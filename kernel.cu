// Standard C++ includes
#include <algorithm>
#include <chrono>
#include <iostream>
#include <numeric>
#include <random>
#include <stdexcept>
#include <string>
#include <sstream>
#include <vector>

// Standard C includes
#include <cassert>
#include <cmath>

// CUDA includes
#include <cooperative_groups.h>
#include <cuda_runtime.h>
#include <curand_kernel.h>
#include <device_launch_parameters.h>

//------------------------------------------------------------------------
// Macros
//------------------------------------------------------------------------
#define SEED 124
#define BLOCK_SIZE 32

#define CHECK_CUDA_ERRORS(call) {                                                                   \
    cudaError_t error = call;                                                                       \
    if (error != cudaSuccess) {                                                                     \
            std::ostringstream errorMessageStream;                                                  \
            errorMessageStream << "cuda error:" __FILE__ << ": " << __LINE__ << " ";                \
            errorMessageStream << cudaGetErrorString(error) << "(" << error << ")" << std::endl;    \
            throw std::runtime_error(errorMessageStream.str());                                     \
        }                                                                                           \
    }

template<typename T>
using HostDeviceArray = std::pair < T*, T* > ;

enum Mode
{
    Mode1D,
    Mode2DGlobalAtomic,
    Mode2DSharedAtomic,
    Mode2DWarpShuffle,
    ModeMax,
};

const char *const s_ModeNames[] = {
    "1D",
    "2D global atomic",
    "2D shared atomic",
    "2D warp shuffle"};

//------------------------------------------------------------------------
// Timer
//------------------------------------------------------------------------
template<typename A = std::milli>
class Timer
{
public:
    Timer(const std::string &title) : m_Start(std::chrono::high_resolution_clock::now()), m_Title(title)
    {
    }

    ~Timer()
    {
        std::cout << m_Title << get() << std::endl;
    }

    //------------------------------------------------------------------------
    // Public API
    //------------------------------------------------------------------------
    double get() const
    {
        auto now = std::chrono::high_resolution_clock::now();
        std::chrono::duration<double, std::milli> duration = now - m_Start;
        return duration.count();
    }

private:
    //------------------------------------------------------------------------
    // Members
    //------------------------------------------------------------------------
    std::chrono::time_point<std::chrono::high_resolution_clock> m_Start;
    std::string m_Title;
};

