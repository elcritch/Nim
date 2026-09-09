discard """
  targets: "c"
  matrix: "--exceptions:native --mm:arc; --exceptions:native --mm:orc; --exceptions:native --mm:refc; --exceptions:native --mm:arc -d:release; --exceptions:native --mm:arc -d:danger"
  disabled: "windows"
  ccodecheck: "!@('setjmp(' / 'pushSafePoint(' / 'longjmp(')"
"""

import std/assertions

static:
  doAssert defined(nimHasNativeExceptions)
  doAssert compileOption("exceptions", "native")

proc fail() {.noinline.} =
  raise newException(ValueError, "native")

block captures:
  proc test(a: int; b: var int; values: openArray[int]): int =
    var local = [1, 2, 3]
    try:
      b += a + values[0]
      local[1] = b
      result = local[1]
      fail()
    except ValueError as e:
      doAssert e.msg == "native"
      inc result
    finally:
      inc b
  var b = 2
  doAssert test(3, b, [4]) == 10
  doAssert b == 10

block exits:
  var finalizers = 0
  proc early(): string =
    try:
      try:
        return "returned"
      finally:
        inc finalizers
    finally:
      inc finalizers
  doAssert early() == "returned"
  doAssert finalizers == 2
  block outer:
    for i in 0..3:
      try:
        if i == 0: continue
        break outer
      finally:
        inc finalizers
  doAssert finalizers == 4

block cleanup:
  var destroyed = 0
  type Resource = object
    count: ptr int
  proc `=destroy`(r: var Resource) =
    if r.count != nil: inc r.count[]
  proc callee() =
    var r = Resource(count: addr destroyed)
    fail()
  try:
    callee()
  except ValueError:
    discard
  doAssert destroyed == 1

block nesting:
  try:
    try:
      fail()
    except ValueError:
      try:
        raise newException(KeyError, "inner")
      except KeyError:
        doAssert getCurrentExceptionMsg() == "inner"
      doAssert getCurrentExceptionMsg() == "native"
      raise
  except ValueError:
    doAssert getCurrentExceptionMsg() == "native"
  doAssert getCurrentException() == nil

block expressions:
  let x = try:
    fail()
    1
  except ValueError:
    2
  doAssert x == 2

block closure:
  proc make(): proc(): int =
    var count = 0
    result = proc(): int =
      try:
        inc count
        fail()
      except ValueError:
        result = count
  let f = make()
  doAssert f() == 1
  doAssert f() == 2

block handlerFailure:
  var finalized = 0
  try:
    try:
      fail()
    except ValueError:
      proc anotherFailure() =
        raise newException(KeyError, "replacement")
      anotherFailure()
    finally:
      inc finalized
  except KeyError:
    doAssert getCurrentExceptionMsg() == "replacement"
  doAssert finalized == 1
  doAssert getCurrentException() == nil

block returnFromFinally:
  proc overrides(): int =
    try:
      try:
        fail()
      finally:
        return 42
    finally:
      discard
  doAssert overrides() == 42
  doAssert getCurrentException() == nil

block cCleanup:
  {.compile: "nativecleanup.c".}
  proc nativeCleanupCall(body: proc() {.cdecl.}; count: ptr cint) {.importc.}
  proc throwingCallback() {.cdecl.} = fail()
  proc normalCallback() {.cdecl.} = discard
  var count: cint = 0
  nativeCleanupCall(normalCallback, addr count)
  doAssert count == 1
  try:
    nativeCleanupCall(throwingCallback, addr count)
  except ValueError:
    discard
  doAssert count == 2

block finalizerFailure:
  try:
    try:
      fail()
    finally:
      raise newException(KeyError, "finally")
  except KeyError:
    doAssert getCurrentExceptionMsg() == "finally"
  doAssert getCurrentException() == nil

block handlerReturns:
  proc handled(): int =
    try:
      fail()
    except ValueError:
      return 7
  doAssert handled() == 7
  doAssert getCurrentException() == nil

block enclosingException:
  try:
    raise newException(KeyError, "outer")
  except KeyError:
    try:
      try:
        fail()
      except ValueError:
        fail()
    except ValueError:
      doAssert getCurrentExceptionMsg() == "native"
    doAssert getCurrentExceptionMsg() == "outer"
  doAssert getCurrentException() == nil

block iteratorReturn:
  iterator early(): int {.closure.} =
    try:
      try:
        fail()
      except ValueError:
        return 123
      yield 0
    except CatchableError:
      discard
  let it = early
  doAssert it() == 123
  doAssert getCurrentException() == nil

var nativeThreadCounter {.threadvar.}: int
block threadLocal:
  try:
    inc nativeThreadCounter
    fail()
  except ValueError:
    doAssert nativeThreadCounter == 1

block captureLayouts:
  type Big = object
    a: array[100, int]
  proc capture(x: Big; a: array[2, array[3, int]]): Big =
    try:
      result = x
      result.a[0] += a[1][2]
      fail()
    except ValueError:
      inc result.a[0]
  var big: Big
  big.a[0] = 7
  doAssert capture(big, [[1, 2, 3], [4, 5, 6]]).a[0] == 14

block capturedSet:
  proc containsLargeSet(values: set[char]; changed: var set[char]): bool =
    try:
      result = 'z' in values
      changed.incl 'x'
      fail()
    except ValueError:
      doAssert 'x' in changed
  var changed: set[char]
  doAssert containsLargeSet({'a', 'z'}, changed)

block deferredCleanup:
  var cleaned = 0
  proc withDefer() =
    defer: inc cleaned
    fail()
  try:
    withDefer()
  except ValueError:
    discard
  doAssert cleaned == 1

when compileOption("threads"):
  block separateThread:
    proc worker(count: ptr int) {.thread.} =
      doAssert nativeThreadCounter == 0
      try:
        inc nativeThreadCounter
        fail()
      except ValueError:
        inc count[]
      doAssert getCurrentException() == nil
    var count = 0
    var thread: Thread[ptr int]
    createThread(thread, worker, addr count)
    joinThread(thread)
    doAssert count == 1
    doAssert nativeThreadCounter == 1
