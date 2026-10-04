discard """
  description: '''IC: cached dependency metadata preserves generic closure scopes and edits'''
"""

#? metamorphic
# Reuse one worker's dependency images across all three consumers.
#!FLAGS -d:icJobs:1

#!FILE shared.nim
type Box[T] = object
  value: T

proc reader*[T](first: T): proc(): T =
  let box = Box[T](value: first)
  result = proc(): T = box.value + T(1)

#!FILE left.nim
import shared
proc left*(): int = reader(10)()

#!FILE middle.nim
import shared
proc middle*(): int = reader(20)()

#!FILE right.nim
import shared
proc right*(): int = reader(30)()

#!FILE main.nim
import left, middle, right
echo left(), " ", middle(), " ", right()
#!STEP expect: 11 21 31
#!STEP expect: 11 21 31
#!STEP expect: 11 21 31; noop

#!FILE shared.nim
type Box[T] = object
  value: T

proc reader*[T](first: T): proc(): T =
  let box = Box[T](value: first)
  result = proc(): T =
    let nested = proc(): T = box.value + T(2)
    nested()
#!STEP expect: 12 22 32

#!FLAGS -d:icProcesses
#!STEP expect: 12 22 32
