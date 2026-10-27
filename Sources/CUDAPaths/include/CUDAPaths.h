#ifndef JSP_CUDA_PATHS_H
#define JSP_CUDA_PATHS_H
#include <stddef.h>
#include <stdint.h>

typedef struct JSPCUDA JSPCUDA;
// NULL means unavailable. Does not require CUDA headers or link-time libraries.
JSPCUDA *jsp_cuda_create(char *error, size_t error_size);
void jsp_cuda_destroy(JSPCUDA *handle);
// Caller serializes access to a handle. All buffers contain batch * rows * cols
// int32 values. Sizes must be in 1...rows*cols; seeds are 0 or 536870911.
int jsp_cuda_paths(JSPCUDA *handle, int32_t rows, int32_t cols, int32_t batch,
                   const int32_t *sizes, const int32_t *seeds, int32_t *output,
                   char *error, size_t error_size);
#endif
