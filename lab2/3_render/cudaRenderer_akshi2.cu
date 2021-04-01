#include <string>
#include <algorithm>
#include <math.h>
#include <stdio.h>
#include <vector>

#include <cuda.h>
#include <cuda_runtime.h>
#include <driver_functions.h>
#include "circleBoxTest.cu_inl"

#include <thrust/scan.h>
#include <thrust/device_ptr.h>
#include <thrust/device_malloc.h>
#include <thrust/device_free.h>
#include <thrust/device_vector.h>
#include <thrust/copy.h>
#include <thrust/reduce.h>
#include <thrust/functional.h>

//TODO: not sure if this block is needed
#include <thrust/host_vector.h>
#include <thrust/generate.h>
#include <thrust/random.h>

#include "cudaRenderer.h"
#include "image.h"
#include "noise.h"
#include "sceneLoader.h"
#include "util.h"


#define gpuErrchk(ans) { gpuAssert((ans), __FILE__, __LINE__); }
inline void gpuAssert(cudaError_t code, const char *file, int line, bool abort=true)
{
   if (code != cudaSuccess) 
   {
      fprintf(stderr,"GPUassert: %s %s %d\n", cudaGetErrorString(code), file, line);
      if (abort) exit(code);
   }
}


////////////////////////////////////////////////////////////////////////////////////////
// Putting all the cuda kernels here
///////////////////////////////////////////////////////////////////////////////////////

struct GlobalConstants {

    SceneName sceneName;

    int numCircles;
    float* position;
    float* velocity;
    float* color;
    float* radius;

    int imageWidth;
    int imageHeight;
    float invWidth;
    float invHeight;
    float* imageData;
};

// Global variable that is in scope, but read-only, for all cuda
// kernels.  The __constant__ modifier designates this variable will
// be stored in special "constant" memory on the GPU. (we didn't talk
// about this type of memory in class, but constant memory is a fast
// place to put read-only variables).
__constant__ GlobalConstants cuConstRendererParams;

// read-only lookup tables used to quickly compute noise (needed by
// advanceAnimation for the snowflake scene)
__constant__ int    cuConstNoiseYPermutationTable[256];
__constant__ int    cuConstNoiseXPermutationTable[256];
__constant__ float  cuConstNoise1DValueTable[256];
// color ramp table needed for the color ramp lookup shader
#define COLOR_MAP_SIZE 5
__constant__ float  cuConstColorRamp[COLOR_MAP_SIZE][3];


// including parts of the CUDA code from external files to keep this
// file simpler and to seperate code that should not be modified
#include "noiseCuda.cu_inl"
#include "lookupColor.cu_inl"


// kernelClearImageSnowflake -- (CUDA device code)
//
// Clear the image, setting the image to the white-gray gradation that
// is used in the snowflake image
__global__ void kernelClearImageSnowflake() {

    int imageX = blockIdx.x * blockDim.x + threadIdx.x;
    int imageY = blockIdx.y * blockDim.y + threadIdx.y;

    int width = cuConstRendererParams.imageWidth;
    int height = cuConstRendererParams.imageHeight;

    if (imageX >= width || imageY >= height)
        return;

    int offset = 4 * (imageY * width + imageX);
    float shade = .4f + .45f * static_cast<float>(height-imageY) / height;
    float4 value = make_float4(shade, shade, shade, 1.f);

    // write to global memory: As an optimization, I use a float4
    // store, that results in more efficient code than if I coded this
    // up as four seperate fp32 stores.
    *(float4*)(&cuConstRendererParams.imageData[offset]) = value;
}

// kernelClearImage --  (CUDA device code)
//
// Clear the image, setting all pixels to the specified color rgba
__global__ void kernelClearImage(float r, float g, float b, float a) {

    int imageX = blockIdx.x * blockDim.x + threadIdx.x;
    int imageY = blockIdx.y * blockDim.y + threadIdx.y;

    int width = cuConstRendererParams.imageWidth;
    int height = cuConstRendererParams.imageHeight;

    if (imageX >= width || imageY >= height)
        return;

    int offset = 4 * (imageY * width + imageX);
    float4 value = make_float4(r, g, b, a);

    // write to global memory: As an optimization, I use a float4
    // store, that results in more efficient code than if I coded this
    // up as four seperate fp32 stores.
    *(float4*)(&cuConstRendererParams.imageData[offset]) = value;
}

// kernelAdvanceFireWorks
//
// Update the position of the fireworks (if circle is firework)
__global__ void kernelAdvanceFireWorks() {
    const float dt = 1.f / 60.f;
    const float pi = 3.14159;
    const float maxDist = 0.25f;

    float* velocity = cuConstRendererParams.velocity;
    float* position = cuConstRendererParams.position;
    float* radius = cuConstRendererParams.radius;

    int index = blockIdx.x * blockDim.x + threadIdx.x;
    if (index >= cuConstRendererParams.numCircles)
        return;

    if (0 <= index && index < NUM_FIREWORKS) { // firework center; no update
        return;
    }

    // determine the fire-work center/spark indices
    int fIdx = (index - NUM_FIREWORKS) / NUM_SPARKS;
    int sfIdx = (index - NUM_FIREWORKS) % NUM_SPARKS;

    int index3i = 3 * fIdx;
    int sIdx = NUM_FIREWORKS + fIdx * NUM_SPARKS + sfIdx;
    int index3j = 3 * sIdx;

    float cx = position[index3i];
    float cy = position[index3i+1];

    // update position
    position[index3j] += velocity[index3j] * dt;
    position[index3j+1] += velocity[index3j+1] * dt;

    // fire-work sparks
    float sx = position[index3j];
    float sy = position[index3j+1];

    // compute vector from firework-spark
    float cxsx = sx - cx;
    float cysy = sy - cy;

    // compute distance from fire-work
    float dist = sqrt(cxsx * cxsx + cysy * cysy);
    if (dist > maxDist) { // restore to starting position
        // random starting position on fire-work's rim
        float angle = (sfIdx * 2 * pi)/NUM_SPARKS;
        float sinA = sin(angle);
        float cosA = cos(angle);
        float x = cosA * radius[fIdx];
        float y = sinA * radius[fIdx];

        position[index3j] = position[index3i] + x;
        position[index3j+1] = position[index3i+1] + y;
        position[index3j+2] = 0.0f;

        // travel scaled unit length
        velocity[index3j] = cosA/5.0;
        velocity[index3j+1] = sinA/5.0;
        velocity[index3j+2] = 0.0f;
    }
}

