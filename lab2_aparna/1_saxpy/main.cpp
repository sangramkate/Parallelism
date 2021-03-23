#include <stdlib.h>
#include <stdio.h>
#include <getopt.h>
#include <string>
#include <vector>
#include <time.h>
#include "saxpy.h"
#include "common.h"

#include "CycleTimer.h"

double timeKernelAvg = 0.0;
double timeCopyH2DAvg = 0.0;
double timeCopyD2HAvg = 0.0;
double totalTimeAvg = 0.0;

// return GB/s
float toBW(long long int bytes, float sec) {
    //printf("Bytes : %lld , sec: %f\n", bytes, sec);
    return static_cast<float>((bytes) / (1024. * 1024. * 1024.) / sec);
}

void saxpyCpu(long N, float alpha, float* x, float* y, float* result) {
    
    double startCPUTime = CycleTimer::currentSeconds();
    for (long index=0; index<N; index++) 
       result[index] = alpha * x[index] + y[index];
    double endCPUTime = CycleTimer::currentSeconds();
    printf("Total CPU time: %8.3f\n", 1000.f*(endCPUTime - startCPUTime));
}

bool check_saxpy(long N, float* a, float* b) {
    printf("%s\n", __func__);
    std::vector<long> diffs;
    for (long index=0; index<N; index++) {
       if (a[index] != b[index]) 
         diffs.push_back(index);
    }
    if (diffs.size() > 0) {
        MYDEBUG("%s done\n", __func__);
        for (unsigned int i=0; i<diffs.size(); i++) {
            int idx = diffs[i];
            MYDEBUG("[%16d] %10.3f != %10.3f (%e)\n", idx, a[idx], b[idx], a[idx] - b[idx]);
            printf("[%16d] %10.3f != %10.3f (%e)\n", idx, a[idx], b[idx], a[idx] - b[idx]);
        }
        MYDEBUG(" failed #: %zu\n", diffs.size());
        return false;
    } else {
      return true;
    }
}

void usage(const char* progname) {
     printf("Usage: %s [options]\n", progname);
     printf("Program Options:\n");
     printf("  -n  --arraysize  <INT>  Number of elements in arrays\n");
     printf("  -p  --partitions <INT>  Number of partitions for the array\n");
     printf("  -i  --iterations <INT>  Number of iterations for statistics\n");
     printf("  -?  --help             This message\n");
}


int main(int argc, char** argv)
{

    long int total_elems = 512 * 1024 * 1024; 
    int partitions = 1;
    int iterations = 1;
    // parse commandline options ////////////////////////////////////////////
    int opt;
    static struct option long_options[] = {
        {"arraysize",  1, 0, 'n'},
        {"partitions",  1, 0, 'p'},
        {"iterations",  1, 0, 'i'},
        {"help",       0, 0, '?'},
        {0 ,0, 0, 0}
    };
 
    while ((opt = getopt_long(argc, argv, "?n:p:i:", long_options, NULL)) != EOF) {
 
        switch (opt) {
        case 'n':
            total_elems = atol(optarg);
            break;
        case 'p':
            partitions = atoi(optarg);
            break;
        case 'i':
            iterations = atoi(optarg);
            break;
        case '?':
        default:
            usage(argv[0]);
            return 1;
        }
    }
    // end parsing of commandline options //////////////////////////////////////
 
    const float alpha = 2.0f;
    float* xarray      = NULL;
    float* yarray      = NULL;
    float* resultarray = NULL;
    //
    // allocate host-side memory
    /*
    xarray = (float*) malloc(total_elems*sizeof(float));
    yarray = (float*) malloc(total_elems*sizeof(float));
    resultarray = (float*) malloc(total_elems*sizeof(float));
    */

    //printf("Calling get arr\n");
    getArrays(total_elems, &xarray, &yarray, &resultarray);
    //
    // initialize input arrays
    //
    srand(time(NULL));
    for (long i=0; i<total_elems; i++) {
        xarray[i] = rand() / 100;
        yarray[i] = rand() / 100;
    }

    printCudaInfo();

    for (int i=0; i<iterations; i++) { 
        saxpyCuda(total_elems, alpha, xarray, yarray, resultarray, partitions);
    }
    totalTimeAvg /= iterations;
    timeKernelAvg /= iterations;
    timeCopyH2DAvg /= iterations;
    timeCopyD2HAvg /= iterations;

    long long int totalBytes = sizeof(float) * 3 * total_elems; //3 is for a,b and c
    printf("Overall time : %8.3f ms [%8.3f GB/s ]\n", 1000.f * totalTimeAvg, toBW(totalBytes, totalTimeAvg));
    printf("GPU Kernel   : %8.3f ms [%8.3f Ops/s]\n", 1000.f * timeKernelAvg, toBW(totalBytes/3, timeKernelAvg));
    printf("Copy CPU->GPU: %8.3f ms [%8.3f GB/s ]\n", 1000.f * timeCopyH2DAvg, toBW(totalBytes*2/3, timeCopyH2DAvg));
    printf("Copy CPU<-GPU: %8.3f ms [%8.3f GB/s ]\n", 1000.f * timeCopyD2HAvg, toBW(totalBytes/3, timeCopyD2HAvg));
    
    if (resultarray != NULL) {
        float* resultrefer = new float[total_elems]();
        saxpyCpu(total_elems, alpha, xarray, yarray, resultrefer);
    
        if (check_saxpy(total_elems, resultarray, resultrefer)) {
            printf("Test succeeded\n");
        } else {
            printf("Test failed\n");
        }
    }

    //
    // deallocate host-side memory
    freeArrays(xarray, yarray, resultarray);
 
    return 0;
}