//-----------------------------------------------------------------------------
// Device functions
//-----------------------------------------------------------------------------
//  Von Neumann'synBlk exponential distribution generator from Ripley p.230
//  Mean number of U(0,1) per call = 5.2
__device__ float exponentialDist(curandState &rng) {
    float a = 0.0f;

    while (true) {
        float u = curand_uniform(&rng);
        const float u0 = u;

        while (true) {
            float uStar = curand_uniform(&rng);
            if (u < uStar) {
                return  a + u0;
            }

            u = curand_uniform(&rng);

            if (u >= uStar) {
                break;
            }
        }

        a += 1.0f;
    }
}
//-----------------------------------------------------------------------------
// Kernel to initialise device RNG seed
template<typename RNGStateType>
__global__ void initRandomSeed(unsigned int sequenceStart, unsigned int numSeed, RNGStateType *d_rowState)
{
    const int i = threadIdx.x + (blockIdx.x * BLOCK_SIZE);
    if (i < numSeed) {
        curand_init(SEED, sequenceStart + i, 0, &d_rowState[i]);
    }

}
//-----------------------------------------------------------------------------
// Kernel to initialise initial Poisson time-to-spike
__global__ void initPoissonTimeToSpike(unsigned int numPoisson, const float *d_meanISI, curandState *d_poissonState,
                                       float *d_timeToSpike)
{
    // Get index of neuron in population
    const int i = threadIdx.x + (blockIdx.x * BLOCK_SIZE);
    if (i < numPoisson) {
        d_timeToSpike[i] = d_meanISI[i] * exponentialDist(d_poissonState[i]);
    }
}
//-----------------------------------------------------------------------------
// Kernel to simulate population of poisson neurons
__global__ void poisson(unsigned int numPoisson, const float *d_meanISI, curandState *d_poissonState,
                        float *d_timeToSpike, unsigned int *d_numOutSpikes, unsigned int *d_outSpikes)
{
    // Count and buffer to hold spikes output by this block
    __shared__ unsigned int blockSpikeCount;
    __shared__ unsigned int blockOutSpikes[BLOCK_SIZE];

    // Offset into global spike output buffer
    __shared__ unsigned int blockSpikeOffset;

    // Get index of neuron in population
    const int i = threadIdx.x + (blockIdx.x * BLOCK_SIZE);

    // Use first thread in each block to zero spike counts
    if (threadIdx.x == 0) {
        blockSpikeCount = 0;
    }
    __syncthreads();

    // If there is a neuron for this thread to simulate
    if (i < numPoisson) {
        float tts = d_timeToSpike[i];

        if (tts <= 0.0f) {
            tts += (d_meanISI[i] * exponentialDist(d_poissonState[i]));

            // Add spike to output
            unsigned int blockSpikeIndex = atomicAdd(&blockSpikeCount, 1);
            blockOutSpikes[blockSpikeIndex] = i;
        }

        d_timeToSpike[i] = (tts - 1.0f);
    }

    // If block has emitted any spikes, use the first thread to  
    // determine where in global spike output buffer to copy them
    __syncthreads();
    if (threadIdx.x == 0 && blockSpikeCount > 0) {
        blockSpikeOffset = atomicAdd(&d_numOutSpikes[0], blockSpikeCount);
    }

    // Copy spikes from block output buffer into correct offset in global buffer
    __syncthreads();
    if (threadIdx.x < blockSpikeCount) {
        d_outSpikes[blockSpikeOffset + threadIdx.x] = blockOutSpikes[threadIdx.x];
    }
}
//-----------------------------------------------------------------------------
__global__ void dense1D(unsigned int numPost, const unsigned int *d_numInSpikes, 
                        const unsigned int *d_inSpikes, const float *d_weights, float *d_outCurrents)
{
    __shared__ unsigned int s_spike[BLOCK_SIZE];

    const unsigned int id = threadIdx.x + (blockIdx.x * BLOCK_SIZE);

    // Calculate number of blocks (dictated by shared memory) spikes need to be processed in
    const unsigned int numSpikes = d_numInSpikes[0];
    const unsigned int numSpikeBlocks = (numSpikes + BLOCK_SIZE - 1) / BLOCK_SIZE;

    // Loop through spikes blocks
    float output = 0.0f;
    for (unsigned int b = 0; b < numSpikeBlocks; b++) {
        // Determine how many spikes are in this block
        const unsigned int numSpikesInBlock = (b == (numSpikeBlocks - 1))
            ? ((numSpikes - 1) % BLOCK_SIZE) + 1 : BLOCK_SIZE;

       // Use first row of threads in block to read spikes and row lengths into shared memory
        if (threadIdx.x < numSpikesInBlock) {
            const unsigned int i = d_inSpikes[(b * BLOCK_SIZE) + threadIdx.x];
            s_spike[threadIdx.x] = i;
        }

        __syncthreads();

        // If there is a synapse for this thread to process
        if(id < numPost) {
            // Loop through spikes in block
            for(unsigned int i = 0; i < numSpikesInBlock; i++) {
                // Get postsynaptic index
                const unsigned int synAddress = (s_spike[i] * numPost) + id;

                // Add input current
                output += d_weights[synAddress];
            }
        }

    }

    // Write currents to global
    if(id < numPost) {
        d_outCurrents[id] += output;
    }
}
//-----------------------------------------------------------------------------
__global__ void dense2DGlobalAtomic(unsigned int numPost, const unsigned int *d_numInSpikes, 
                                    const unsigned int *d_inSpikes, const float *d_weights, float *d_outCurrents)
{
    __shared__ unsigned int s_spike[BLOCK_SIZE];

    const unsigned int id = threadIdx.x + (blockIdx.x * BLOCK_SIZE);

    // Calculate number of blocks (dictated by shared memory) spikes need to be processed in
    const unsigned int numSpikes = d_numInSpikes[0];
    const unsigned int numSpikeBlocks = (numSpikes + BLOCK_SIZE - 1) / BLOCK_SIZE;

    // Loop through spikes blocks
    float output = 0.0f;
    for (unsigned int b = 0; b < numSpikeBlocks; b++) {
        // Determine how many spikes are in this block
        const unsigned int numSpikesInBlock = (b == (numSpikeBlocks - 1))
            ? ((numSpikes - 1) % blockDim.x) + 1 : BLOCK_SIZE;

        // Use first row of threads in block to read spikes and row lengths into shared memory
        if (threadIdx.y == 0 && threadIdx.x < numSpikesInBlock) {
            const unsigned int i = d_inSpikes[(b * BLOCK_SIZE) + threadIdx.x];
            s_spike[threadIdx.x] = i;
        }

        __syncthreads();

        // If there is a synapse for this thread to process
        if(id < numPost && threadIdx.y < numSpikesInBlock) {
            // Get postsynaptic index
            const unsigned int synAddress = (s_spike[threadIdx.y] * numPost) + id;

            // Add output current
            output += d_weights[synAddress];
        }
    }

    // Write currents to global
    if(id < numPost) {
        atomicAdd(&d_outCurrents[id], output);
    }
}

