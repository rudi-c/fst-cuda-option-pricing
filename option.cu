#include <assert.h>
#include <getopt.h>
#include <math_constants.h>
#include <stdio.h>
#include <vector>

#include <cufft.h>

#include "parameters.h"
#include "utils.h"

#ifdef USE_FLOAT

// For quick testing of floats only, otherwise this is obviously a terrible idea.
#define double float
#define complex cufftComplex
#define cuCreal cuCrealf
#define cuCimag cuCimagf
#define cuCadd cuCaddf
#define cuCmul cuCmulf
#define cuCdiv cuCdivf
#define cuConj cuConjf
#define CUFFT_D2Z CUFFT_R2C
#define CUFFT_Z2D CUFFT_C2R
#define cufftExecD2Z cufftExecR2C
#define cufftExecZ2D cufftExecC2R
#define makeComplex make_cuComplex

// If we're using floats, assume that we're using CUDA Compute Capability < 1.3
// which means the max block size is 512.
#define MAX_BLOCK_SIZE 512

#else

#define complex cufftDoubleComplex
#define makeComplex make_cuDoubleComplex

// If we're using floats, assume that we're using CUDA Compute Capability >= 2.x
// which means the max block size is 1024.
// (We're ignoring Compute Capability 1.3 which supports doubles but not block
//  sizes of 1024 since we don't have any devices of that particular generation)
#define MAX_BLOCK_SIZE 1024

#endif

using namespace std;

__host__ __device__ static __inline__
complex cuComplexExponential(complex x)
{
    double a = cuCreal(x);
    double b = cuCimag(x);
    double ea = exp(a);
    return makeComplex(ea * cos(b), ea * sin(b));
}

__host__ __device__ static __inline__
complex cuComplexPower(complex base, complex exponent)
{
    double a = cuCreal(base);
    double b = cuCimag(base);
    double c = cuCreal(exponent);
    double d = cuCimag(exponent);
    double r = cuCabs(base);
    double theta = atan2(b, a);

    double scalar = pow(r, c) * exp(-theta * d);
    double angle = d * log(r) + c * theta;
    return makeComplex(scalar * cos(angle), scalar * sin(angle));
}

__host__ __device__ static __inline__
complex cuComplexScalarMult(double scalar, complex x)
{
    double a = cuCreal(x);
    double b = cuCimag(x);
    return makeComplex(scalar * a, scalar * b);
}

__global__
void normalize(double* ft, int length)
{
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    ft[idx] /= length;
}

__global__
// TODO: Need better argument names for the last two...
void earlyExercise(double* ft, double startPrice, double strikePrice,
                   double x_min, double delta_x,
                   OptionPayoffType type)
{
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    double assetPrice = startPrice * exp(x_min + idx * delta_x);
    if (type == Call) {
        ft[idx] = max(ft[idx], max(assetPrice - strikePrice, 0.0));
    } else {
        ft[idx] = max(ft[idx], max(strikePrice - assetPrice, 0.0));
    }
}

// Fourier transform of the Merton jump function.
__global__
void prepareMertonJumpFT(complex* jump_ft, double delta_frequency,
                         int N, double mertonNormalStdev, double driftRate)
{
    int idx = blockIdx.x * blockDim.x + threadIdx.x;

    // Frequency (see p.11 for discretization).
    double m;
    if (idx <= N / 2) {
        m = idx;
    } else {
        m = idx - N;
    }
    double k = delta_frequency * m;

    // See Lippa (2013) p.13
    double real = M_PI * k * mertonNormalStdev;
    real = -2 * real * real;
    double imag = -2 * M_PI * k * driftRate;
    complex exponent = makeComplex(real, imag);

    jump_ft[idx] = cuComplexExponential(exponent);
}

