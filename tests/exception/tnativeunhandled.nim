discard """
  targets: "c"
  cmd: "nim c --exceptions:native $file"
  disabled: "windows"
  outputsub: "Error: unhandled exception: native unhandled [ValueError]"
  exitcode: "1"
"""

proc fail() =
  raise newException(ValueError, "native unhandled")

try:
  fail()
finally:
  discard