//-----------------------------------------------------------------------------
__global__ void dense2DSharedAtomic(unsigned int numPost, const unsigned int *d_numInSpikes, 
                                    const unsigned int *d_inSpikes, const float *d_weights, float *d_outCurrents)
{
    __shared__ unsigned int s_spike[BLOCK_SIZE];
    __shared__ float s_output[BLOCK_SIZE];

    const unsigned int id = threadIdx.x + (blockIdx.x * BLOCK_SIZE);

    // Calculate number of blocks (dictated by shared memory) spikes need to be processed in
    const unsigned int numSpikes = d_numInSpikes[0];
    const unsigned int numSpikeBlocks = (numSpikes + BLOCK_SIZE - 1) / BLOCK_SIZE;
    
    // Zero shared memory
    if (threadIdx.y == 0) {
        s_output[threadIdx.x] = 0.0f;
    }
    __syncthreads();

    // Loop through spikes blocks
    float output = 0.0f;
    for (unsigned int b = 0; b < numSpikeBlocks; b++) {
        // Determine how many spikes are in this block
        const unsigned int numSpikesInBlock = (b == (numSpikeBlocks - 1))
            ? ((numSpikes - 1) % BLOCK_SIZE) + 1 : BLOCK_SIZE;

        // Use first row of threads in block to read spikes and row lengths into shared memory
        if (threadIdx.y == 0 && threadIdx.x < numSpikesInBlock) {
            const unsigned int i = d_inSpikes[(b * BLOCK_SIZE) + threadIdx.x];
            s_spike[threadIdx.x] = i;
        }

        __syncthreads();

        // If there is a synapse for this thread to process
        if(id < numPost && threadIdx.y < numSpikesInBlock) {
            // Get postsynaptic index
            const unsigned int synAddress = (s_spike[threadIdx.y] * numPost) + id;

            // Add input current
            output += d_weights[synAddress];
        }
    }

    // Add input to shared
    atomicAdd(&s_output[threadIdx.x], output);
    __syncthreads();

    // Write currents to global
    if(threadIdx.y == 0 && id < numPost) {
        d_outCurrents[id] += s_output[threadIdx.x];
    }
}
//-----------------------------------------------------------------------------
__global__ void dense2DWarpShuffle(unsigned int numPost, const unsigned int *d_numInSpikes, 
                                   const unsigned int *d_inSpikes, const float *d_weights, float *d_outCurrents)
{
    __shared__ unsigned int s_spike[BLOCK_SIZE];
    __shared__ float s_output[BLOCK_SIZE][BLOCK_SIZE];

    const unsigned int id = threadIdx.x + (blockIdx.x * BLOCK_SIZE);

    // Calculate number of blocks (dictated by shared memory) spikes need to be processed in
    const unsigned int numSpikes = d_numInSpikes[0];
    const unsigned int numSpikeBlocks = (numSpikes + BLOCK_SIZE - 1) / BLOCK_SIZE;
    
    // Loop through spikes blocks
    float output = 0.0f;
    for (unsigned int b = 0; b < numSpikeBlocks; b++) {
        // Determine how many spikes are in this block
        const unsigned int numSpikesInBlock = (b == (numSpikeBlocks - 1))
            ? ((numSpikes - 1) % BLOCK_SIZE) + 1 : BLOCK_SIZE;

        // Use first row of threads in block to read spikes and row lengths into shared memory
        if (threadIdx.y == 0 && threadIdx.x < numSpikesInBlock) {
            const unsigned int i = d_inSpikes[(b * BLOCK_SIZE) + threadIdx.x];
            s_spike[threadIdx.x] = i;
        }

        __syncthreads();

        // If there is a synapse for this thread to process
        if(id < numPost && threadIdx.y < numSpikesInBlock) {
            // Get postsynaptic index
            const unsigned int synAddress = (s_spike[threadIdx.y] * numPost) + id;

            // Add input current
            output += d_weights[synAddress];
        }
    }

    // Copy output to shared
    s_output[threadIdx.x][threadIdx.y] = output;
    __syncthreads();

    
    // Warp reduce down columns 
    float outputSum = s_output[threadIdx.y][threadIdx.x];
    for (int i = 16; i > 0; i = i / 2) {
        outputSum += __shfl_down_sync(-1, outputSum, i);
    }

    const unsigned int tranposeID = threadIdx.y + (blockIdx.x * BLOCK_SIZE);
    if(tranposeID < numPost && threadIdx.x == 0) {
        d_outCurrents[tranposeID] += outputSum;
    }
}