// Fourier transform of the Kou jump function
__global__
void prepareKouJumpFT(complex* jump_ft, double delta_frequency,
                      int N, double kouUpJumpProbability,
                      double kouUpRate, double kouDownRate)
{
    int idx = blockIdx.x * blockDim.x + threadIdx.x;

    double p = kouUpJumpProbability;

    // Frequency (see p.11 for discretization).
    double m;
    if (idx <= N / 2) {
        m = idx;
    } else {
        m = idx - N;
    }
    double k = delta_frequency * m;

    // See Lippa (2013) p.54
    complex up = cuCdiv(makeComplex(p, 0),
            makeComplex(1, 2 * M_PI * k / kouUpRate));
    complex down = cuCdiv(makeComplex(1 - p, 0),
            makeComplex(1, -2 * M_PI * k / kouDownRate));

    jump_ft[idx] = cuCadd(up, down);
}

__global__
void prepareJumpModelCharacteristic(
        complex* characteristic, complex* jump_ft,
        double riskFreeRate, double dividend,
        double volatility, double jumpMean,
        double kappa, double delta_frequency,
        int N)
{
    int idx = blockIdx.x * blockDim.x + threadIdx.x;

    // Frequency (see Lippa (2013) p.11 for discretization).
    double m;
    if (idx <= N / 2) {
        m = idx;
    } else {
        m = idx - N;
    }
    double k = delta_frequency * m;

    // Calculate Ψ (psi) (Lippa (2013) 2.14)
    // The dividend is shown on p.13
    // Equation slightly simplified to save a few operations.
    // TODO: Continuous dividend is too specific, there's more interpretations (see thesis).
    double fst_term = volatility * M_PI * k;
    complex psi = makeComplex(
            (-2.0 * fst_term * fst_term) - (riskFreeRate + jumpMean),
            (riskFreeRate - dividend - jumpMean * kappa - volatility * volatility / 2.0) *
                      (2 * M_PI * k));

    // Jump component.
    if (jump_ft) {
        psi = cuCadd(psi, cuComplexScalarMult(jumpMean, cuConj(jump_ft[idx])));
    }

    characteristic[idx] = psi;
}

__global__
void prepareCGMYCharacteristic(
        complex* characteristic,
        int N, double delta_frequency,
        double C, double G, double M, double Y,
        double gamma /* Γ(-Y), do it on the CPU */)
{
    int idx = blockIdx.x * blockDim.x + threadIdx.x;

    // Frequency (see Lippa (2013) p.11 for discretization).
    double m;
    if (idx <= N / 2) {
        m = idx;
    } else {
        m = idx - N;
    }
    double k = delta_frequency * m;
    double w = 2 * M_PI * k;

    // See Lippa (2013) p.17 and Surkov (2009) p.26
    // Originally from Carr (2002) p.313
    // Note that the equation in those papers use the symbol ω
    // instead of k for the frequency.
    complex MY = cuComplexPower(makeComplex(M, -w), makeComplex(Y, 0));
    complex MG = cuComplexPower(makeComplex(G, w), makeComplex(Y, 0));
    characteristic[idx] = cuComplexScalarMult(C * gamma,
            cuCadd(makeComplex(-pow(M, Y) - pow(G, Y), 0),
                   cuCadd(MY, MG)));
}

__global__
void solveODE(complex* ft,
              complex* characteristic,  // psi
              double from_time,         // τ_l (T - t_l)
              double to_time            // τ_u (T - t_u)
             )
{
    int idx = blockIdx.x * blockDim.x + threadIdx.x;

    complex old_value = ft[idx];

    complex psi = characteristic[idx];

    // Solution to ODE (Lippa (2013) 2.27)
    double delta_tau = to_time - from_time;
    complex exponent = cuComplexScalarMult(delta_tau, psi);
    complex exponential = cuComplexExponential(exponent);

    complex new_value = cuCmul(old_value, exponential);

    ft[idx] = new_value;
}

