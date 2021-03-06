#include <stdio.h>

#include <cuda.h>
#include <cuda_runtime.h>
#include <driver_functions.h>

#include <thrust/scan.h>
#include <thrust/device_ptr.h>
#include <thrust/device_malloc.h>
#include <thrust/device_free.h>

#include "CycleTimer.h"

#define gpuErrchk(ans) { gpuAssert((ans), __FILE__, __LINE__); }
inline void gpuAssert(cudaError_t code, const char *file, int line, bool abort=true)
{
   if (code != cudaSuccess) 
   {
      fprintf(stderr,"GPUassert: %s %s %d\n", cudaGetErrorString(code), file, line);
      if (abort) exit(code);
   }
}


extern float toBW(int bytes, float sec);


/* Helper function to round up to a power of 2. 
 */
static inline int nextPow2(int n)
{
    n--;
    n |= n >> 1;
    n |= n >> 2;
    n |= n >> 4;
    n |= n >> 8;
    n |= n >> 16;
    n++;
    return n;
}

__global__ void
upsweep_kernel(int N, int twod, int twod1, int* output) {

    // compute overall index from dev_offsetition of thread in current block,
    // and given the block we are in
    int index = blockIdx.x * blockDim.x + threadIdx.x;

    if ((index < N) && ((index % twod1) == 0)) {
        output[index + twod1 - 1] += output[index + twod -1];    
    }
}

__global__ void
upsweep_small_kernel(int N, int* output) {

    // compute overall index from dev_offsetition of thread in current block,
    // and given the block we are in
    int index = threadIdx.x;

    int num_threads = 1024;
    for(int i=N/1024; i<N; i*=2) {
        if(index < num_threads) {
            output[i*index + i - 1] += output[i*index + i/2 - 1];
        }
        num_threads /= 2;
        __syncthreads();
    }
}

__global__ void
update_result_arr(int N, int* output) {
    output[N-1] = 0; 
}

__global__ void
downsweep_kernel(int N, int twod, int twod1, int* output) {

    int index = blockIdx.x * blockDim.x + threadIdx.x;

    if ((index < N) && ((index % twod1) == 0)) {
        int t = output[index + twod - 1];
         output[index+twod-1] = output[index+twod1-1];
         output[index+twod1-1] += t; // change twod1 to twod to reverse prefix sum.
    }
}

void exclusive_scan(int* device_start, int length, int* device_result)
{
    /* Fill in this function with your exclusive scan implementation.
     * You are passed the locations of the input and output in device memory,
     * but this is host code -- you will need to declare one or more CUDA 
     * kernels (with the __global__ decorator) in order to actually run code
     * in parallel on the GPU.
     * Note you are given the real length of the array, but may assume that
     * both the input and the output arrays are sized to accommodate the next
     * power of 2 larger than the input.
     */

    const int threadsPerBlock = 256; // change this if necessary
    int N = nextPow2(length);
    for(int twod=1; twod<N/2048; twod*=2)  {
        int twod1 = twod*2;
        upsweep_kernel<<<(N + threadsPerBlock - 1)/threadsPerBlock, threadsPerBlock>>>(N, twod, twod1, device_result); 
        gpuErrchk(cudaDeviceSynchronize());
    }

    upsweep_small_kernel<<<1, 1024>>>(N, device_result); 
    gpuErrchk(cudaDeviceSynchronize());

    //device_result[N-1] = 0;
    update_result_arr<<<1, 1>>>(N, device_result);
    gpuErrchk(cudaDeviceSynchronize());


    for(int twod=N/2; twod >=1; twod/=2) {
        int twod1 = twod*2 ;
        downsweep_kernel<<<(N + threadsPerBlock - 1)/threadsPerBlock, threadsPerBlock>>>(N, twod, twod1, device_result); 
        gpuErrchk(cudaDeviceSynchronize());
    }

}

/* This function is a wrapper around the code you will write - it copies the
 * input to the GPU and times the invocation of the exclusive_scan() function
 * above. You should not modify it.
 */
