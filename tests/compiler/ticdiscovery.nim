discard """
  joinable: false
"""

import std/[assertions, os, osproc, strutils, tempfiles]

const nim = getCurrentCompilerExe()
let dir = createTempDir("nim_ic_discovery_", "")
let source = dir / "main.nim"
let binary = dir / "prog".addFileExt(ExeExt)

proc build(expected: string): string =
  let compiled = execCmdEx(quoteShellCommand([
    nim, "c", "--ic:on", "--parallelBuild:4", "-d:icProfile",
    "--hints:off", "--warnings:off", "--path:" & dir, "--nimcache:" & dir / "nc",
    "--out:" & binary, source]))
  doAssert compiled.exitCode == 0, compiled.output
  let ran = execCmdEx(quoteShell(binary))
  doAssert ran.exitCode == 0 and ran.output.strip == expected, ran.output
  result = compiled.output

try:
  for i in 0..<10:
    let body = if i == 9: "proc value9*(): int = 1\n"
               else: "import level" & $(i+1) & "\nproc value" & $i &
                     "*(): int = value" & $(i+1) & "() + 1\n"
    writeFile(dir / ("level" & $i & ".nim"), body)
  writeFile(dir / "gate.nim", "proc gateValue*(): int = 42\n")
  writeFile(dir / "broken.nim", "{.error: \"inactive include was followed\".}\n")
  writeFile(dir / "inactive.nim", "import broken\n")
  writeFile(source, """
import gate
const enabled = true
when enabled:
  import level0
when not enabled:
  include inactive
echo value0()
""")
  let cold = build("10")
  # One discovery exposes the whole unconditional subtree. Its depth must not
  # become a sequence of serial frontend rounds. Exclude the backend run.
  let builds = cold.count("ICBUILD ")
  if builds > 0: # the process fallback does not emit actor profiles
    let rounds = builds - 1
    doAssert rounds in 1..3, "unexpected discovery rounds: " & $rounds & "\n" & cold

  # Gate stops for a new macro import, so main is blocked this round. Its old
  # sidecar must not confirm the removed level0 subtree, even when that subtree
  # can no longer compile. Only jobs actually run have fresh discovery data.
  writeFile(dir / "hidden.nim", "proc hidden*(): int = 42\n")
  writeFile(dir / "gate.nim", """
import std/macros
macro imports(): untyped = parseStmt("import hidden")
imports()
proc gateValue*(): int = hidden()
""")
  writeFile(dir / "level9.nim", "{.error: \"stale import was confirmed\".}\n")
  writeFile(source, """
import gate
const enabled = false
when enabled:
  import level0
echo gateValue()
""")
  discard build("42")
finally:
  removeDir(dir)
