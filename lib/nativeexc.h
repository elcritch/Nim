/* Private ABI for the C backend's native exception boundaries. */
#ifndef NIM_NATIVE_EXC_H
#define NIM_NATIVE_EXC_H
#ifdef __cplusplus
extern "C" {
#endif
typedef int (*NimNativeBody)(void *);
typedef struct { int status; } NimNativeSafePoint;
int nimNativeTry(NimNativeBody body, void *context, int *flow);
int nimNativeHasHandler(void);
#if defined(__GNUC__) || defined(__clang__)
__attribute__((noreturn))
#endif
void nimNativeThrow(void);
#ifdef __cplusplus
}
#endif
#endif