vector<double> assetPricesAtPayoff(Parameters& prms)
{
    double N = prms.resolution;
    vector<double> out(N);

    // Discretization parameters (see p.11)
    // TODO: Factor out into params?
    double x_max = prms.x_max();
    double x_min = prms.x_min();
    double delta_x = (x_max - x_min) / (N - 1);

    /*
    // Tree parameters (see p.53 of notes).
    double u = exp(prms.volatility * sqrt(prms.timeIncrement));
    double d = 1.0 / u;
    double a = exp(prms.riskFreeRate * prms.timeIncrement);
    // double p = (a - d) / (u - d);

    for (int i = 0; i < N; i++) {
        out[i] = prms.startPrice * pow(u, i) * pow(d, N - i);
    }
    */

    for (int i = 0; i < N; i++) {
        out[i] = prms.startPrice * exp(x_min + i * delta_x);
    }

    return out;
}

vector<double> optionValuesAtPayoff(Parameters& prms, vector<double>& assetPrices)
{
    vector<double> out(prms.resolution);

    double N = prms.resolution;
    for (int i = 0; i < N; i++) {
        if (prms.optionPayoffType == Call) {
            out[i] = max(assetPrices[i] - prms.strikePrice, 0.0);
        } else {
            out[i] = max(prms.strikePrice - assetPrices[i], 0.0);
        }
    }

    return out;
}

void printComplex(complex x) {
    double a = cuCreal(x);
    double b = cuCimag(x);
    printf("%f + %fi", a, b);
}

void printComplexArray(vector<complex> xs)
{
    for (int i = 0; i < xs.size(); i++) {
        printComplex(xs[i]);
        if (i < xs.size() - 1)
            printf(", ");
        if (i % 5 == 0 && i > 0)
            printf("\n");
    }
    printf("\n");
}

vector<complex> dft(vector<double>& in)
{
    vector<complex> out(in.size());

    for (int k = 0; k < out.size(); k++) {
        out[k] = makeComplex(0, 0);

        for (int n = 0; n < in.size(); n++) {
            complex exponent = makeComplex(0, -2.0f * M_PI * k * n / in.size());
            out[k] = cuCadd(out[k], cuComplexScalarMult(in[n], cuComplexExponential(exponent)));
        }
    }

    return out;
}

vector<complex> idft_complex(vector<complex>& in)
{
    vector<complex> out(in.size());

    for (int k = 0; k < out.size(); k++) {
        out[k] = makeComplex(0, 0);

        for (int n = 0; n < in.size(); n++) {
            complex exponent = makeComplex(0, 2.0f * M_PI * k * n / in.size());
            out[k] = cuCadd(out[k], cuCmul(in[n], cuComplexExponential(exponent)));
        }

        out[k] = cuComplexScalarMult(1.0 / out.size(), out[k]);
    }

    /*
    printComplexArray(out);
    printf("\n");
    */

    return out;
}

vector<double> idft(vector<complex>& in)
{
    vector<complex> ift = idft_complex(in);
    vector<double> out(ift.size());
    for (int i = 0; i < ift.size(); i++) {
        out[i] = cuCreal(ift[i]);
    }
    return out;
}

void printPrices(vector<double>& prices) {
    int first_negative = -1;
    for (int i = 0; i < prices.size(); i++) {
        printf("%f ", prices[i]);
        if (first_negative == -1 && prices[i] < 0) {
            first_negative = i;
        }
    }
    printf("\n");
    printf("First negative number at %d.\n", first_negative);
}

