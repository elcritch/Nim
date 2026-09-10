discard """
  description: "CacheCounter type IDs reuse generic instances across modules"
"""

#? metamorphic

#!FILE ids.nim
import std/macrocache
const ids = CacheCounter"tests.ic.genericCounter"
proc nextId(): int {.compileTime.} =
  ids.inc
  ids.value
proc typeIdAux[T](): int =
  var id {.global.} = nextId()
  id
proc typeId*(T: typedesc): int = static(typeIdAux[T]())

#!FILE first.nim
import ids
proc intId*(): int = typeId(int)
proc sequenceId*(): int = typeId(seq[int])

#!FILE second.nim
import ids
proc stringId*(): int = typeId(string)
proc sequenceId*(): int = typeId(seq[int])

#!FILE main.nim
import first, second
echo first.intId(), ",", second.stringId(), ",",
  first.sequenceId(), ",", second.sequenceId()

#!STEP expect: 1,3,2,2
#!STEP noop; expect: 1,3,2,2

# Adding a new instantiation shifts subsequent IDs; shared instances stay equal.
#!FILE first.nim
import ids
proc intId*(): int = typeId(int)
proc boolId*(): int = typeId(bool)
proc sequenceId*(): int = typeId(seq[int])

#!STEP expect: 1,4,3,3
#!STEP noop; expect: 1,4,3,3

#!FILE main.nim
import second, first
echo first.intId(), ",", second.stringId(), ",",
  first.sequenceId(), ",", second.sequenceId()

#!STEP expect: 3,1,2,2
#!STEP noop; expect: 3,1,2,2
