discard """
  joinable: false
"""

import std/[assertions, os, osproc, strutils, tempfiles, json, tables, sets]

const nim = getCurrentCompilerExe()
let dir = createTempDir("nim_ic_object_actors_", "")
let source = dir / "main.nim"
let cache = dir / "nc"
let binary = dir / "prog".addFileExt(ExeExt)

proc build(workers: int; incremental = true): tuple[log, output: string] =
  let built = execCmdEx(quoteShellCommand([nim, "c",
    "--ic:" & (if incremental: "on" else: "off"),
    "--parallelBuild:" & $workers, "-d:icParallelBodies", "-d:icProfile",
    "-d:icBodyStats", "--hints:off", "--warnings:off", "--nimcache:" & cache,
    "--out:" & binary, source]))
  doAssert built.exitCode == 0, built.output
  let ran = execCmdEx(quoteShell(binary))
  doAssert ran.exitCode == 0, ran.output
  (built.output, ran.output)

proc snapshots(): Table[string, string] =
  for file in walkFiles(cache / "*.s.bif"): result[file] = readFile(file)

proc jobs(log: string): seq[JsonNode] =
  for line in log.splitLines:
    let pos = line.find("ICBODY ")
    if pos >= 0:
      let job = parseJson(line[pos + 7 .. ^1])
      if job["module"].getStr == "main": result.add job

try:
  writeFile(dir / "helpers.nim", """
type
  Point* = object
    x*, y*: int
  Paint = object
    color: int
converter toPaint*(value: string | Point): Paint =
  when value is string: Paint(color: value.len)
  else: Paint(color: value.x)
proc step*(x: int): int = (x + 3) mod 997
""")
  var program = """
import helpers as h
from helpers import step
proc step(x: int): int = h.step(x) + 1
proc identity[T](x: T): T = x
proc warmGeneric(x: int): int = identity(x)
proc warmObject(p: h.Point): h.Point =
  var copy = p
  copy.x = copy.x + 1
  copy
type
  IntView = var int
  Mode = enum first, second
  Row = ref object
    text: string
    values: array[4, int]
    mode: Mode
proc warmRow(r: Row): int =
  if r == nil: return 0
  r.values[0] + r.text.len + ord(r.mode)
proc warmView(p: var h.Point): IntView = p.x
"""
  for i in 0 ..< 12:
    program.add "proc work" & $i & "(p: h.Point; delta: var int): h.Point =\n  var value = p\n"
    for j in 0 ..< 100:
      program.add "  if value.x >= 0: value.x = identity(h.step(value.x + delta))\n"
      program.add "  else: value.x = max(value.x, delta)\n  value.y = value.y + 1\n"
    program.add "  delta = value.x\n  value\n"
  # A pending callee ends a batch. Both callers can start once its inferred
  # effects have been merged, using its checked signature without its body.
  program.add "proc base(x: int): int =\n  var v = x\n"
  for j in 0 ..< 100: program.add "  v = step(v)\n"
  program.add "  v\n"
  for name in ["left", "right"]:
    program.add "proc " & name & "(x: int): int =\n  var v = base(x)\n"
    for j in 0 ..< 100: program.add "  v = step(v)\n"
    program.add "  v\n"
  for i in 0 ..< 4:
    program.add "proc readRow" & $i & "(r: Row): int =\n  if r == nil: return 0\n  var total = 0\n"
    for j in 0 ..< 80:
      program.add "  total = total + r.values[0] + r.text.len + ord(r.mode)\n"
    program.add "  total\n"
  for i in 0 ..< 3:
    program.add "proc view" & $i & "(p: var h.Point): IntView =\n  var value = p.x\n"
    for j in 0 ..< 80: program.add "  value = value + 1\n"
    program.add "  p.x = value\n  p.x\n"
  # This fresh instantiation and this VM-dependent body retain the module path.
  program.add "proc fresh(x: float): float = identity(x)\n"
  program.add "proc ct(): int {.compileTime.} = 9\nproc vm(): int = ct()\n"
  program.add "var d = 1\nvar p = h.Point(x: 1, y: 2)\n"
  for i in 0 ..< 12: program.add "p = work" & $i & "(p, d)\n"
  program.add "echo p.x, \" \", p.y, \" \", left(d), \" \", right(d), \" \", fresh(1.5), \" \", vm()\n"
  program.add "let row = Row(text: \"abc\", values: [3, 4, 5, 6], mode: second)\n"
  for i in 0 ..< 4: program.add "echo readRow" & $i & "(row), \" \", readRow" & $i & "(nil)\n"
  for i in 0 ..< 3: program.add "view" & $i & "(p) = " & $(i + 5) & "\necho p.x\n"
  writeFile(source, program)
  let oracle = build(1, incremental = false).output
  let parallel = build(4)
  doAssert parallel.output == oracle
  let bodies = jobs(parallel.log)
  if "ICBUILD " in parallel.log:
    var successful: HashSet[string]
    var overlap = false
    for i, body in bodies:
      if not body["fallback"].getBool: successful.incl body["routine"].getStr
      for j in i + 1 ..< bodies.len:
        let other = bodies[j]
        if body["thread"] != other["thread"] and
            body["startNs"].getBiggestInt < other["endNs"].getBiggestInt and
            other["startNs"].getBiggestInt < body["endNs"].getBiggestInt:
          overlap = true
    for i in 0 ..< 12: doAssert "work" & $i in successful, parallel.log
    for name in ["left", "right"]: doAssert name in successful, parallel.log
    for i in 0 ..< 4: doAssert "readRow" & $i in successful, parallel.log
    for i in 0 ..< 3: doAssert "view" & $i in successful, parallel.log
    doAssert overlap, "different whole procedures must overlap"
  let expected = snapshots()
  for file in expected.keys: removeFile(file)
  doAssert build(1).output == oracle
  doAssert snapshots() == expected, "worker count changed semantic artifacts"
  discard build(4)
  doAssert jobs(build(4).log).len == 0

  # Changing the shared runtime helper must affect all its callers.
  let helpers = readFile(dir / "helpers.nim")
  writeFile(dir / "helpers.nim", helpers.replace("x + 3", "x + 4"))
  let changed = build(4)
  doAssert changed.output != oracle
  doAssert changed.output == build(1, incremental = false).output
finally:
  removeDir(dir)