void computeCPU(Parameters& params, vector<double>& assetPrices, vector<double>& optionValues)
{
    int N = params.resolution;

    // Discretization parameters (see p.11)
    double x_max = params.x_max();
    double x_min = params.x_min();
    double delta_frequency = (double)(N - 1) / (x_max - x_min) / N;

    double from_time = 0.0f;
    double to_time = params.expiryTime;
    double riskFreeRate = params.riskFreeRate;
    double volatility = params.volatility;
    double jumpMean = params.jumpMean;
    double kappa = params.kappa();

    // Forward transform
    vector<complex> ft = dft(optionValues);
    vector<complex> ft2(N);

    for (int idx = 0; idx < ft.size(); idx++) {
        complex old_value = ft[idx];

        // Frequency (see p.11 for discretization).
        double m;
        if (idx <= N / 2) {
            m = idx;
        } else {
            m = idx - N;
        }
        double k = delta_frequency * m;

        // Calculate Ψ (psi) (2.14)
        // Equation slightly simplified to save a few operations.
        double fst_term = volatility * M_PI * k;
        double psi_real = (-2.0 * fst_term * fst_term) - (riskFreeRate + jumpMean);
        double psi_imag = (riskFreeRate - jumpMean * kappa - volatility * volatility / 2.0) *
                          (2 * M_PI * k);

        // TODO: jump component.

        // Solution to ODE (2.27)
        double delta_tau = to_time - from_time;
        complex exponent =
            makeComplex(psi_real * delta_tau, psi_imag * delta_tau);
        complex exponential = cuComplexExponential(exponent);

        complex new_value = cuCmul(old_value, exponential);

        ft2[idx] = new_value;
    }

    // Inverse transform
    vector<double> ift = idft(ft2);

    // printPrices(ift);

    double answer_index = -x_min * (N - 1) / (x_max - x_min);
    assert(answer_index == (int)answer_index);

    if (params.verbose) {
        printf("Price at index %i: %f\n", (int)answer_index, ift[(int)answer_index]);
    } else {
        printf("%f\n", ift[(int)answer_index]);
    }
}