double cudaScan(int* inarray, int* end, int* resultarray)
{
    int* device_result;
    int* device_input; 
    // We round the array sizes up to a power of 2, but elements after
    // the end of the original input are left uninitialized and not checked
    // for correctness. 
    // You may have an easier time in your implementation if you assume the 
    // array's length is a power of 2, but this will result in extra work on
    // non-power-of-2 inputs.
    int rounded_length = nextPow2(end - inarray);
    cudaMalloc((void **)&device_result, sizeof(int) * rounded_length);
    cudaMalloc((void **)&device_input, sizeof(int) * rounded_length);
    cudaMemcpy(device_input, inarray, (end - inarray) * sizeof(int), 
               cudaMemcpyHostToDevice);

    // For convenience, both the input and output vectors on the device are
    // initialized to the input values. This means that you are free to simply
    // implement an in-place scan on the result vector if you wish.
    // If you do this, you will need to keep that fact in mind when calling
    // exclusive_scan from find_repeats.
    cudaMemcpy(device_result, inarray, (end - inarray) * sizeof(int), 
               cudaMemcpyHostToDevice);

    double startTime = CycleTimer::currentSeconds();

    exclusive_scan(device_input, end - inarray, device_result);

    // Wait for any work left over to be completed.
    cudaDeviceSynchronize();
    double endTime = CycleTimer::currentSeconds();
    double overallDuration = endTime - startTime;
    
    cudaMemcpy(resultarray, device_result, (end - inarray) * sizeof(int),
               cudaMemcpyDeviceToHost);
    return overallDuration;
}

/* Wrapper around the Thrust library's exclusive scan function
 * As above, copies the input onto the GPU and times only the execution
 * of the scan itself.
 * You are not expected to produce competitive performance to the
 * Thrust version.
 */
double cudaScanThrust(int* inarray, int* end, int* resultarray) {

    int length = end - inarray;
    thrust::device_ptr<int> d_input = thrust::device_malloc<int>(length);
    thrust::device_ptr<int> d_output = thrust::device_malloc<int>(length);
    
    cudaMemcpy(d_input.get(), inarray, length * sizeof(int), 
               cudaMemcpyHostToDevice);

    double startTime = CycleTimer::currentSeconds();

    thrust::exclusive_scan(d_input, d_input + length, d_output);

    // Wait for any work left over to be completed.
    cudaDeviceSynchronize();
    double endTime = CycleTimer::currentSeconds();

    cudaMemcpy(resultarray, d_output.get(), length * sizeof(int),
               cudaMemcpyDeviceToHost);
    thrust::device_free(d_input);
    thrust::device_free(d_output);
    double overallDuration = endTime - startTime;
    return overallDuration;
}

__global__ void
gen_predicate_kernel(int N, int* input, int* predicate) {

    // compute overall index from dev_offsetition of thread in current block,
    // and given the block we are in
    int index = blockIdx.x * blockDim.x + threadIdx.x;

    //TODO: optimize this. This is too unoptimal!  
    //I think malloc initializes it to 0.. then we can get rid of this line
    if (index == N-1) {
        predicate[index] = 0;
    }

    if (index < N-1) {
        if(input[index] == input[index+1]) {
            predicate[index] = 1;
        } else {
            predicate[index] = 0;
        }
    }

}

__global__ void
process_repeat_kernel(int N, int* output, int* predicate) {

    // compute overall index from dev_offsetition of thread in current block,
    // and given the block we are in
    int index = blockIdx.x * blockDim.x + threadIdx.x;

    if (index < N) {
        if(predicate[index] != predicate[index + 1]) {
            output[predicate[index]] = index;
        }
    }
}

