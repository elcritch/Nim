discard """
  targets: "c"
  ccodecheck: "'N_LIB_EXPORT N_NIMCALL\\(NI, _ZN13texportnimabi6chooseE3int\\)'"
  ccodecheck: "'N_LIB_EXPORT N_NIMCALL\\(NI, _ZN13texportnimabi6chooseE6string\\)'"
  ccodecheck: "'N_LIB_EXPORT N_NIMCALL\\(NI, _ZN13texportnimabi3tagE3BoxI3intE\\)'"
  ccodecheck: "'N_LIB_EXPORT N_NIMCALL\\(NI, _ZN13texportnimabi3tagE3BoxI6stringE\\)'"
"""

type
  Box[T] = object
    value: T

proc choose(x: int): int {.exportnimabi.} =
  x

proc choose(x: string): int {.exportnimabi.} =
  x.len

proc tag[T](box: Box[T]): int {.exportnimabi.} =
  when T is int:
    box.value
  else:
    box.value.len

discard tag(Box[int](value: 3))
discard tag(Box[string](value: "nim"))
