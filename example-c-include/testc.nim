import hashes

include "testing.c"

proc add(a, b: cint): cint {.importc.}

echo add(1, 2)
