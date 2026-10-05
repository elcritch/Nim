discard """
  description: '''IC: early interfaces preserve body demands, VM state and incremental edits'''
"""

#? metamorphic
#!FLAGS -d:icSplitBodies --parallelBuild:4

#!FILE provider.nim
import std/[macros, macrocache]
const counter = CacheCounter"split-semantic-interface-counter"
type Token* = object
  value*: int
macro count*(): untyped = newLit(counter.value)
proc inferred*(): auto = 7
proc constant*(): int = 9
proc closure*[T](x: T): proc(): T =
  result = proc(): T = x
proc checked*(x: Token): int =
  static: counter.inc
  const offset = constant()
  x.value + offset

#!FILE consumer.nim
import provider
const compiledValue* = count()
type Wrapper* = object
  token*: Token
proc consume*(x: int): int =
  checked(Token(value: x)) + inferred() + closure(2)()

#!FILE main.nim
import consumer
echo consume(20), " ", compiledValue
#!STEP expect: 38 1
#!STEP expect: 38 1
#!STEP expect: 38 1; noop

#!FILE provider.nim
import std/[macros, macrocache]
const counter = CacheCounter"split-semantic-interface-counter"
type Token* = object
  value*: int
macro count*(): untyped = newLit(counter.value)
proc inferred*(): auto = 8
proc constant*(): int = 10
proc closure*[T](x: T): proc(): T =
  result = proc(): T = x + T(1)
proc checked*(x: Token): int =
  static: counter.inc(2)
  const offset = constant()
  x.value + offset
#!STEP expect: 41 2
#!STEP expect: 41 2
#!STEP expect: 41 2; noop

#!FLAGS -d:icSplitBodies --parallelBuild:1
#!STEP expect: 41 2

#!FLAGS -d:icProcesses
#!STEP expect: 41 2