// kernelAdvanceHypnosis
//
// Update the radius/color of the circles
__global__ void kernelAdvanceHypnosis() {
    int index = blockIdx.x * blockDim.x + threadIdx.x;
    if (index >= cuConstRendererParams.numCircles)
        return;

    float* radius = cuConstRendererParams.radius;

    float cutOff = 0.5f;
    // place circle back in center after reaching threshold radisus
    if (radius[index] > cutOff) {
        radius[index] = 0.02f;
    } else {
        radius[index] += 0.01f;
    }
}


// kernelAdvanceBouncingBalls
//
// Update the positino of the balls
__global__ void kernelAdvanceBouncingBalls() {
    const float dt = 1.f / 60.f;
    const float kGravity = -2.8f; // sorry Newton
    const float kDragCoeff = -0.8f;
    const float epsilon = 0.001f;

    int index = blockIdx.x * blockDim.x + threadIdx.x;

    if (index >= cuConstRendererParams.numCircles)
        return;

    float* velocity = cuConstRendererParams.velocity;
    float* position = cuConstRendererParams.position;

    int index3 = 3 * index;
    // reverse velocity if center position < 0
    float oldVelocity = velocity[index3+1];
    float oldPosition = position[index3+1];

    if (oldVelocity == 0.f && oldPosition == 0.f) { // stop-condition
        return;
    }

    if (position[index3+1] < 0 && oldVelocity < 0.f) { // bounce ball
        velocity[index3+1] *= kDragCoeff;
    }

    // update velocity: v = u + at (only along y-axis)
    velocity[index3+1] += kGravity * dt;

    // update positions (only along y-axis)
    position[index3+1] += velocity[index3+1] * dt;

    if (fabsf(velocity[index3+1] - oldVelocity) < epsilon
        && oldPosition < 0.0f
        && fabsf(position[index3+1]-oldPosition) < epsilon) { // stop ball
        velocity[index3+1] = 0.f;
        position[index3+1] = 0.f;
    }
}

// kernelAdvanceSnowflake -- (CUDA device code)
//
// move the snowflake animation forward one time step.  Updates circle
// positions and velocities.  Note how the position of the snowflake
// is reset if it moves off the left, right, or bottom of the screen.
__global__ void kernelAdvanceSnowflake() {

    int index = blockIdx.x * blockDim.x + threadIdx.x;

    if (index >= cuConstRendererParams.numCircles)
        return;

    const float dt = 1.f / 60.f;
    const float kGravity = -1.8f; // sorry Newton
    const float kDragCoeff = 2.f;

    int index3 = 3 * index;

    float* positionPtr = &cuConstRendererParams.position[index3];
    float* velocityPtr = &cuConstRendererParams.velocity[index3];

    // loads from global memory
    float3 position = *((float3*)positionPtr);
    float3 velocity = *((float3*)velocityPtr);

    // hack to make farther circles move more slowly, giving the
    // illusion of parallax
    float forceScaling = fmin(fmax(1.f - position.z, .1f), 1.f); // clamp

    // add some noise to the motion to make the snow flutter
    float3 noiseInput;
    noiseInput.x = 10.f * position.x;
    noiseInput.y = 10.f * position.y;
    noiseInput.z = 255.f * position.z;
    float2 noiseForce = cudaVec2CellNoise(noiseInput, index);
    noiseForce.x *= 7.5f;
    noiseForce.y *= 5.f;

    // drag
    float2 dragForce;
    dragForce.x = -1.f * kDragCoeff * velocity.x;
    dragForce.y = -1.f * kDragCoeff * velocity.y;

    // update positions
    position.x += velocity.x * dt;
    position.y += velocity.y * dt;

    // update velocities
    velocity.x += forceScaling * (noiseForce.x + dragForce.y) * dt;
    velocity.y += forceScaling * (kGravity + noiseForce.y + dragForce.y) * dt;

    float radius = cuConstRendererParams.radius[index];

    // if the snowflake has moved off the left, right or bottom of
    // the screen, place it back at the top and give it a
    // pseudorandom x position and velocity.
    if ( (position.y + radius < 0.f) ||
         (position.x + radius) < -0.f ||
         (position.x - radius) > 1.f)
    {
        noiseInput.x = 255.f * position.x;
        noiseInput.y = 255.f * position.y;
        noiseInput.z = 255.f * position.z;
        noiseForce = cudaVec2CellNoise(noiseInput, index);

        position.x = .5f + .5f * noiseForce.x;
        position.y = 1.35f + radius;

        // restart from 0 vertical velocity.  Choose a
        // pseudo-random horizontal velocity.
        velocity.x = 2.f * noiseForce.y;
        velocity.y = 0.f;
    }

    // store updated positions and velocities to global memory
    *((float3*)positionPtr) = position;
    *((float3*)velocityPtr) = velocity;
}

__device__ __inline__ void
shadePixelSmallCircles(int circleIndex, float2 pixelCenter, float3 p, float4* imagePtr) {

    float diffX = p.x - pixelCenter.x;
    float diffY = p.y - pixelCenter.y;
    float pixelDist = diffX * diffX + diffY * diffY;

    float rad = cuConstRendererParams.radius[circleIndex];;
    float maxDist = rad * rad;

    // circle does not contribute to the image
    if (pixelDist > maxDist)
        return;

    float3 rgb;
    float alpha;

    // there is a non-zero contribution.  Now compute the shading value

    // This conditional is in the inner loop, but it evaluates the
    // same direction for all threads so it's cost is not so
    // bad. Attempting to hoist this conditional is not a required
    // student optimization in Assignment 2
    if (cuConstRendererParams.sceneName == SNOWFLAKES || cuConstRendererParams.sceneName == SNOWFLAKES_SINGLE_FRAME) {

        const float kCircleMaxAlpha = .5f;
        const float falloffScale = 4.f;

        float normPixelDist = sqrt(pixelDist) / rad;
        rgb = lookupColor(normPixelDist);

        float maxAlpha = .6f + .4f * (1.f-p.z);
        maxAlpha = kCircleMaxAlpha * fmaxf(fminf(maxAlpha, 1.f), 0.f); // kCircleMaxAlpha * clamped value
        alpha = maxAlpha * exp(-1.f * falloffScale * normPixelDist * normPixelDist);

    } else {
        // simple: each circle has an assigned color
        int index3 = 3 * circleIndex;
        rgb = *(float3*)&(cuConstRendererParams.color[index3]);
        alpha = .5f;
    }

    float oneMinusAlpha = 1.f - alpha;

    // BEGIN SHOULD-BE-ATOMIC REGION
    // global memory read

    float4 existingColor = *imagePtr;
    float4 newColor;
    newColor.x = alpha * rgb.x + oneMinusAlpha * existingColor.x;
    newColor.y = alpha * rgb.y + oneMinusAlpha * existingColor.y;
    newColor.z = alpha * rgb.z + oneMinusAlpha * existingColor.z;
    newColor.w = alpha + existingColor.w;

    // global memory write
    *imagePtr = newColor;

    // END SHOULD-BE-ATOMIC REGION
}



