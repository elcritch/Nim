discard """
  matrix: "--mm:arc; --mm:orc"
"""

const binary = block:
  var data = newString(1_500_000)
  for i in 0 ..< data.len:
    data[i] = char(i mod 256)
  data

proc embeddedBinary(): string = binary

var value = embeddedBinary()
doAssert value.len == 1_500_000
for i, c in value:
  doAssert c == char(i mod 256)
doAssert value.cstring[value.len] == '\0'

# A borrowed constant must retain the normal string copy-on-write behavior.
value[0] = 'x'
doAssert binary[0] == '\0'
value.add "tail"
doAssert value.len == binary.len + 4
doAssert value[^4 .. ^1] == "tail"
