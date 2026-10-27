#include "CUDAPaths.h"
#include <stdio.h>
#include <stdlib.h>

#if defined(__linux__)
#include <dlfcn.h>
#include <string.h>

// CUDA's stable driver ABI, loaded dynamically. No CUDA SDK at build time.
typedef int CUdevice;
typedef unsigned long long CUdeviceptr;
typedef void *CUcontext;
typedef void *CUmodule;
typedef void *CUfunction;
typedef void *CUstream;
typedef void *nvrtcProgram;

struct JSPCUDA {
    void *driver, *nvrtc;
    CUdevice device;
    CUcontext context;
    CUmodule module;
    CUfunction function;
    int retained;
    int (*cuInit)(unsigned);
    int (*cuDeviceGet)(CUdevice *, int);
    int (*cuDevicePrimaryCtxRetain)(CUcontext *, CUdevice);
    int (*cuDevicePrimaryCtxRelease)(CUdevice);
    int (*cuCtxGetCurrent)(CUcontext *);
    int (*cuCtxSetCurrent)(CUcontext);
    int (*cuModuleLoadData)(CUmodule *, const void *);
    int (*cuModuleUnload)(CUmodule);
    int (*cuModuleGetFunction)(CUfunction *, CUmodule, const char *);
    int (*cuMemAlloc)(CUdeviceptr *, size_t);
    int (*cuMemFree)(CUdeviceptr);
    int (*cuMemcpyHtoD)(CUdeviceptr, const void *, size_t);
    int (*cuMemcpyDtoH)(void *, CUdeviceptr, size_t);
    int (*cuLaunchKernel)(CUfunction, unsigned, unsigned, unsigned, unsigned,
                          unsigned, unsigned, unsigned, CUstream, void **, void **);
    int (*cuStreamCreate)(CUstream *, unsigned);
    int (*cuStreamSynchronize)(CUstream);
    int (*cuStreamDestroy)(CUstream);
    int (*nvrtcCreateProgram)(nvrtcProgram *, const char *, const char *, int,
                              const char *const *, const char *const *);
    int (*nvrtcCompileProgram)(nvrtcProgram, int, const char *const *);
    int (*nvrtcGetPTXSize)(nvrtcProgram, size_t *);
    int (*nvrtcGetPTX)(nvrtcProgram, char *);
    int (*nvrtcGetProgramLogSize)(nvrtcProgram, size_t *);
    int (*nvrtcGetProgramLog)(nvrtcProgram, char *);
    int (*nvrtcDestroyProgram)(nvrtcProgram *);
};

static const char *kernel =
"extern \"C\" __global__ void integerPaths(const int *sizes, const int *seeds, int *output, int rows, int cols, int batch) {\n"
" int board = blockIdx.x, lane = threadIdx.x; if (board >= batch) return;\n"
" const int n = rows * cols, offset = board * n;\n"
" __shared__ int a[121], b[121]; int *previous = a, *next = b;\n"
" for (int cell=lane; cell<n; cell+=32) previous[cell]=seeds[offset+cell];\n"
" __syncthreads();\n"
" for (int step=1; step<n; ++step) {\n"
"  bool changed=false;\n"
"  for (int cell=lane; cell<n; cell+=32) {\n"
"   int best=previous[cell];\n"
"   int neighbors[4]={cell-cols,cell+1,cell+cols,cell-1};\n"
"   bool allowed[4]={cell>=cols,cell%cols+1<cols,cell+cols<n,cell%cols>0};\n"
"   for (int k=0; k<4; ++k) if (allowed[k]) {\n"
"    int from=neighbors[k], x=sizes[offset+cell], y=sizes[offset+from];\n"
"    int candidate=previous[from]+(x<y?x:y); if(candidate<best) best=candidate;\n"
"   }\n"
"   next[cell]=best; changed=changed || best!=previous[cell];\n"
"  }\n"
"  __syncthreads();\n"
"  int *swap=previous; previous=next; next=swap;\n"
"  if (!__any_sync(0xffffffffu, changed)) break;\n"
" }\n"
" for (int cell=lane; cell<n; cell+=32) output[offset+cell]=previous[cell];\n"
"}\n";

static int fail(char *error, size_t capacity, const char *step, int code) {
    if (error && capacity) snprintf(error, capacity, "%s (code %d)", step, code);
    return -1;
}

#define LOAD(lib, field, symbol) do { \
    *(void **)(&h->field) = dlsym(h->lib, symbol); \
    if (!h->field) { fail(error, capacity, symbol, -1); goto failed; } \
} while (0)
#define CHECK(call) do { int code = (call); if (code) { fail(error, capacity, #call, code); goto failed; } } while (0)

