discard """
  description: "CacheCounter shares one allocation history across sibling modules"
"""

#? metamorphic

#!FILE counter.nim
when isMainModule:
  {.error: "an imported counter module is not the entry point".}
import std/macrocache
const ids* = CacheCounter"tests.ic.sharedCounter"
proc nextId*(): int {.compileTime.} =
  ids.inc
  ids.value

#!FILE first.nim
import counter
const firstId* = nextId()

#!FILE second.nim
import counter
const secondId* = nextId()

#!FILE main.nim
import first, second, counter
import std/macrocache
const finalCount = ids.value
echo firstId, ",", secondId, ",", finalCount

#!STEP expect: 1,2,2
#!STEP noop; expect: 1,2,2

# Only this sibling changes; the later allocation and reader must update too.
#!FILE first.nim
import counter
const firstId* = nextId()
const extraId* = nextId()

#!STEP expect: 1,3,3
#!STEP noop; expect: 1,3,3

#!FILE first.nim
import counter
const firstId* = nextId()

#!STEP expect: 1,2,2

# The allocation sequence follows source import order, even on a warm cache.
#!FILE main.nim
import second, first, counter
import std/macrocache
const finalCount = ids.value
echo firstId, ",", secondId, ",", finalCount

#!STEP expect: 2,1,2

# The shared frontend can discover and compile a macro-generated import itself.
#!FILE generated.nim
import counter
const generatedId* = nextId()

#!FILE main.nim
import second, first, counter
import std/[macrocache, macros]
macro importGenerated(): untyped = parseStmt("import generated")
importGenerated()
const finalCount = ids.value
echo firstId, ",", secondId, ",", generatedId, ",", finalCount

#!STEP expect: 2,1,3,3
#!STEP noop; expect: 2,1,3,3
