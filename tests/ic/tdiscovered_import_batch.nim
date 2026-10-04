discard """
  description: '''IC: discover every active grouped import without crossing conditional branches'''
"""

#? metamorphic

#!FILE left.nim
proc left*(): string = "left"

#!FILE right.nim
proc right*(): string = "right"

#!FILE other.nim
proc other*(): string = "other"

#!FILE broken.nim
{.error: "inactive import must stay deferred".}

#!FILE gen.nim
import std/macros

macro imports(): untyped =
  parseStmt("import ./[left as lhs, right], other as extra")

const Active* {.booldefine.} = true
when Active:
  imports()
  proc value*(): string = lhs.left() & ":" & right() & ":" & extra.other()
else:
  when false:
    import broken
  proc value*(): string = "inactive"

#!FILE main.nim
import gen
echo value()
#!STEP expect: left:right:other

#!FILE right.nim
proc right*(): string = "edited"
#!STEP expect: left:edited:other

#!FLAGS -d:Active=false
#!STEP expect: inactive

#!FLAGS
#!STEP expect: left:edited:other