// shadePixel -- (CUDA device code)
//
// given a pixel and a circle, determines the contribution to the
// pixel from the circle.  Update of the image is done in this
// function.  Called by kernelRenderCircles()
__device__ __inline__ void
shadePixel(int circleIndex, float2 pixelCenter, float3 p, float& redPix, float& greenPix, float& bluePix, float& alphaPix) {
//shadePixel(int circleIndex, float2 pixelCenter, float3 p, float4* imagePtr) {


    float diffX = p.x - pixelCenter.x;
    float diffY = p.y - pixelCenter.y;
    float pixelDist = diffX * diffX + diffY * diffY;

    float rad = cuConstRendererParams.radius[circleIndex];;
    float maxDist = rad * rad;

    // circle does not contribute to the image
    if (pixelDist > maxDist)
        return;

    float3 rgb;
    float alpha;

    // there is a non-zero contribution.  Now compute the shading value

    // This conditional is in the inner loop, but it evaluates the
    // same direction for all threads so it's cost is not so
    // bad. Attempting to hoist this conditional is not a required
    // student optimization in Assignment 2
    if (cuConstRendererParams.sceneName == SNOWFLAKES || cuConstRendererParams.sceneName == SNOWFLAKES_SINGLE_FRAME) {

        const float kCircleMaxAlpha = .5f;
        const float falloffScale = 4.f;

        float normPixelDist = sqrt(pixelDist) / rad;
        rgb = lookupColor(normPixelDist);

        float maxAlpha = .6f + .4f * (1.f-p.z);
        maxAlpha = kCircleMaxAlpha * fmaxf(fminf(maxAlpha, 1.f), 0.f); // kCircleMaxAlpha * clamped value
        alpha = maxAlpha * exp(-1.f * falloffScale * normPixelDist * normPixelDist);

    } else {
        // simple: each circle has an assigned color
        int index3 = 3 * circleIndex;
        rgb = *(float3*)&(cuConstRendererParams.color[index3]);
        alpha = .5f;
    }

    float oneMinusAlpha = 1.f - alpha;

    // BEGIN SHOULD-BE-ATOMIC REGION
    // global memory read
    //TODO: why in 2 steps -- is it to avoid some hazard???!!
    /*
    float4 existingColor = *imagePtr;
    float4 newColor;
    newColor.x = alpha * rgb.x + oneMinusAlpha * existingColor.x;
    newColor.y = alpha * rgb.y + oneMinusAlpha * existingColor.y;
    newColor.z = alpha * rgb.z + oneMinusAlpha * existingColor.z;
    newColor.w = alpha + existingColor.w;

    // global memory write
    *imagePtr = newColor;
    */

    redPix = alpha * rgb.x + oneMinusAlpha * redPix;
    greenPix = alpha * rgb.y + oneMinusAlpha * greenPix;
    bluePix = alpha * rgb.z + oneMinusAlpha * bluePix;
    alphaPix = alpha + alphaPix;

    // END SHOULD-BE-ATOMIC REGION
}

// kernelRenderCircles -- (CUDA device code)
//
// Each thread renders a circle.  Since there is no protection to
// ensure order of update or mutual exclusion on the output image, the
// resulting image will be incorrect.


__global__ void kernelRenderCircles(int* circleImgBlockList, int* circleStartAddr) {
    const int sharedSize = 2850;
    const int totalThreads = blockDim.x * blockDim.y;
     __shared__ int sharedData[sharedSize];
    float invWidth = cuConstRendererParams.invWidth;
    float invHeight = cuConstRendererParams.invHeight;
    int imageWidth = cuConstRendererParams.imageWidth;
    int imageHeight = cuConstRendererParams.imageHeight;

    int start_addr = circleStartAddr[blockIdx.y*gridDim.x + blockIdx.x];
    int end_addr= circleStartAddr[blockIdx.y*gridDim.x + blockIdx.x + 1];
    int sharedCirclePairs = end_addr - start_addr;
  
    int data_per_thread;
    int sharedDataOverhead = 0;

    if(sharedCirclePairs<sharedSize)
       data_per_thread = (end_addr-start_addr + totalThreads-1)/totalThreads;
    else{
       data_per_thread = (sharedSize+totalThreads-1)/totalThreads;
       sharedDataOverhead = 1;
    }
    for(int i=0; i < data_per_thread; i++ ){
      int tid = threadIdx.y * blockDim.y + threadIdx.x;
      if(tid < sharedCirclePairs  && (i + data_per_thread * tid) < sharedSize){
         sharedData[i + data_per_thread * tid] = circleImgBlockList[start_addr + i + data_per_thread * tid]; 
      }
    }
    __syncthreads();

    if(sharedCirclePairs){

                int x = blockIdx.x*(imageWidth/gridDim.x) + threadIdx.x + 16*(blockIdx.z % 4);
                int y = blockIdx.y*(imageHeight/gridDim.y) + threadIdx.y + 16*(blockIdx.z / 4);
                float red_pixel = cuConstRendererParams.imageData[(4 * (y * imageWidth + x))];
                float green_pixel = cuConstRendererParams.imageData[(4 * (y * imageWidth + x)) + 1];
                float blue_pixel = cuConstRendererParams.imageData[(4 * (y * imageWidth + x)) + 2];
                float alpha_pixel = cuConstRendererParams.imageData[(4 * (y * imageWidth + x)) + 3]; 
                float2 pixelCenterNorm = make_float2(invWidth * (static_cast<float>(x) + 0.5f),
                                                                 invHeight * (static_cast<float>(y) + 0.5f));
                
                //k*# of pixels, added with linear thread ID 
                //Unrolled the k loop to avoid loop overhead
                int index ;
                for (int arrIdx = start_addr; arrIdx < end_addr; arrIdx++) {
                    if(sharedDataOverhead && ((arrIdx - start_addr) >= sharedSize))
                        index = circleImgBlockList[arrIdx] - 1;
                    else
                        index = sharedData[arrIdx-start_addr] - 1;
                    int index3 = 3 * index;
                    float3 p = *(float3*)(&cuConstRendererParams.position[index3]);
                    //float rad = cuConstRendererParams.radius[index];
                    shadePixel(index, pixelCenterNorm, p, red_pixel, green_pixel, blue_pixel, alpha_pixel);

                 }
                 __syncthreads();

                
                 cuConstRendererParams.imageData[4 * (y * imageWidth + x)] = red_pixel;
                 cuConstRendererParams.imageData[4 * (y * imageWidth + x) + 1] = green_pixel;
                 cuConstRendererParams.imageData[4 * (y * imageWidth + x) + 2 ] = blue_pixel;
                 cuConstRendererParams.imageData[4 * (y * imageWidth + x) + 3 ] = alpha_pixel;
        
            }
}


