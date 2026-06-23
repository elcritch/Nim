discard """
  cmd: "nim check $options $file"
  errormsg: "exportnimabi accessor for field 'layers' has unsupported type"
"""

type
  Renderer* = ref object
    layers*: seq[int]

proc touch(r: Renderer) {.exportnimabi.} =
  discard