int find_repeats(int *device_input, int length, int *device_output) {
    /* Finds all pairs of adjacent repeated elements in the list, storing the
     * indices of the first element of each pair (in order) into device_result.
     * Returns the number of pairs found.
     * Your task is to implement this function. You will probably want to
     * make use of one or more calls to exclusive_scan(), as well as
     * additional CUDA kernel launches.
     * Note: As in the scan code, we ensure that allocated arrays are a power
     * of 2 in size, so you can use your exclusive_scan function with them if 
     * it requires that. However, you must ensure that the results of
     * find_repeats are correct given the original length.
     */    

    //TODO: how do we ensure it works for original length? 
    int N = nextPow2(length);
    const int threadsPerBlock = 256; // change this if necessary
   
    /* 
    //Debug
    int *predicate_cpu_arr = (int*) malloc(length*sizeof(int));
    gpuErrchk(cudaMemcpy(predicate_cpu_arr, device_input, length*sizeof(int), cudaMemcpyDeviceToHost));
    gpuErrchk(cudaDeviceSynchronize());
    for(int i=0; i<length; i++) {
        printf("Array of input before scan : a[%d] = %d\n", i, predicate_cpu_arr[i]);
    }
    cudaFree(predicate_cpu_arr);
    */

    //Gen predicate    : keeping it N sized array to make exclusive scan easier
    int *predicate_arr;
    gpuErrchk(cudaMalloc(&predicate_arr, N*sizeof(float)));
    gen_predicate_kernel<<<(N + threadsPerBlock - 1)/threadsPerBlock, threadsPerBlock>>>(N, device_input, predicate_arr);
    gpuErrchk(cudaDeviceSynchronize());

    //Do exclusive scan
    exclusive_scan(device_input, length, predicate_arr);
    
    //Parallely get the value of predicate array's last element
    //Reading the value only after length.. 
    int *predicate_size = new int[1];
    gpuErrchk(cudaMemcpy(predicate_size, predicate_arr+length-1, sizeof(int), cudaMemcpyDeviceToHost));

    //Process result to find repeats
    process_repeat_kernel<<<(length + threadsPerBlock - 1)/threadsPerBlock, threadsPerBlock>>>(length, device_output, predicate_arr);
    gpuErrchk(cudaDeviceSynchronize());

    int ret_len = predicate_size[0]; 
    cudaFree(predicate_arr);
    cudaFree(predicate_size);
    return ret_len;
}

/* Timing wrapper around find_repeats. You should not modify this function.
 */
double cudaFindRepeats(int *input, int length, int *output, int *output_length) {
    int *device_input;
    int *device_output;
    int rounded_length = nextPow2(length);
    cudaMalloc((void **)&device_input, rounded_length * sizeof(int));
    cudaMalloc((void **)&device_output, rounded_length * sizeof(int));
    cudaMemcpy(device_input, input, length * sizeof(int), 
               cudaMemcpyHostToDevice);

    double startTime = CycleTimer::currentSeconds();
    
    int result = find_repeats(device_input, length, device_output);

    // Wait for any work left over to be completed.
    cudaDeviceSynchronize();
    double endTime = CycleTimer::currentSeconds();

    *output_length = result;

    cudaMemcpy(output, device_output, length * sizeof(int),
               cudaMemcpyDeviceToHost);

    cudaFree(device_input);
    cudaFree(device_output);

    return endTime - startTime;
}

void printCudaInfo()
{
    // for fun, just print out some stats on the machine

    int deviceCount = 0;
    cudaError_t err = cudaGetDeviceCount(&deviceCount);

    printf("---------------------------------------------------------\n");
    printf("Found %d CUDA devices\n", deviceCount);

    for (int i=0; i<deviceCount; i++)
    {
        cudaDeviceProp deviceProps;
        cudaGetDeviceProperties(&deviceProps, i);
        printf("Device %d: %s\n", i, deviceProps.name);
        printf("   SMs:        %d\n", deviceProps.multiProcessorCount);
        printf("   Global mem: %.0f MB\n",
               static_cast<float>(deviceProps.totalGlobalMem) / (1024 * 1024));
        printf("   CUDA Cap:   %d.%d\n", deviceProps.major, deviceProps.minor);
    }
    printf("---------------------------------------------------------\n"); 
}