__global__ void kernelRenderCircles_pattern(int sharedMem_size) {
    float invWidth = cuConstRendererParams.invWidth;
    float invHeight = cuConstRendererParams.invHeight;
    int imageWidth = cuConstRendererParams.imageWidth;
    int imageHeight = cuConstRendererParams.imageHeight;
    int numCircles = cuConstRendererParams.numCircles;
    //extern __shared__ int circleList[];
    //extern __shared__ int circleScan[];
    //extern __shared__ int final_circleList[];

    extern __shared__ int circleGlobal[];

    int threadsPerBlock = blockDim.x * blockDim.y;

    for (int i = 0; i < sharedMem_size ; i += threadsPerBlock ) {
        int tid = i + threadIdx.y * blockDim.x + threadIdx.x;
        int index3 = 3 * tid;
        float3 p = *(float3*)(&cuConstRendererParams.position[index3]);
        float rad = cuConstRendererParams.radius[tid];
        if (tid < numCircles) {
            int circleInBox = circleInBoxConservative(p.x, p.y, rad, 
                              static_cast<float>(1.f/gridDim.x)*blockIdx.x, static_cast<float>(1.f/gridDim.x)*(blockIdx.x+1), 
                              static_cast<float>(1.f/gridDim.y)*(blockIdx.y+1), static_cast<float>(1.f/gridDim.y)*(blockIdx.y));
            circleGlobal[tid] = circleInBox ? (tid+1) : 0;
            circleGlobal[sharedMem_size +tid] = circleInBox;
            //if(blockIdx.x + blockIdx.y == 0) {
            //    printf("tid = %d, circleInBox = %d, circleList[%d] = %d\n", tid, circleInBox, tid, circleGlobal[tid]);
            //}
        } else {
            circleGlobal[tid] = 0;
            circleGlobal[sharedMem_size +tid] = 0;
        }
        

    }
    __syncthreads();
    //Perform scan on circlePresent
    int previous = 0;
    int current = 0;
    for (int i = 0; i < sharedMem_size ; i += threadsPerBlock ) {
        int tid = i + threadIdx.y * blockDim.x + threadIdx.x;
        int local_tid = threadIdx.y * blockDim.x + threadIdx.x;

        if (local_tid == 0) {
            current = circleGlobal[sharedMem_size +i + threadsPerBlock -1];
        }
        
        for (int twod = 1; twod < threadsPerBlock; twod *= 2) {
            int twod1 = 2*twod;
           if(local_tid < threadsPerBlock && ((local_tid % twod1) == 0)) {
                circleGlobal[sharedMem_size +local_tid + twod1 -1 + i] += circleGlobal[sharedMem_size +local_tid + twod -1 + i];
           }
        }
        __syncthreads();
        if(local_tid == 0) {circleGlobal[sharedMem_size +threadsPerBlock  - 1 + i] = 0;}
         __syncthreads(); 
        for(int twod=threadsPerBlock/2; twod >=1; twod/=2) {
            int twod1 = twod*2 ;
            if ((local_tid < threadsPerBlock) && ((local_tid % twod1) == 0)) {
                int t = circleGlobal[sharedMem_size +local_tid + twod - 1 + i];
                circleGlobal[sharedMem_size +local_tid+twod-1 + i] = circleGlobal[sharedMem_size +local_tid+twod1-1 + i];
                circleGlobal[sharedMem_size +local_tid+twod1-1 + i] += t; // change twod1 to twod to reverse prefix sum.
            }     
        }
        __syncthreads();
        if (i != 0) {
            circleGlobal[sharedMem_size +tid] += circleGlobal[sharedMem_size +i - 1] + previous;
        }
        if(local_tid == 0 ) {
            previous = current;
        }
        __syncthreads();
    }

    //Perform stream compaction
    for (int i =0; i < sharedMem_size; i+= threadsPerBlock) {
        int tid = i + threadIdx.y * blockDim.x + threadIdx.x; 
        if(circleGlobal[tid] != 0) {
            circleGlobal[2*sharedMem_size +circleGlobal[sharedMem_size +tid]] = circleGlobal[tid] - 1; 
        }
    }

   // if (blockIdx.x + blockIdx.y == 0) {
   //     for (int i = 0; i < sharedMem_size ; i += threadsPerBlock ) { 
   //         int tid = i + threadIdx.y * blockDim.x + threadIdx.x;
   //         //if (tid < 257) {
   //             printf("tid = %d, finalCircleList[%d] = %d\n", tid, tid, circleGlobal[2*sharedMem_size +tid]);
   //         //}
   //     }
   // }
    __syncthreads();
    //int start_addr = circleStartAddr[blockIdx.y*gridDim.x + blockIdx.x];
    //int end_addr= circleStartAddr[blockIdx.y*gridDim.x + blockIdx.x + 1];
    int start_addr = 0;
    int end_addr = circleGlobal[sharedMem_size +sharedMem_size - 1];

       //         int x = blockIdx.x*(imageWidth/gridDim.x) + threadIdx.x + 16*(blockIdx.z % 8);
       //         int y = blockIdx.y*(imageHeight/gridDim.y) + threadIdx.y + 16*(blockIdx.z / 8);
                int x = blockIdx.x*(imageWidth/gridDim.x) + threadIdx.x + 16*(blockIdx.z % 4);
                int y = blockIdx.y*(imageHeight/gridDim.y) + threadIdx.y + 16*(blockIdx.z / 4);
                float red_pixel = cuConstRendererParams.imageData[(4 * (y * imageWidth + x))];
                float green_pixel = cuConstRendererParams.imageData[(4 * (y * imageWidth + x)) + 1];
                float blue_pixel = cuConstRendererParams.imageData[(4 * (y * imageWidth + x)) + 2];
                float alpha_pixel = cuConstRendererParams.imageData[(4 * (y * imageWidth + x)) + 3]; 
                float2 pixelCenterNorm = make_float2(invWidth * (static_cast<float>(x) + 0.5f),
                                                                 invHeight * (static_cast<float>(y) + 0.5f));
                
                //k*# of pixels, added with linear thread ID 
                //Unrolled the k loop to avoid loop overhead
                int index ;
                for (int arrIdx = start_addr; arrIdx < end_addr; arrIdx++) {
                        //index = circleImgBlockList[arrIdx] - 1;
                    index = circleGlobal[2*sharedMem_size +arrIdx];
                    int index3 = 3 * index;
                    float3 p = *(float3*)(&cuConstRendererParams.position[index3]);
                    shadePixel(index, pixelCenterNorm, p, red_pixel, green_pixel, blue_pixel, alpha_pixel);

                 }
                 __syncthreads();

                
                 cuConstRendererParams.imageData[4 * (y * imageWidth + x)] = red_pixel;
                 cuConstRendererParams.imageData[4 * (y * imageWidth + x) + 1] = green_pixel;
                 cuConstRendererParams.imageData[4 * (y * imageWidth + x) + 2 ] = blue_pixel;
                 cuConstRendererParams.imageData[4 * (y * imageWidth + x) + 3 ] = alpha_pixel;
        
}
////////////////////////////////////////////////////////////////////////////////////////


