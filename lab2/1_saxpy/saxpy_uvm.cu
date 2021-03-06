#include <stdio.h>

#include <cuda.h>
#include <cuda_runtime.h>
#include <driver_functions.h>

#include "CycleTimer.h"
#include "saxpy.h"

__global__ void
saxpy_kernel(long N, float alpha, float* x, float* y, float* result) {

    // compute overall index from position of thread in current block,
    // and given the block we are in
    long index = blockIdx.x * blockDim.x + threadIdx.x;

    if (index < N)
       result[index] = alpha * x[index] + y[index];
}
void 
getArrays(long size, float **xarray, float **yarray, float **resultarray) {
    cudaError_t err_x = cudaMallocManaged(xarray, size*sizeof(float));
    if(err_x != cudaSuccess) {
        fprintf(stderr,"%s in %s at line %d\n", cudaGetErrorString(err_x),__FILE__,__LINE__);
        exit(EXIT_FAILURE);
    }

    cudaError_t err_y = cudaMallocManaged(yarray, size*sizeof(float));
    if(err_y != cudaSuccess) {
        fprintf(stderr,"%s in %s at line %d\n", cudaGetErrorString(err_y),__FILE__,__LINE__);
        exit(EXIT_FAILURE);
    }
    cudaError_t err_res = cudaMallocManaged(resultarray, size*sizeof(float));
    if(err_res != cudaSuccess) {
        fprintf(stderr,"%s in %s at line %d\n", cudaGetErrorString(err_res),__FILE__,__LINE__);
        exit(EXIT_FAILURE);
    }
}

void 
freeArrays(float *xarray, float *yarray, float *resultarray) {
  // TODO: implement and use this interface if necessary  
    cudaFree(xarray);
    cudaFree(yarray);
    cudaFree(resultarray);
}
void
saxpyCuda(long total_elems, float alpha, float* xarray, float* yarray, float* resultarray, int partitions) {

    const int threadsPerBlock = 512; // change this if necessary


    //
    // TODO: do we need to allocate device memory buffers on the GPU here?
    //


    // start timing after allocation of device memory.
    double startTime = CycleTimer::currentSeconds();

  
    const int numBlocks = (total_elems-1)/threadsPerBlock + 1;
    //
    // TODO: do we need copy here?
    //
     
    //
    // TODO: insert time here to begin timing only the kernel
    //
    double startGPUTime = CycleTimer::currentSeconds();
    // compute number of blocks and threads per block

    // run saxpy_kernel on the GPU
    saxpy_kernel<<<numBlocks,threadsPerBlock>>>(total_elems, alpha, xarray, yarray, resultarray);    
    //
    // TODO: insert timer here to time only the kernel.  Since the
    // kernel will run asynchronously with the calling CPU thread, you
    // need to call cudaDeviceSynchronize() before your timer to
    // ensure the kernel running on the GPU has completed.  (Otherwise
    // you will incorrectly observe that almost no time elapses!)
    //
    // cudaDeviceSynchronize();

    cudaError_t err_sync = cudaDeviceSynchronize();
    if(err_sync != cudaSuccess) {
        fprintf(stderr,"%s in %s at line %d\n", cudaGetErrorString(err_sync),__FILE__,__LINE__);
        exit(EXIT_FAILURE);
    }
   
    double endGPUTime = CycleTimer::currentSeconds();
    timeKernelAvg += endGPUTime - startGPUTime;
    
    cudaError_t errCode = cudaPeekAtLastError();
    if (errCode != cudaSuccess) {
        fprintf(stderr, "WARNING: A CUDA error occured: code=%d, %s\n", errCode, cudaGetErrorString(errCode));
    }
    
    //
    // TODO: copy result from GPU using cudaMemcpy
    //

    // What would be copy time when we use UVM?
    double endTime = CycleTimer::currentSeconds();
    double overallDuration = endTime - startTime;
    totalTimeAvg   += overallDuration;

    //
    // TODO free device memory if you allocate some device memory earlier in this function.
    //
}

void
printCudaInfo() {

    // for fun, just print out some stats on the machine

    int deviceCount = 0;
    cudaError_t err = cudaGetDeviceCount(&deviceCount);

    printf("---------------------------------------------------------\n");
    printf("Found %d CUDA devices\n", deviceCount);

    for (int i=0; i<deviceCount; i++) {
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
