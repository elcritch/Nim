proc identity*(x: int): int = x
proc constant*(): int = 13
proc ctValue*(): int = 17
proc addValues*(x, y: int): int = x + y
proc genericIdentity*[T](x: T): T = x
proc inlineValue*(x: int): int {.inline.} = x + 1