CudaRenderer::CudaRenderer() {
    image = NULL;

    numCircles = 0;
    position = NULL;
    velocity = NULL;
    color = NULL;
    radius = NULL;

    cudaDevicePosition = NULL;
    cudaDeviceVelocity = NULL;
    cudaDeviceColor = NULL;
    cudaDeviceRadius = NULL;
    cudaDeviceImageData = NULL;
}

CudaRenderer::~CudaRenderer() {

    if (image) {
        delete image;
    }

    if (position) {
        delete [] position;
        delete [] velocity;
        delete [] color;
        delete [] radius;
    }

    if (cudaDevicePosition) {
        cudaFree(cudaDevicePosition);
        cudaFree(cudaDeviceVelocity);
        cudaFree(cudaDeviceColor);
        cudaFree(cudaDeviceRadius);
        cudaFree(cudaDeviceImageData);
    }
}

const Image*
CudaRenderer::getImage() {

    // need to copy contents of the rendered image from device memory
    // before we expose the Image object to the caller

    printf("Copying image data from device\n");

    cudaMemcpy(image->data,
               cudaDeviceImageData,
               sizeof(float) * 4 * image->width * image->height,
               cudaMemcpyDeviceToHost);

    return image;
}

void
CudaRenderer::loadScene(SceneName scene) {
    sceneName = scene;
    loadCircleScene(sceneName, numCircles, position, velocity, color, radius);
}

void
CudaRenderer::setup() {

    int deviceCount = 0;
    std::string name;
    cudaError_t err = cudaGetDeviceCount(&deviceCount);

    printf("---------------------------------------------------------\n");
    printf("Initializing CUDA for CudaRenderer\n");
    printf("Found %d CUDA devices\n", deviceCount);

    for (int i=0; i<deviceCount; i++) {
        cudaDeviceProp deviceProps;
        cudaGetDeviceProperties(&deviceProps, i);
        name = deviceProps.name;

        printf("Device %d: %s\n", i, deviceProps.name);
        printf("   SMs:        %d\n", deviceProps.multiProcessorCount);
        printf("   Global mem: %.0f MB\n", static_cast<float>(deviceProps.totalGlobalMem) / (1024 * 1024));
        printf("   CUDA Cap:   %d.%d\n", deviceProps.major, deviceProps.minor);
    }
    printf("---------------------------------------------------------\n");

    // By this time the scene should be loaded.  Now copy all the key
    // data structures into device memory so they are accessible to
    // CUDA kernels
    //
    // See the CUDA Programmer's Guide for descriptions of
    // cudaMalloc and cudaMemcpy

    cudaMalloc(&cudaDevicePosition, sizeof(float) * 3 * numCircles);
    cudaMalloc(&cudaDeviceVelocity, sizeof(float) * 3 * numCircles);
    cudaMalloc(&cudaDeviceColor, sizeof(float) * 3 * numCircles);
    cudaMalloc(&cudaDeviceRadius, sizeof(float) * numCircles);
    cudaMalloc(&cudaDeviceImageData, sizeof(float) * 4 * image->width * image->height);

    cudaMemcpy(cudaDevicePosition, position, sizeof(float) * 3 * numCircles, cudaMemcpyHostToDevice);
    cudaMemcpy(cudaDeviceVelocity, velocity, sizeof(float) * 3 * numCircles, cudaMemcpyHostToDevice);
    cudaMemcpy(cudaDeviceColor, color, sizeof(float) * 3 * numCircles, cudaMemcpyHostToDevice);
    cudaMemcpy(cudaDeviceRadius, radius, sizeof(float) * numCircles, cudaMemcpyHostToDevice);

    // Initialize parameters in constant memory.  We didn't talk about
    // constant memory in class, but the use of read-only constant
    // memory here is an optimization over just sticking these values
    // in device global memory.  NVIDIA GPUs have a few special tricks
    // for optimizing access to constant memory.  Using global memory
    // here would have worked just as well.  See the Programmer's
    // Guide for more information about constant memory.

    GlobalConstants params;
    params.sceneName = sceneName;
    params.numCircles = numCircles;
    params.imageWidth = image->width;
    params.imageHeight = image->height;
    params.invWidth  = 1.f / image->width;
    params.invHeight =1.f/image->height;
    params.position = cudaDevicePosition;
    params.velocity = cudaDeviceVelocity;
    params.color = cudaDeviceColor;
    params.radius = cudaDeviceRadius;
    params.imageData = cudaDeviceImageData;

    cudaMemcpyToSymbol(cuConstRendererParams, &params, sizeof(GlobalConstants));

    // also need to copy over the noise lookup tables, so we can
    // implement noise on the GPU
    int* permX;
    int* permY;
    float* value1D;
    getNoiseTables(&permX, &permY, &value1D);
    cudaMemcpyToSymbol(cuConstNoiseXPermutationTable, permX, sizeof(int) * 256);
    cudaMemcpyToSymbol(cuConstNoiseYPermutationTable, permY, sizeof(int) * 256);
    cudaMemcpyToSymbol(cuConstNoise1DValueTable, value1D, sizeof(float) * 256);

    // last, copy over the color table that's used by the shading
    // function for circles in the snowflake demo

    float lookupTable[COLOR_MAP_SIZE][3] = {
        {1.f, 1.f, 1.f},
        {1.f, 1.f, 1.f},
        {.8f, .9f, 1.f},
        {.8f, .9f, 1.f},
        {.8f, 0.8f, 1.f},
    };

    cudaMemcpyToSymbol(cuConstColorRamp, lookupTable, sizeof(float) * 3 * COLOR_MAP_SIZE);

}