//-----------------------------------------------------------------------------
// Host functions
//-----------------------------------------------------------------------------
template<typename T>
HostDeviceArray<T> allocateHostDevice(unsigned int count)
{
    T *array = nullptr;
    T *d_array = nullptr;
    CHECK_CUDA_ERRORS(cudaMallocHost(&array, count * sizeof(T)));
    CHECK_CUDA_ERRORS(cudaMalloc(&d_array, count * sizeof(T)));

    return std::make_pair(array, d_array);
}
//-----------------------------------------------------------------------------
template<typename T>
void hostToDeviceCopy(HostDeviceArray<T> &array, unsigned int count, bool deleteHost=false)
{
    CHECK_CUDA_ERRORS(cudaMemcpy(array.second, array.first, sizeof(T) * count, cudaMemcpyHostToDevice));
    if (deleteHost) {
        CHECK_CUDA_ERRORS(cudaFreeHost(array.first));
        array.first = nullptr;
    }
}
//-----------------------------------------------------------------------------
template<typename T>
void deviceToHostCopy(HostDeviceArray<T> &array, unsigned int count)
{
    CHECK_CUDA_ERRORS(cudaMemcpy(array.first, array.second, count * sizeof(T), cudaMemcpyDeviceToHost));
}
//-----------------------------------------------------------------------------
int main(int argc, char *argv[])
{
    try
    {
        unsigned int numPre = 10000;
        unsigned int numPost = 10000;
        const float dt = 1.0f;
        const float poissonRate = 10.0f;
    
        // Read mode from command line
        Mode mode;
        if(argc < 2) {
            std::cerr << "Expected parameters specifying:" << std::endl;
            std::cerr << "\t Mode (";
            for(int m = 0; m < ModeMax; m++) {
                std::cerr << m << " = " << s_ModeNames[m];
                if(m != (ModeMax - 1)) {
                    std::cerr << ", ";
                }
            }
            std::cerr << ")" << std::endl;
            return EXIT_FAILURE;
        }
        else {
            mode = (Mode)std::stoul(argv[1]);
        }
    
        // If additional parameters are specified, read N
        if(argc > 2) {
            numPre = numPost = std::stoul(argv[2]);
        }

        const unsigned int preBlocks = (unsigned int)std::ceil((float)numPre / (float)BLOCK_SIZE);
        std::cout << "Mode:" << s_ModeNames[mode] << " pre:" << numPre << ", num post:" << numPost << std::endl;
    
        CHECK_CUDA_ERRORS(cudaSetDevice(0));

        //------------------------------------------------------------------------
        // Configure fixed-probability connector
        //------------------------------------------------------------------------
        // Create arrays to hold post-synaptic currents
        auto outCurrents = allocateHostDevice<float>(numPost);
        std::fill_n(&outCurrents.first[0], numPost, 0.0f);
        hostToDeviceCopy(outCurrents, numPost);

        HostDeviceArray<float> weights;
       
        // Allocate, fill and upload weight array
        const unsigned int numIndices = numPre * numPost;
        weights = allocateHostDevice<float>(numIndices);
        std::fill_n(&weights.first[0], numIndices, 1.0f);
        hostToDeviceCopy(weights, numIndices, true);


        //------------------------------------------------------------------------
        // Configure poisson population
        //------------------------------------------------------------------------
        // Create arrays to hold poisson spike count
        auto poissonNumSpikes = allocateHostDevice<unsigned int>(1);

        // Create arrays to hold poisson spikes
        auto poissonSpikes = allocateHostDevice<unsigned int>(numPre);

        // Create arrays to hold poisson interspike intervals
        auto poissonMeanISI = allocateHostDevice<float>(numPre);
        std::fill_n(&poissonMeanISI.first[0], numPre, 1000.0 / (poissonRate * dt));
        hostToDeviceCopy(poissonMeanISI, numPre, true);

        // Create device random number generator states for poisson generators
        curandState *d_poissonState = nullptr;
        CHECK_CUDA_ERRORS(cudaMalloc(&d_poissonState, numPre * sizeof(curandState)));
        {
            Timer<std::milli> t("Seed poisson:");
            // Initialise these seeds using kernel
            // **NOTE** first numPre sequences used by Poisson spike sources
            initRandomSeed <<<preBlocks, BLOCK_SIZE>>>(numPre, numPre, d_poissonState);
            cudaDeviceSynchronize();
        }

        // Create device array for poisson generator time to spike
        float *d_poissonTimeToSpike = nullptr;
        CHECK_CUDA_ERRORS(cudaMalloc(&d_poissonTimeToSpike, numPre * sizeof(float)));

        // Initialise time to spike using kernel
        {
            Timer<std::milli> t("Init poisson TTS:");
            initPoissonTimeToSpike <<<preBlocks, BLOCK_SIZE>>>(numPre, poissonMeanISI.second, d_poissonState,
                d_poissonTimeToSpike);
            cudaDeviceSynchronize();
        }

        // Create timing events
        cudaEvent_t kernelStartEvent;
        cudaEvent_t kernelEndEvent;
        double kernelTime = 0.0;
        CHECK_CUDA_ERRORS(cudaEventCreate(&kernelStartEvent));
        CHECK_CUDA_ERRORS(cudaEventCreate(&kernelEndEvent));

        {
            // Loop through time
            for (unsigned int t = 0; t < 1000; t++) {
                poissonNumSpikes.first[0] = 0;
                hostToDeviceCopy(poissonNumSpikes, 1);

                // Simulate poisson population
                poisson <<<preBlocks, 32>>>(numPre, poissonMeanISI.second, d_poissonState,
                    d_poissonTimeToSpike, poissonNumSpikes.second, poissonSpikes.second);
            
                CHECK_CUDA_ERRORS(cudaEventRecord(kernelStartEvent));
                if(mode == Mode1D) {
                    const unsigned int numPostSynapseBlocks = (unsigned int)std::ceil((float)numPost / (float)BLOCK_SIZE);

                    dim3 threads(BLOCK_SIZE, 1);
                    dim3 grid(numPostSynapseBlocks, 1);
                    dense1D<<<grid, threads>>>(numPost, poissonNumSpikes.second, poissonSpikes.second, weights.second, outCurrents.second);
                }
                else if(mode == Mode2DGlobalAtomic) {
                    const unsigned int numPostSynapseBlocks = (unsigned int)std::ceil((float)numPost / (float)BLOCK_SIZE);
       
                    dim3 threads(BLOCK_SIZE, BLOCK_SIZE);
                    dim3 grid(numPostSynapseBlocks, 1);
                    dense2DGlobalAtomic<<<grid, threads>>>(numPost, poissonNumSpikes.second, poissonSpikes.second, weights.second, outCurrents.second);
                }
                else if(mode == Mode2DSharedAtomic) {
                    const unsigned int numPostSynapseBlocks = (unsigned int)std::ceil((float)numPost / (float)BLOCK_SIZE);
       
                    dim3 threads(BLOCK_SIZE, BLOCK_SIZE);
                    dim3 grid(numPostSynapseBlocks, 1);
                    dense2DSharedAtomic<<<grid, threads>>>(numPost, poissonNumSpikes.second, poissonSpikes.second, weights.second, outCurrents.second);
                }
                else if(mode == Mode2DWarpShuffle) {
                    const unsigned int numPostSynapseBlocks = (unsigned int)std::ceil((float)numPost / (float)BLOCK_SIZE);
       
                    dim3 threads(BLOCK_SIZE, BLOCK_SIZE);
                    dim3 grid(numPostSynapseBlocks, 1);
                    dense2DWarpShuffle<<<grid, threads>>>(numPost, poissonNumSpikes.second, poissonSpikes.second, weights.second, outCurrents.second);
                }

                CHECK_CUDA_ERRORS(cudaEventRecord(kernelEndEvent));
                CHECK_CUDA_ERRORS(cudaEventSynchronize(kernelEndEvent));

                float tmp;
                CHECK_CUDA_ERRORS(cudaEventElapsedTime(&tmp, kernelStartEvent, kernelEndEvent));
                kernelTime += tmp;
            }
        }

        std::cout << "Kernel time:" << kernelTime << " ms" << std::endl;

        deviceToHostCopy(outCurrents, numPost);
        float meanCurrent = std::accumulate(&outCurrents.first[0], &outCurrents.first[numPost], 0.0f) / (float)numPost;
        std::cout << "Mean current:" << meanCurrent << ", estimated mean current:" << numPre * poissonRate << std::endl;
    }
    catch(std::exception &ex)
    {
        std::cerr << ex.what() << std::endl;
        return EXIT_FAILURE;
    }

    return EXIT_SUCCESS;
}

