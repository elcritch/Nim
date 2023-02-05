import hashes

const chash* = staticRead("testing.c").hash()
{.emit: "#include <testing.c>".}
proc cversion*(): Hash {.exportc.} =
  chash

proc add(a, b: cint): cint {.importc.}

echo add(1, 2)