// allocOutputImage --
//
// Allocate buffer the renderer will render into.  Check status of
// image first to avoid memory leak.
void
CudaRenderer::allocOutputImage(int width, int height) {

    if (image)
        delete image;
    image = new Image(width, height);
}

// clearImage --
//
// Clear's the renderer's target image.  The state of the image after
// the clear depends on the scene being rendered.
void
CudaRenderer::clearImage() {

    // 256 threads per block is a healthy number
    dim3 blockDim(16, 16, 1);
    dim3 gridDim(
        (image->width + blockDim.x - 1) / blockDim.x,
        (image->height + blockDim.y - 1) / blockDim.y);

    if (sceneName == SNOWFLAKES || sceneName == SNOWFLAKES_SINGLE_FRAME) {
        kernelClearImageSnowflake<<<gridDim, blockDim>>>();
    } else {
        kernelClearImage<<<gridDim, blockDim>>>(1.f, 1.f, 1.f, 1.f);
    }
    cudaDeviceSynchronize();
}

// advanceAnimation --
//
// Advance the simulation one time step.  Updates all circle positions
// and velocities
void
CudaRenderer::advanceAnimation() {
     // 256 threads per block is a healthy number
    dim3 blockDim(256, 1);
    dim3 gridDim((numCircles + blockDim.x - 1) / blockDim.x);

    // only the snowflake scene has animation
    if (sceneName == SNOWFLAKES) {
        kernelAdvanceSnowflake<<<gridDim, blockDim>>>();
    } else if (sceneName == BOUNCING_BALLS) {
        kernelAdvanceBouncingBalls<<<gridDim, blockDim>>>();
    } else if (sceneName == HYPNOSIS) {
        kernelAdvanceHypnosis<<<gridDim, blockDim>>>();
    } else if (sceneName == FIREWORKS) {
        kernelAdvanceFireWorks<<<gridDim, blockDim>>>();
    }
    cudaDeviceSynchronize();
}

__global__ void make_circleImgBlockArray(int *circleImgBlockArray, int *circleImgBlockId, int imgBlockWidth, int imgBlockNum) {
   int index = blockIdx.x * blockDim.x + threadIdx.x; 
   if (index >= cuConstRendererParams.numCircles)
        return;

    int index3 = 3 * index;
    //printf("Index : %d\n", index);

    // read position and radius
    float3 p = *(float3*)(&cuConstRendererParams.position[index3]);
    float  rad = cuConstRendererParams.radius[index];

    // compute the bounding box of the circle. The bound is in integer
    // screen coordinates, so it's clamped to the edges of the screen.
    short imageWidth = cuConstRendererParams.imageWidth;
    short imageHeight = cuConstRendererParams.imageHeight;
    short minX = static_cast<short>(imageWidth * (p.x - rad));
    short maxX = static_cast<short>(imageWidth * (p.x + rad)) + 1;
    short minY = static_cast<short>(imageHeight * (p.y - rad));
    short maxY = static_cast<short>(imageHeight * (p.y + rad)) + 1;

    // a bunch of clamps.  Is there a CUDA built-in for this?
    short screenMinX = (minX > 0) ? ((minX < imageWidth) ? minX : imageWidth) : 0;
    short screenMaxX = (maxX > 0) ? ((maxX < imageWidth) ? maxX : imageWidth) : 0;
    short screenMinY = (minY > 0) ? ((minY < imageHeight) ? minY : imageHeight) : 0;
    short screenMaxY = (maxY > 0) ? ((maxY < imageHeight) ? maxY : imageHeight) : 0;

    /* 
    printf("MinX = %d\n",screenMinX/imgBlockWidth);
    printf("MaxX = %d\n",screenMaxX/imgBlockWidth);
    printf("MinY = %d\n",screenMinY/imgBlockWidth);
    printf("MaxY = %d\n",screenMaxY/imgBlockWidth);
    */


    for (short x = (screenMinX/imgBlockWidth); x  <= (screenMaxX/imgBlockWidth); x++) {
        for (short y = (screenMinY/imgBlockWidth); y <= (screenMaxY/imgBlockWidth); y++) {
            if((x == imgBlockNum) || (y == imgBlockNum)) { continue;}
            circleImgBlockArray[(y*imgBlockNum + x) *(cuConstRendererParams.numCircles) + index] = 1;
            circleImgBlockId[(y*imgBlockNum + x) *(cuConstRendererParams.numCircles) + index] = index+1;
            //printf("Index = %d %d %d\n", x, y, index);
            //printf("HERE!!!!\n");
        }
    }

}

__global__ void print_kernel(int length, int* input) {
    printf("HERE\n");
    for(int i=0; i< length; i++) {
        printf("input[%d] = %d\n", i, input[i]);
    }
}

__global__ void compare_array(int length, int* array1, int* array2) {
    for(int i=0; i< length; i++) {
        if(array1[i] != array2[i]) {
            printf("Arrays don't match. Expected = %d, Got = %d\n", array1[i], array2[i]);
        }
    }
}

