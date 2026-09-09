## One workload, compiled independently with native, setjmp, and goto exceptions.
## See README.md and run.py for the comparison harness.
import std/[assertions, json, monotimes, os, strutils, times]

const
  expectedMode {.strdefine.} = ""
  batchSize = 4096
  mode =
    when defined(nimHasNativeExceptions) and compileOption("exceptions", "native"): "native"
    elif compileOption("exceptions", "setjmp"): "setjmp"
    elif compileOption("exceptions", "goto"): "goto"
    else: "unsupported"

static:
  doAssert expectedMode.len > 0, "build with -d:expectedMode=native|setjmp|goto"
  doAssert mode == expectedMode, "the requested exception mode was not selected"

type
  BenchError = object of CatchableError
  Input = object
    value: uint64
    fails: bool
  Counters = object
    checksum: uint64
    caught, cleaned: int64

proc mix(value: uint64; salt: int): uint64 {.inline.} =
  (value xor uint64(salt)) * 1664525'u64 + 1013904223'u64

proc leaf(input: Input; error: ref BenchError; fresh: bool): uint64 {.noinline.} =
  if input.fails:
    if fresh:
      raise newException(BenchError, "benchmark")
    else:
      # Nim records raise sites even with stack traces disabled. Reusing a
      # payload must not accumulate an ever-growing trace across iterations.
      error.trace.setLen(0)
      raise error
  result = mix(input.value, 0)

proc descend(input: Input; depth: int; error: ref BenchError;
             fresh: bool): uint64 {.noinline.} =
  if depth == 0:
    result = leaf(input, error, fresh)
  else:
    result = mix(descend(input, depth - 1, error, fresh), depth)

proc descendCleanup(input: Input; depth: int; error: ref BenchError;
                    fresh: bool; cleaned: var int64): uint64 {.noinline.} =
  try:
    if depth == 0:
      result = leaf(input, error, fresh)
    else:
      result = mix(descendCleanup(input, depth - 1, error, fresh, cleaned), depth)
  finally:
    inc cleaned

proc run[protected, cleanup: static bool](inputs: openArray[Input]; rounds, depth: int;
                                        error: ref BenchError; fresh: bool): Counters =
  for round in 0..<rounds:
    for input in inputs:
      when protected:
        try:
          when cleanup:
            result.checksum += descendCleanup(input, depth, error, fresh, result.cleaned)
          else:
            result.checksum += descend(input, depth, error, fresh)
        except BenchError:
          inc result.caught
          result.checksum += input.value xor 0xDEADBEEF'u64
      else:
        result.checksum += descend(input, depth, error, fresh)

proc main() =
  if paramCount() != 5:
    quit "usage: exceptionbench plain|try|cleanup ROUNDS DEPTH THROW_EVERY reuse|fresh"
  let
    kind = paramStr(1)
    rounds = parseInt(paramStr(2))
    depth = parseInt(paramStr(3))
    throwEvery = parseInt(paramStr(4))
    payload = paramStr(5)
  doAssert kind in ["plain", "try", "cleanup"]
  doAssert rounds in 1..1_000_000 and depth in 0..128
  doAssert throwEvery in 0..batchSize
  doAssert payload in ["reuse", "fresh"]
  doAssert kind != "plain" or throwEvery == 0
  let fresh = payload == "fresh"
  var inputs: array[batchSize, Input]
  var expected: Counters
  for i in 0..<batchSize:
    inputs[i] = Input(value: mix(uint64(i + 1), 91),
      fails: throwEvery > 0 and (i + 1) mod throwEvery == 0)
    var value = inputs[i].value xor 0xDEADBEEF'u64
    if inputs[i].fails:
      inc expected.caught
    else:
      value = mix(inputs[i].value, 0)
      for level in 1..depth:
        value = mix(value, level)
    expected.checksum += value
  if kind == "cleanup": expected.cleaned = int64(batchSize) * int64(depth + 1)
  let error = newException(BenchError, "benchmark")

  template execute(count: int): Counters =
    case kind
    of "plain": run[false, false](inputs, count, depth, error, fresh)
    of "try": run[true, false](inputs, count, depth, error, fresh)
    else: run[true, true](inputs, count, depth, error, fresh)

  # Warm-up and validation happen outside the timed region.
  doAssert execute(1) == expected
  doAssert getCurrentException() == nil
  let start = getMonoTime()
  let actual = execute(rounds)
  let elapsed = (getMonoTime() - start).inNanoseconds
  expected.checksum *= uint64(rounds)
  expected.caught *= int64(rounds)
  expected.cleaned *= int64(rounds)
  doAssert actual == expected, "benchmark work or cleanup was lost"
  doAssert getCurrentException() == nil
  echo $(%*{"mode": mode, "kind": kind, "rounds": rounds, "depth": depth,
    "throw_every": throwEvery, "payload": payload, "elapsed_ns": elapsed,
    "operations": int64(rounds) * batchSize, "caught": actual.caught,
    "cleaned": actual.cleaned, "checksum": $actual.checksum})

main()