JSPCUDA *jsp_cuda_create(char *error, size_t capacity) {
    JSPCUDA *h = calloc(1, sizeof(*h));
    CUcontext previous = NULL;
    nvrtcProgram program = NULL;
    char *ptx = NULL;
    int have_previous = 0;
    if (!h) { fail(error, capacity, "CUDA host allocation", -1); return NULL; }
    h->driver = dlopen("libcuda.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!h->driver) { fail(error, capacity, "libcuda.so.1 unavailable", -1); goto failed; }
    const char *libraries[] = {"libnvrtc.so", "libnvrtc.so.13", "libnvrtc.so.12", "libnvrtc.so.11.2"};
    for (size_t i=0; i<sizeof(libraries)/sizeof(libraries[0]) && !h->nvrtc; ++i)
        h->nvrtc = dlopen(libraries[i], RTLD_NOW | RTLD_LOCAL);
    if (!h->nvrtc) { fail(error, capacity, "CUDA NVRTC unavailable", -1); goto failed; }
    LOAD(driver, cuInit, "cuInit");
    LOAD(driver, cuDeviceGet, "cuDeviceGet");
    LOAD(driver, cuDevicePrimaryCtxRetain, "cuDevicePrimaryCtxRetain");
    LOAD(driver, cuDevicePrimaryCtxRelease, "cuDevicePrimaryCtxRelease_v2");
    LOAD(driver, cuCtxGetCurrent, "cuCtxGetCurrent");
    LOAD(driver, cuCtxSetCurrent, "cuCtxSetCurrent");
    LOAD(driver, cuModuleLoadData, "cuModuleLoadData");
    LOAD(driver, cuModuleUnload, "cuModuleUnload");
    LOAD(driver, cuModuleGetFunction, "cuModuleGetFunction");
    LOAD(driver, cuMemAlloc, "cuMemAlloc_v2");
    LOAD(driver, cuMemFree, "cuMemFree_v2");
    LOAD(driver, cuMemcpyHtoD, "cuMemcpyHtoD_v2");
    LOAD(driver, cuMemcpyDtoH, "cuMemcpyDtoH_v2");
    LOAD(driver, cuLaunchKernel, "cuLaunchKernel");
    LOAD(driver, cuStreamCreate, "cuStreamCreate");
    LOAD(driver, cuStreamSynchronize, "cuStreamSynchronize");
    LOAD(driver, cuStreamDestroy, "cuStreamDestroy_v2");
    LOAD(nvrtc, nvrtcCreateProgram, "nvrtcCreateProgram");
    LOAD(nvrtc, nvrtcCompileProgram, "nvrtcCompileProgram");
    LOAD(nvrtc, nvrtcGetPTXSize, "nvrtcGetPTXSize");
    LOAD(nvrtc, nvrtcGetPTX, "nvrtcGetPTX");
    LOAD(nvrtc, nvrtcGetProgramLogSize, "nvrtcGetProgramLogSize");
    LOAD(nvrtc, nvrtcGetProgramLog, "nvrtcGetProgramLog");
    LOAD(nvrtc, nvrtcDestroyProgram, "nvrtcDestroyProgram");
    CHECK(h->cuInit(0));
    CHECK(h->cuDeviceGet(&h->device, 0));
    CHECK(h->cuCtxGetCurrent(&previous)); have_previous = 1;
    CHECK(h->cuDevicePrimaryCtxRetain(&h->context, h->device)); h->retained = 1;
    CHECK(h->cuCtxSetCurrent(h->context));
    CHECK(h->nvrtcCreateProgram(&program, kernel, "integerPaths.cu", 0, NULL, NULL));
    // PTX targets Turing or newer, supported by CUDA 11/12/13 NVRTC.
    const char *options[] = {"--gpu-architecture=compute_75", "--std=c++11"};
    int compile = h->nvrtcCompileProgram(program, 2, options);
    if (compile) {
        size_t log_size = 0;
        if (!h->nvrtcGetProgramLogSize(program, &log_size) && log_size > 0 && log_size < 1048576) {
            char *log = malloc(log_size);
            if (log) {
                if (!h->nvrtcGetProgramLog(program, log) && error && capacity)
                    snprintf(error, capacity, "NVRTC: %s", log);
                free(log);
            } else fail(error, capacity, "NVRTC log allocation", -1);
        } else fail(error, capacity, "NVRTC compilation", compile);
        goto failed;
    }
    size_t ptx_size = 0;
    CHECK(h->nvrtcGetPTXSize(program, &ptx_size));
    ptx = malloc(ptx_size);
    if (!ptx) { fail(error, capacity, "PTX allocation", -1); goto failed; }
    CHECK(h->nvrtcGetPTX(program, ptx));
    CHECK(h->cuModuleLoadData(&h->module, ptx));
    CHECK(h->cuModuleGetFunction(&h->function, h->module, "integerPaths"));
    free(ptx); ptx = NULL;
    h->nvrtcDestroyProgram(&program); program = NULL;
    if (h->cuCtxSetCurrent(previous)) { fail(error, capacity, "CUDA context restoration", -1); goto failed; }
    return h;
failed:
    free(ptx);
    if (program && h->nvrtcDestroyProgram) h->nvrtcDestroyProgram(&program);
    // Destroy while its context is current, then restore the caller's context.
    if (h->module && h->cuModuleUnload) h->cuModuleUnload(h->module);
    if (have_previous && h->cuCtxSetCurrent) h->cuCtxSetCurrent(previous);
    if (h->retained && h->cuDevicePrimaryCtxRelease) h->cuDevicePrimaryCtxRelease(h->device);
    if (h->nvrtc) dlclose(h->nvrtc);
    if (h->driver) dlclose(h->driver);
    free(h); return NULL;
}

void jsp_cuda_destroy(JSPCUDA *h) {
    if (!h) return;
    CUcontext previous = NULL;
    h->cuCtxGetCurrent(&previous);
    if (!h->cuCtxSetCurrent(h->context)) h->cuModuleUnload(h->module);
    h->cuCtxSetCurrent(previous);
    h->cuDevicePrimaryCtxRelease(h->device);
    dlclose(h->nvrtc); dlclose(h->driver); free(h);
}

int jsp_cuda_paths(JSPCUDA *h, int32_t rows, int32_t cols, int32_t batch,
                   const int32_t *sizes, const int32_t *seeds, int32_t *output,
                   char *error, size_t capacity) {
    if (!h || rows<1 || cols<1 || rows>121 || cols>121 || rows*cols>121 || batch<1 || batch>32 || !sizes || !seeds || !output)
        return fail(error, capacity, "Invalid CUDA batch", -1);
    const int cells = rows*cols*batch;
    for (int i=0; i<cells; ++i)
        if (sizes[i]<1 || sizes[i]>rows*cols || (seeds[i]!=0 && seeds[i]!=536870911))
            return fail(error, capacity, "Invalid CUDA input", -1);
    CUcontext previous = NULL;
    CUdeviceptr d_sizes=0, d_seeds=0, d_output=0;
    CUstream stream = NULL;
    int result = -1, have_previous = 0;
    const size_t bytes = (size_t)cells * sizeof(int32_t);
    CHECK(h->cuCtxGetCurrent(&previous)); have_previous = 1;
    CHECK(h->cuCtxSetCurrent(h->context));
    CHECK(h->cuStreamCreate(&stream, 1));
    CHECK(h->cuMemAlloc(&d_sizes, bytes));
    CHECK(h->cuMemAlloc(&d_seeds, bytes));
    CHECK(h->cuMemAlloc(&d_output, bytes));
    CHECK(h->cuMemcpyHtoD(d_sizes, sizes, bytes));
    CHECK(h->cuMemcpyHtoD(d_seeds, seeds, bytes));
    void *arguments[] = {&d_sizes, &d_seeds, &d_output, &rows, &cols, &batch};
    CHECK(h->cuLaunchKernel(h->function, (unsigned)batch, 1, 1, 32, 1, 1, 0, stream, arguments, NULL));
    CHECK(h->cuStreamSynchronize(stream));
    CHECK(h->cuMemcpyDtoH(output, d_output, bytes));
    result = 0;
failed:
    // Ensure a failed launch cannot outlive the allocations it references.
    if (stream) { h->cuStreamSynchronize(stream); h->cuStreamDestroy(stream); }
    if (d_output) h->cuMemFree(d_output);
    if (d_seeds) h->cuMemFree(d_seeds);
    if (d_sizes) h->cuMemFree(d_sizes);
    if (have_previous && h->cuCtxSetCurrent(previous)) return fail(error, capacity, "CUDA context restoration", -1);
    return result;
}
#else
struct JSPCUDA { int unused; };
JSPCUDA *jsp_cuda_create(char *error, size_t capacity) {
    if (error && capacity) snprintf(error, capacity, "CUDA backend requires Linux");
    return NULL;
}
void jsp_cuda_destroy(JSPCUDA *h) { (void)h; }
int jsp_cuda_paths(JSPCUDA *h, int32_t rows, int32_t cols, int32_t batch,
                   const int32_t *sizes, const int32_t *seeds, int32_t *output,
                   char *error, size_t capacity) {
    (void)h; (void)rows; (void)cols; (void)batch; (void)sizes; (void)seeds; (void)output;
    if (error && capacity) snprintf(error, capacity, "CUDA backend requires Linux");
    return -1;
}
#endif