__global__ void getRefCircleArray(int* refCircleImgArray) {
    for (int index = 0; index < cuConstRendererParams.numCircles; index++) {
        int index3 = 3 * index;
        float3 p = *(float3*)(&cuConstRendererParams.position[index3]);

        float rad = cuConstRendererParams.radius[index];
        // BlockDim = 256 x1, gridDim = 4x4

        int circleInBox = circleInBoxConservative(p.x, p.y, rad, 
            static_cast<float>(1.f/gridDim.x)*blockIdx.x, static_cast<float>(1.f/gridDim.x)*(blockIdx.x+1), 
            static_cast<float>(1.f/gridDim.y)*(blockIdx.y+1), static_cast<float>(1.f/gridDim.y)*(blockIdx.y));

        //printf("ID: %d\n" , index + (blockIdx.x + blockIdx.y*gridDim.x)*cuConstRendererParams.numCircles);
        refCircleImgArray[index + (blockIdx.x + blockIdx.y*gridDim.x)*cuConstRendererParams.numCircles] = circleInBox;
    }
}

//predicate functor
template <typename T>
struct is_not_zero : public thrust::unary_function<T,bool>
{
    __host__  __device__
        bool operator()(T x)
    {
        return (x != 0);
    }
};

// convert a linear index to + data_per_thread * tid a row index
template <typename T>
struct linear_index_to_row_index : public thrust::unary_function<T,T>
{
  T C; // number of columns
  
  __host__ __device__
  linear_index_to_row_index(T C) : C(C) {}

  __host__ __device__
  T operator()(T i)
  {
    return i / C;
  }
};


__global__ void kernelRenderSmallCircles(int index, int imageWidth, int imageHeight, int screenMinX, int screenMinY, int screenMaxX, int screenMaxY) {

    float invWidth = 1.f / imageWidth;
    float invHeight = 1.f / imageHeight;
    int index3 = 3 * index;
    float3 p = *(float3*)(&cuConstRendererParams.position[index3]);

    int x = blockIdx.x*blockDim.x + threadIdx.x + screenMinX;
    int y = blockIdx.y*blockDim.y + threadIdx.y + screenMinY;
    if(x >= screenMaxX) return;
    if(y >= screenMaxY) return;
    /*
    const unsigned int offset = blockIdx.x*blockDim.x + threadIdx.x;
    if(offset >= (screenMaxX - screenMinX) * (screenMaxY - screenMinY)) return;
    int x = (offset % (screenMaxX - screenMinX)) + screenMinX;
    int y = (offset / (screenMaxX - screenMinX)) + screenMinY;
    */
    float4* imgPtr = (float4*)(&cuConstRendererParams.imageData[4 * (y * imageWidth + x)]);
    float2 pixelCenterNorm = make_float2(invWidth * (static_cast<float>(x) + 0.5f),
                                                 invHeight * (static_cast<float>(y) + 0.5f));
    shadePixelSmallCircles(index, pixelCenterNorm, p, imgPtr);
}

