discard """
  joinable: false
"""

import std/[assertions, os, osproc, strutils, tempfiles, json, tables, sets]

const nim = getCurrentCompilerExe()
let dir = createTempDir("nim_ic_proc_actors_", "")
let source = dir / "main.nim"
let cache = dir / "nc"
let binary = dir / "prog".addFileExt(ExeExt)

proc build(workers: int; expected = "2412 148 0 1.0 9"): string =
  let compiled = execCmdEx(quoteShellCommand([
    nim, "c", "--ic:on", "--parallelBuild:" & $workers,
    "-d:icParallelBodies", "-d:icProfile", "--hints:off", "--warnings:off",
    "--nimcache:" & cache, "--out:" & binary, source]))
  doAssert compiled.exitCode == 0, compiled.output
  let ran = execCmdEx(quoteShell(binary))
  doAssert ran.exitCode == 0 and ran.output.strip == expected, ran.output
  compiled.output

proc snapshots(): Table[string, string] =
  for file in walkFiles(cache / "*.s.bif"):
    result[file] = readFile(file)

try:
  var program = ""
  for i in 0 ..< 12:
    program.add "proc calc" & $i & "(x: int): int =\n  var value = x\n"
    for j in 0 ..< 400:
      program.add "  value = (value + " & $(j mod 7) & ") mod 997\n"
    program.add "  value\n\n"
  program.add "proc control(x: int; flag: bool): int =\n  var value = x\n  var again = flag\n  while again:\n"
  for j in 0 ..< 50:
    program.add "    value = (value + " & $(j mod 7) & ") mod 997\n"
  program.add "    again = false\n  if flag: value\n  else: 0\n\n"
  program.add "proc fract(x: float): float =\n  var value = x\n"
  for j in 0 ..< 40: program.add "  value = value * 0.5 + 0.5\n"
  program.add "  value\n\n"
  # VM calls and a body depending on an earlier procedure stay on the module.
  program.add "proc constant(): int = 9\nproc dependent(): int =\n  const v = constant()\n  v\n"
  program.add "echo "
  for i in 0 ..< 12:
    if i > 0: program.add " + "
    program.add "calc" & $i & "(1)"
  program.add ", \" \", control(1, true), \" \", control(1, false), \" \", fract(1.0), \" \", dependent()\n"
  # 400 additions sum to 1197; (1+1197) mod 997 = 201.
  writeFile(source, program)
  let parallel = build(4)
  var bodies: seq[JsonNode]
  var threads: HashSet[int]
  for line in parallel.splitLines:
    if line.startsWith("ICBODY "):
      let job = parseJson(line[7..^1])
      if job["module"].getStr == "main":
        doAssert not job["fallback"].getBool, line
        bodies.add job
        threads.incl job["thread"].getInt
  if "ICBUILD " in parallel:
    doAssert bodies.len == 14, parallel
    doAssert threads.len >= 2, "sibling procedures must use different OS workers"
    var overlapped = false
    for i in 0 ..< bodies.len:
      for j in i + 1 ..< bodies.len:
        if bodies[i]["thread"] != bodies[j]["thread"] and
            bodies[i]["startNs"].getBiggestInt < bodies[j]["endNs"].getBiggestInt and
            bodies[j]["startNs"].getBiggestInt < bodies[i]["endNs"].getBiggestInt:
          overlapped = true
    doAssert overlapped, "body semantic checking must actually overlap"
  let expected = snapshots()
  # The same header/defer path with one worker supplies the sequential oracle.
  for file in expected.keys: removeFile(file)
  discard build(1)
  doAssert snapshots() == expected, "semantic artifacts changed with worker count"
  discard build(4)
  let warm = snapshots()
  let noop = build(4)
  doAssert "ICBODY " notin noop and snapshots() == warm

  writeFile(source, program.replace("constant(): int = 9", "constant(): int = 10"))
  discard build(4, "2412 148 0 1.0 10")

  # Failed speculation must report the normal error from the module thread.
  writeFile(source, program.replace("  var value = x", "  var value: bool = x"))
  let rejected = execCmdEx(quoteShellCommand([nim, "c", "--ic:on",
    "--parallelBuild:4", "-d:icParallelBodies", "--nimcache:" & cache, source]))
  doAssert rejected.exitCode != 0 and "type mismatch" in rejected.output,
    rejected.output
finally:
  removeDir(dir)
