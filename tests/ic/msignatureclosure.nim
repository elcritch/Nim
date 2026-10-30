proc nestedCapture*(x: int): int =
  proc inner(y: int): int = x + y
  inner(3)

proc nestedTwice*(x: int): int =
  proc outer(y: int): int =
    proc inner(z: int): int {.inline.} = z + 4
    x + inner(y)
  outer(3)

proc nestedLocals*(x: uint8): int =
  proc inner(): int =
    let index = x shr 1
    let values = [10, 20, 30, 40]
    result = values[index]
  inner()

proc nestedIndex*(data: string): string =
  var offset = 0
  proc outer(): string =
    while offset < data.len:
      let op = uint8(data[offset])
      inc offset
      if op > 21:
        proc inner(): string =
          var lookup = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]
          var output = ""
          while offset < data.len:
            let b = uint8(data[offset])
            inc offset
            var n1 = b shr 4
            var n2 = b and 15
            output.add lookup[n1]
            output.add lookup[n2]
          output
        return inner()
  outer()