void
CudaRenderer::render() {

    // 256 threads per block is a healthy number
    //dim3 blockDim(256, 1);
    //dim3 gridDim((numCircles + blockDim.x - 1) / blockDim.x);


    // compute the bounding box of the circle. The bound is in integer
    // screen coordinates, so it's clamped to the edges of the screen.
    
    short imageWidth = image->width;
    int* circleImgBlockArray = NULL;
    int* circleImgBlockId = NULL;
    //printf("NumCircles = %d\n",numCircles);

   if (numCircles < 5) {
      for (int i = 0; i < numCircles; i++) {
            // read p sition and radius
            int index3 = 3 * i;
            float3 p = *(float3*)(&position[index3]);
            float  rad = radius[i];

            // compute the bounding box of the circle. The bound is in integer
            // screen coordinates, so it's clamped to the edges of the screen.
            short imageWidth = image->width;
            short imageHeight = image->height;
            short minX = static_cast<short>(imageWidth * (p.x - rad));
            short maxX = static_cast<short>(imageWidth * (p.x + rad)) + 1;
            short minY = static_cast<short>(imageHeight * (p.y - rad));
            short maxY = static_cast<short>(imageHeight * (p.y + rad)) + 1;

            // a bunch of clamps.  Is there a CUDA built-in for this?
            short screenMinX = (minX > 0) ? ((minX < imageWidth) ? minX : imageWidth) : 0;
            short screenMaxX = (maxX > 0) ? ((maxX < imageWidth) ? maxX : imageWidth) : 0;
            short screenMinY = (minY > 0) ? ((minY < imageHeight) ? minY : imageHeight) : 0;
            short screenMaxY = (maxY > 0) ? ((maxY < imageHeight) ? maxY : imageHeight) : 0;

            dim3 blockDim(16, 16);
            dim3 gridDim(((screenMaxX - screenMinX) + blockDim.x - 1) / blockDim.x, ((screenMaxY - screenMinY) + blockDim.y - 1) / blockDim.y);

            kernelRenderSmallCircles<<<gridDim, blockDim>>>(i, imageWidth, imageHeight, screenMinX, screenMinY, screenMaxX, screenMaxY);
            gpuErrchk(cudaDeviceSynchronize());
        }
      }
      else if (numCircles < 1500 && numCircles >= 5) {

         int imgBlockNum = 16;

         int numImgBlocks = imgBlockNum * imgBlockNum;
         int numElements = numCircles * imgBlockNum * imgBlockNum;  


        // cudaMalloc(&circleImgBlockArray, sizeof(int) * numElements);
        // cudaMalloc(&circleImgBlockId, sizeof(int) * numElements);
        // //gpuErrchk(cudaDeviceSynchronize());
        // dim3 blockDim(256, 1);
        // dim3 gridDim((numCircles + blockDim.x - 1) / blockDim.x);
        // make_circleImgBlockArray<<<gridDim, blockDim>>>(circleImgBlockArray,circleImgBlockId,imageWidth/imgBlockNum, imgBlockNum);


        // /*Convert the 2D circle block array into 1 D array by removing 0 values  */
        // thrust::device_ptr<int> thrust_arr = thrust::device_pointer_cast(circleImgBlockArray); 
        // thrust::device_ptr<int> thrust_circleid = thrust::device_pointer_cast(circleImgBlockId); 
        // 
        // // allocate storage for rowu sums and indices
        // thrust::device_vector<int> row_sums(numImgBlocks+1);
        // thrust::device_vector<int> row_indices(numImgBlocks);

        //   // compute row sums by summing values with equal row indices
        // thrust::reduce_by_key
        // (thrust::make_transform_iterator(thrust::counting_iterator<int>(0), linear_index_to_row_index<int>(numCircles)),
        //  thrust::make_transform_iterator(thrust::counting_iterator<int>(0), linear_index_to_row_index<int>(numCircles)) + numElements,
        //  thrust_arr,
        //  row_indices.begin(),
        //  row_sums.begin(),
        //  thrust::equal_to<int>(),
        //  thrust::plus<int>());
        // 
        // thrust::fill(thrust::device, row_sums.end() - 1, row_sums.end(), 0);
        // //thrust::copy(row_sums.begin(), row_sums.end(), std::ostream_iterator<int>(std::cout, " "));
        // 
        // thrust::device_vector<int> circleStartAddr(numImgBlocks+1);
        // thrust::exclusive_scan(row_sums.begin(), row_sums.end(), circleStartAddr.begin());
        // //thrust::copy(circleStartAddr.begin(), circleStartAddr.end(), std::ostream_iterator<float>(std::cout, " "));

        // //int num_pairs = thrust::reduce(thrust_arr, thrust_arr + numElements);
        // int num_pairs = circleStartAddr[numImgBlocks];
        // //printf("SUM = %d\n", num_pairs);

        // //cudaFree(circleImgBlockArray);

        // //allocate the right size of array
        // //This array will be traversed by each block -- by using starting address from circleStartAddr
        // thrust::device_vector<int> circleImgBlockList(num_pairs);
        // thrust::copy_if(thrust_circleid, thrust_circleid + numElements, circleImgBlockList.begin(), is_not_zero<int>());
        // //cudaFree(circleImgBlockId);

        // //thrust::copy(circleImgBlockList.begin(), circleImgBlockList.end(), std::ostream_iterator<float>(std::cout, " "));


         dim3 gridDim3(imgBlockNum, imgBlockNum,16);
         dim3 blockDim3(16, 16);
        // 
        // int *deviceStartAddr = NULL;
        // deviceStartAddr = thrust::raw_pointer_cast(circleStartAddr.data());
        // int *deviceImgBlockList = NULL;
        // deviceImgBlockList = thrust::raw_pointer_cast(circleImgBlockList.data());
 
        // //int numPixelsPerBlock = blockDim.x * blockDim.y * 4;
         kernelRenderCircles_pattern<<<gridDim3, blockDim3,256*6*sizeof(int)*3>>>(256*6);
         gpuErrchk(cudaDeviceSynchronize());
   } else {
         int imgBlockNum = 16;

         int numImgBlocks = imgBlockNum * imgBlockNum;
         int numElements = numCircles * imgBlockNum * imgBlockNum;  


         cudaMalloc(&circleImgBlockArray, sizeof(int) * numElements);
         cudaMalloc(&circleImgBlockId, sizeof(int) * numElements);
         //gpuErrchk(cudaDeviceSynchronize());
         dim3 blockDim(256, 1);
         dim3 gridDim((numCircles + blockDim.x - 1) / blockDim.x);
         make_circleImgBlockArray<<<gridDim, blockDim>>>(circleImgBlockArray,circleImgBlockId,imageWidth/imgBlockNum, imgBlockNum);


         /*Convert the 2D circle block array into 1 D array by removing 0 values  */
         thrust::device_ptr<int> thrust_arr = thrust::device_pointer_cast(circleImgBlockArray); 
         thrust::device_ptr<int> thrust_circleid = thrust::device_pointer_cast(circleImgBlockId); 
         
         // allocate storage for rowu sums and indices
         thrust::device_vector<int> row_sums(numImgBlocks+1);
         thrust::device_vector<int> row_indices(numImgBlocks);

           // compute row sums by summing values with equal row indices
         thrust::reduce_by_key
         (thrust::make_transform_iterator(thrust::counting_iterator<int>(0), linear_index_to_row_index<int>(numCircles)),
          thrust::make_transform_iterator(thrust::counting_iterator<int>(0), linear_index_to_row_index<int>(numCircles)) + numElements,
          thrust_arr,
          row_indices.begin(),
          row_sums.begin(),
          thrust::equal_to<int>(),
          thrust::plus<int>());
         
         thrust::fill(thrust::device, row_sums.end() - 1, row_sums.end(), 0);
         //thrust::copy(row_sums.begin(), row_sums.end(), std::ostream_iterator<int>(std::cout, " "));
         
         thrust::device_vector<int> circleStartAddr(numImgBlocks+1);
         thrust::exclusive_scan(row_sums.begin(), row_sums.end(), circleStartAddr.begin());
         //thrust::copy(circleStartAddr.begin(), circleStartAddr.end(), std::ostream_iterator<float>(std::cout, " "));

         //int num_pairs = thrust::reduce(thrust_arr, thrust_arr + numElements);
         int num_pairs = circleStartAddr[numImgBlocks];
         //printf("SUM = %d\n", num_pairs);

         //cudaFree(circleImgBlockArray);

         //allocate the right size of array
         //This array will be traversed by each block -- by using starting address from circleStartAddr
         thrust::device_vector<int> circleImgBlockList(num_pairs);
         thrust::copy_if(thrust_circleid, thrust_circleid + numElements, circleImgBlockList.begin(), is_not_zero<int>());
         //cudaFree(circleImgBlockId);

         //thrust::copy(circleImgBlockList.begin(), circleImgBlockList.end(), std::ostream_iterator<float>(std::cout, " "));


         dim3 gridDim3(imgBlockNum, imgBlockNum,16);
         dim3 blockDim3(16, 16);
         
         int *deviceStartAddr = NULL;
         deviceStartAddr = thrust::raw_pointer_cast(circleStartAddr.data());
         int *deviceImgBlockList = NULL;
         deviceImgBlockList = thrust::raw_pointer_cast(circleImgBlockList.data());
 
         //int numPixelsPerBlock = blockDim.x * blockDim.y * 4;
         kernelRenderCircles<<<gridDim3, blockDim3>>>(deviceImgBlockList, deviceStartAddr);
         gpuErrchk(cudaDeviceSynchronize());
    }
}


