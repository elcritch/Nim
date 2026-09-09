/* Compile as C: C++ compilation would hide missing -fexceptions support. */
#ifdef __cplusplus
#error This fixture must be compiled as C
#endif
static void release(int **count) { ++**count; }
void nativeCleanupCall(void (*body)(void), int *count) {
  int *resource __attribute__((cleanup(release))) = count;
  body();
  (void)resource;
}
