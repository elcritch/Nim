discard """
  joinable: false
"""

import std/[assertions, os, osproc, strutils, tempfiles]

const nim = getCurrentCompilerExe()

proc run(serial: bool) =
  let dir = createTempDir("nim_ic_counter_", "")
  try:
    let source = dir / "main.nim"
    let cache = dir / "nc"
    let binary = dir / "prog".addFileExt(ExeExt)
    let flags = if serial: @["-d:icNoParallel"] else: @[]

    proc build(expected: string; fails = false) =
      let compiled = execCmdEx(quoteShellCommand(@[nim, "ic", "--hints:off",
        "--warnings:off", "--nimcache:" & cache, "--out:" & binary] & flags & @[source]))
      if fails:
        doAssert compiled.exitCode != 0, compiled.output
        doAssert expected in compiled.output, compiled.output
      else:
        doAssert compiled.exitCode == 0, compiled.output
        let executed = execCmdEx(quoteShell(binary))
        doAssert executed.exitCode == 0, executed.output
        doAssert executed.output.strip == expected, executed.output

    # Merely importing macrocache must retain the ordinary per-module frontend.
    writeFile(source, "import std/macrocache\necho \"ordinary\"\n")
    build("ordinary")
    doAssert not fileExists(cache / "ic.counter-session")

    writeFile(dir / "allocator.nim", """
import std/macrocache
const ids* = CacheCounter"tests.ic.counter.edits"
proc nextId*(): int {.compileTime.} =
  ids.inc
  ids.value
""")
    writeFile(dir / "first.nim", """
import allocator
when isMainModule:
  {.error: "imported module treated as main".}
const firstId* = nextId()
""")
    writeFile(dir / "view.nim", """
import std/macrocache
const snapshot* = CacheCounter"tests.ic.counter.edits".value
const otherStart = CacheCounter"tests.ic.counter.other".value
static:
  doAssert otherStart == 0
  CacheCounter"tests.ic.counter.other".inc(5)
  CacheCounter"tests.ic.counter.other".inc(-2)
const otherValue* = CacheCounter"tests.ic.counter.other".value
""")
    writeFile(dir / "second.nim", "import allocator\nconst secondId* = nextId()\n")
    let main = """
import first, view, second
static: doAssert isMainModule
echo firstId, ",", snapshot, ",", secondId, ",", otherValue
"""
    writeFile(source, main)
    build("1,1,2,3")
    build("1,1,2,3")
    doAssert fileExists(cache / "ic.counter-session")

    # A dependency-only edit shifts later allocations AND a read-only sibling.
    let untouchedMain = getLastModificationTime(source)
    writeFile(dir / "first.nim", readFile(dir / "first.nim") &
      "const extraId* = nextId()\n")
    build("1,2,3,3")
    build("1,2,3,3")
    doAssert getLastModificationTime(source) == untouchedMain

    # Every live module remains a declared output, even in the shared session.
    var removed = false
    for path in walkFiles(cache / "vie*.s.bif"):
      removeFile(path)
      removed = true
    doAssert removed
    build("1,2,3,3")

    # A rejected build cannot turn into a successful cached build on repetition.
    writeFile(source, main & "static: doAssert false, \"counter rejection\"\n")
    build("counter rejection", fails = true)
    build("counter rejection", fails = true)
    writeFile(source, main)
    build("1,2,3,3")
  finally:
    removeDir(dir)

run(serial = false)
run(serial = true)