void computeGPU(Parameters& params, vector<double>& assetPrices, vector<double>& optionValues)
{
    // Option values at time t = 0
    vector<double> initialValues(optionValues.size());

    int N = params.resolution;

    double* d_prices;
    checkCuda(cudaMalloc((void**)&d_prices, sizeof(double) * N));
    checkCuda(cudaMemcpy(d_prices, &optionValues[0], sizeof(double) * N,
                         cudaMemcpyHostToDevice));

    complex* d_ft;
    checkCuda(cudaMalloc((void**)&d_ft, sizeof(complex) * N));

    cufftHandle plan;
    cufftHandle planr;

    // Float to complex interleaved
    checkCufft(cufftPlan1d(&plan, N, CUFFT_D2Z, /* deprecated? */ 1));
    checkCufft(cufftPlan1d(&planr, N, CUFFT_Z2D, /* deprecated? */ 1));

    // Discretization parameters (see p.11)
    double x_min = params.x_min();
    double x_max = params.x_max();
    double delta_x = (x_max - x_min) / (N - 1);
    double delta_frequency = (double)(N - 1) / (x_max - x_min) / N;

    // Characteristic Ψ (psi) and Jump function
    // TODO: I think we're fine with just N/2 + 1 of these.
    complex *d_characteristic = NULL;
    checkCuda(cudaMalloc((void**)&d_characteristic, sizeof(complex) * N));
    complex *d_jump_ft = NULL;

    if (params.jumpType == CGMY) {
        prepareCGMYCharacteristic<<<max(N / MAX_BLOCK_SIZE, 1), min(N, MAX_BLOCK_SIZE)>>>(
                d_characteristic,
                N, delta_frequency,
                params.CGMY_C, params.CGMY_G, params.CGMY_M, params.CGMY_Y,
                tgamma(-params.CGMY_Y));
    } else {
        if (params.jumpType != None) {
            checkCuda(cudaMalloc((void**)&d_jump_ft, sizeof(complex) * N));

            if (params.jumpType == Merton) {
                prepareMertonJumpFT<<<max(N / MAX_BLOCK_SIZE, 1), min(N, MAX_BLOCK_SIZE)>>>(
                        d_jump_ft, delta_frequency, N,
                        params.mertonNormalStdev, params.driftRate);
            } else if (params.jumpType == Kou) {
                prepareKouJumpFT<<<max(N / MAX_BLOCK_SIZE, 1), min(N, MAX_BLOCK_SIZE)>>>(
                        d_jump_ft, delta_frequency, N,
                        params.kouUpJumpProbability, params.kouUpRate, params.kouDownRate);
            }
        }

        prepareJumpModelCharacteristic<<<max(N / MAX_BLOCK_SIZE, 1), min(N, MAX_BLOCK_SIZE)>>>(
                d_characteristic, d_jump_ft,
                params.riskFreeRate, params.dividendRate,
                params.volatility, params.jumpMean, params.kappa(),
                delta_frequency, N);
    }

    for (int i = 0; i < params.timesteps; i++) {
        double from_time = (double)i / params.timesteps * params.expiryTime;
        double to_time = (double)(i + 1) / params.timesteps * params.expiryTime;

        // Forward transform
        checkCufft(cufftExecD2Z(plan, d_prices, d_ft));

        // Solve ODE
        // Note that we solve the ODE only on the first half of the frequency
        // data. Why? A fourier transform on real (non-complex) data will give
        // hermetian symmetry, where the second half of the array is just the
        // complex conjugate of the first half. So cufft & fftw doesn't store
        // any values in the second half at all! They don't use the second half
        // of the array either to compute the inverse fourier transform.
        // See http://www.fftw.org/doc/The-1d-Real_002ddata-DFT.html
        int fourier_size = N / 2 + 1;
        int fourier_block_count = (int)ceil((double)fourier_size / MAX_BLOCK_SIZE);
        int fourier_block_size = min(fourier_size, MAX_BLOCK_SIZE);
        solveODE<<<fourier_block_count, fourier_block_size>>>(
                d_ft, d_characteristic, from_time, to_time);

        // Reverse transform
        checkCufft(cufftExecZ2D(planr, d_ft, d_prices));
        normalize<<<max(N / MAX_BLOCK_SIZE, 1), min(N, MAX_BLOCK_SIZE)>>>(d_prices, N);

        // Consider early exercise for American options. This is the same technique
        // as option pricing using dynamic programming: at each timestep, set the
        // option value to the payoff if is higher than the current option value.
        if (params.optionExerciseType == American) {
            earlyExercise<<<max(N / MAX_BLOCK_SIZE, 1), min(N, MAX_BLOCK_SIZE)>>>(
                    d_prices, params.startPrice, params.strikePrice,
                    x_min, delta_x, params.optionPayoffType);
        }
    }

    checkCuda(cudaMemcpy(&initialValues[0], d_prices, sizeof(double) * N,
                         cudaMemcpyDeviceToHost));

    // Destroy the cuFFT plan.
    cufftDestroy(plan);
    cufftDestroy(planr);
    cudaFree(d_prices);
    cudaFree(d_ft);
    cudaFree(d_jump_ft);

    double answer_index = -x_min * (N - 1) / (x_max - x_min);
    assert(answer_index == (int)answer_index);

    if (params.verbose) {
        printf("Price at index %i: %f\n", (int)answer_index, initialValues[(int)answer_index]);
    } else {
        printf("%f\n", initialValues[(int)answer_index]);
    }
}

