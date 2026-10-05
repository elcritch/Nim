discard """
  output: "deferred lookup OK"
  matrix: "--deferBodies:on --ic:off; --deferBodies:on --ic:on"
"""

import std/macros

proc choose[T](x: T): int = 1
proc before(): int = choose(0)
proc qualifiedBefore(): int = tdeferred_lookup.choose(0)
proc choose(x: int): int = 2
doAssert before() == 1
doAssert qualifiedBefore() == 1
doAssert choose(0) == 2

proc inferred(): auto = 4
proc throughConst(): int =
  const value = inferred()
  value
doAssert throughConst() == 4

proc forward(): int {.raises: [], gcsafe.}
proc useForward(): int {.raises: [], gcsafe.} = forward()
proc forward(): int = 6
doAssert useForward() == 6

# NimNode in the signature implicitly makes this routine compile-time. That
# is discovered after parsing its header, so it must flush earlier bodies
# before inferring its own effects.
proc runtimeValue(): int = 3
proc treeValue(): NimNode = newLit(runtimeValue())
type NodeFactory = proc(): NimNode {.nimcall, raises: [].}
static:
  let factory: NodeFactory = treeValue
  doAssert factory().intVal == 3

echo "deferred lookup OK"
