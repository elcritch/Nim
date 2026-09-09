/* Nim owns the exception payload in its thread-local currException chain.
 * This private tag transports control only; it never owns a Nim reference.
 * Foreign exceptions are deliberately not caught here. */
#include "../nativeexc.h"

namespace {
struct NimNativeException {};
thread_local unsigned handlerDepth = 0;
struct Handler {
  Handler() { ++handlerDepth; }
  ~Handler() { --handlerDepth; }
};
}

extern "C" int nimNativeHasHandler(void) { return handlerDepth != 0; }
extern "C" void nimNativeThrow(void) { throw NimNativeException{}; }
extern "C" int nimNativeTry(NimNativeBody body, void *context, int *flow) {
  Handler handler;
  *flow = 0;
  try {
    *flow = body(context);
    return 0;
  } catch (const NimNativeException &) {
    return 1;
  }
}