int main(int argc, char** argv)
{
    assert(sizeof(complex) == 2 * sizeof(double));

    Parameters params;

    // Parse arguments
    while (true) {
        static struct option long_options[] = {
            {"payoff",  required_argument, 0, 'p'},
            {"exercise",  required_argument, 0, 'e'},
            {"dividend",  required_argument, 0, 'q'},
            {"debug",  no_argument, 0, 'd'},
            {"verbose",  no_argument, 0, 'v'},
            // General parameters
            {"S",  required_argument, 0, 'S'},
            {"K",  required_argument, 0, 'K'},
            {"r",  required_argument, 0, 'r'},
            {"T",  required_argument, 0, 'T'},
            {"sigma",  required_argument, 0, 'o'},
            {"resolution",  required_argument, 0, 'n'},
            {"timesteps",  required_argument, 0, 't'},
            // Merton Jump args
            {"mertonjumps",  no_argument, 0, 'm'},
            {"lambda",  required_argument, 0, 'l'},
            {"mu",  required_argument, 0, 'u'},
            // Kou Jump args
            {"koujumps",  no_argument, 0, 'k'},
            {"p",  required_argument, 0, '0'},
            {"etaUp",  required_argument, 0, '1'},
            {"etaDown",  required_argument, 0, '2'},
            {"gamma",  required_argument, 0, 'y'},
            // CGMY model
            {"CGMY",  no_argument, 0, '4'},
            {"C",  required_argument, 0, 'C'},
            {"G",  required_argument, 0, 'G'},
            {"M",  required_argument, 0, 'M'},
            {"Y",  required_argument, 0, 'Y'},
            {0, 0, 0, 0}
        };

        int option_index = 0;
        char c = getopt_long(argc, argv, "abc:d:f:", long_options, &option_index);

        if (c == -1) {
            break;
        }

        switch (c) {
            case 'e':
                if (!strcmp(optarg, "european")) {
                    params.optionExerciseType = European;
                } else if (!strcmp(optarg, "american")) {
                    params.optionExerciseType = American;
                } else {
                    fprintf(stderr, "Option exercise type %s invalid.\n", optarg);
                    abort();
                }
                break;
            case 'p':
                if (!strcmp(optarg, "put")) {
                    params.optionPayoffType = Put;
                } else if (!strcmp(optarg, "call")) {
                    params.optionPayoffType = Call;
                } else {
                    fprintf(stderr, "Option payoff type %s invalid.\n", optarg);
                    abort();
                }
                break;
            case 'q':
                params.dividendRate = atof(optarg);
                break;
            case 'l':
                params.jumpMean = atof(optarg);
                break;
            case 'u':
                params.driftRate = atof(optarg);
                break;
            case '0':
                params.kouUpJumpProbability = atof(optarg);
                break;
            case '1':
                params.kouUpRate = atof(optarg);
                break;
            case '2':
                params.kouDownRate = atof(optarg);
                break;
            case '4':
                params.jumpType = CGMY;
                break;
            case 'C':
                params.CGMY_C = atof(optarg);
                break;
            case 'G':
                params.CGMY_G = atof(optarg);
                break;
            case 'M':
                params.CGMY_M = atof(optarg);
                break;
            case 'Y':
                params.CGMY_Y = atof(optarg);
                break;
            case 'y':
                params.mertonNormalStdev = atof(optarg);
                break;
            case 'S':
                params.startPrice = atof(optarg);
                break;
            case 'K':
                params.strikePrice = atof(optarg);
                break;
            case 'r':
                params.riskFreeRate = atof(optarg);
                break;
            case 'T':
                params.expiryTime = atof(optarg);
                break;
            case 'o':
                params.volatility = atof(optarg);
                break;
            case 'd':
                params.debug = true;
                break;
            case 'm':
                params.jumpType = Merton;
                break;
            case 'k':
                params.jumpType = Kou;
                break;
            case 'n':
                params.resolution = atoi(optarg);
                assert(isPowerOfTwo(params.resolution));
                break;
            case 't':
                params.timesteps = atoi(optarg);
                break;
            case 'v':
                params.verbose = true;
                break;
            case '?':
                break;
            default:
                abort();
        }
    }

    cudaCheck(params.debug);

    if (params.verbose) {
        printf("\nChecks finished. Starting option calculation...\n\n");
    }

    vector<double> assetPrices = assetPricesAtPayoff(params);
    vector<double> optionValues = optionValuesAtPayoff(params, assetPrices);

    if (params.verbose) {
        printf("\nComputing GPU results...\n");
    }
    computeGPU(params, assetPrices, optionValues);

    return EXIT_SUCCESS;
}

