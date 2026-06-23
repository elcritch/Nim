discard """
  targets: "c"
  joinable: false
  disabled: "windows"
"""

import std/[os, osproc, strformat, strutils]

const
  nim = getCurrentCompilerExe()
  producerSource = """
type
  Vec2* = object
    x*, y*: float32

  Token* = object
    id*: int

  Box*[T] = object
    value*: T

  Child* = ref object
    label*: string

  Base* = ref object of RootObj
    baseId*: int

  Renderer* = ref object of Base
    name*: string
    size*: Vec2
    scale*: float32
    child*: Child
    token*: Token

proc `=destroy`(x: var Token) =
  x.id = 0

proc makeRenderer*(): Renderer {.exportnimabi.} =
  Renderer(
    baseId: 1,
    name: "main",
    size: Vec2(x: 1'f32, y: 2'f32),
    scale: 1'f32,
    child: Child(label: "child"),
    token: Token(id: 7))

proc rendererScale*(r: Renderer): float32 {.exportnimabi.} =
  r.scale

proc `$`*(r: Renderer): string {.exportnimabi.} =
  result = "Renderer(" & repr(r) & ")"

proc makeIntBox*(): Box[int] {.exportnimabi.} =
  Box[int](value: 42)

proc makeStringBox*(): Box[string] {.exportnimabi.} =
  Box[string](value: "generic")

proc boxIntValue*(box: Box[int]): int {.exportnimabi.} =
  box.value

proc boxStringLen*(box: Box[string]): int {.exportnimabi.} =
  box.value.len
"""
  consumerSource = """
import std/strutils
import producer_abi

let r = makeRenderer()
doAssert r.baseId == 1
r.baseId = 11
r.name = "consumer"
r.size.x = 7'f32
r.size.y = 8'f32
r.scale = 9'f32
r.child.label = "child-updated"
r.token.id = 42
let rendered = $r
let intBox = makeIntBox()
let stringBox = makeStringBox()
let localIntBox = Box[int](value: 12)
let localStringBox = Box[string](value: "local")
doAssert r.baseId == 11
doAssert r.name == "consumer"
doAssert r.size.x == 7'f32
doAssert r.size.y == 8'f32
doAssert rendererScale(r) == 9'f32
doAssert r.child.label == "child-updated"
doAssert r.token.id == 42
doAssert "Renderer(" in rendered
doAssert intBox.value == 42
doAssert stringBox.value == "generic"
doAssert boxIntValue(localIntBox) == 12
doAssert boxStringLen(localStringBox) == 5
"""
  mismatchSource = """
import producer_abi
"""

when defined(macosx):
  const libProducer = "libproducer.dylib"
else:
  const libProducer = "libproducer.so"

proc runCmd(cmd: string): string =
  let (outp, exitCode) = execCmdEx(cmd, options = {poStdErrToStdOut})
  doAssert exitCode == 0, cmd & "\n" & outp
  result = outp

proc runCmdFailure(cmd: string): string =
  let (outp, exitCode) = execCmdEx(cmd, options = {poStdErrToStdOut})
  doAssert exitCode != 0, cmd & "\nexpected failure\n" & outp
  result = outp

proc checkHookWrapperOrder(abiModule: string) =
  let text = readFile(abiModule)
  let hookPos = text.find("proc `=destroy`(dest: var Token)")
  let procPos = text.find("proc makeRenderer*()")
  doAssert hookPos >= 0, "missing imported hook wrapper"
  doAssert procPos >= 0, "missing imported proc wrapper"
  doAssert hookPos < procPos, "hook wrapper must attach before proc wrappers"

proc checkInitCallPlacement(abiModule: string) =
  let text = readFile(abiModule)
  let initPos = text.find("\ninitProducerAbi()\n")
  let procPos = text.find("proc makeRenderer*()")
  doAssert initPos >= 0, "missing top-level ABI init call"
  doAssert procPos >= 0, "missing imported proc wrapper"
  doAssert initPos < procPos, "top-level ABI init must run before proc wrappers"
  doAssert text.count("initProducerAbi()\n") == 1,
    "expected exactly one top-level ABI init call"
  doAssert "nimAbiEnsureInitialized" notin text,
    "generated ABI module should use initProducerAbi directly"
  doAssert "  if nimAbiValidated: return\n" in text,
    "initProducerAbi should be idempotent"

proc checkDirectProcImports(abiModule: string) =
  let text = readFile(abiModule)
  doAssert "proc makeRenderer*(): Renderer {.importc:" in text,
    "ordinary proc should import directly"
  doAssert "proc rendererScale*(r: Renderer): float32 {.importc:" in text,
    "ordinary proc should import directly"
  doAssert "proc nimAbiProc_makeRenderer_" notin text,
    "ordinary proc should not need a private import wrapper"
  doAssert "proc nimAbiProc_boxIntValue_" in text,
    "generic facade proc still needs a raw import wrapper"

proc checkGenericObjectNames(abiModule: string) =
  let text = readFile(abiModule)
  doAssert "NimAbi_ZN8producer3BoxI3intEE*" in text,
    "missing concrete Box[int] ABI type"
  doAssert "NimAbi_ZN8producer3BoxI6stringEE*" in text,
    "missing concrete Box[string] ABI type"
  doAssert "Box*[T] = object" in text, "missing public generic Box facade"
  doAssert "proc makeIntBox*(): Box[int]" in text
  doAssert "proc makeStringBox*(): Box[string]" in text
  doAssert "proc boxIntValue*(box: Box[int]): int" in text
  doAssert "proc boxStringLen*(box: Box[string]): int" in text

let root = getTempDir() / "nim_exportnimabi_e2e_" & $getCurrentProcessId()
removeDir(root)
createDir(root)

let
  producer = root / "producer.nim"
  consumer = root / "consumer.nim"
  mismatch = root / "consumer_mismatch.nim"
  prodCache = root / "prodcache"
  consCache = root / "conscache"
  libPath = root / libProducer

writeFile(producer, producerSource)
writeFile(consumer, consumerSource)
writeFile(mismatch, mismatchSource)

discard runCmd(fmt"{nim.quoteShell} c --hints:off --app:lib " &
  fmt"--nimcache:{prodCache.quoteShell} --out:{libPath.quoteShell} " &
  producer.quoteShell)

let rpathOpt = "-Wl,-rpath," & root
let linkOpts = fmt"--path:{prodCache.quoteShell} " &
  fmt"--cincludes:{prodCache.quoteShell} --passL:{libPath.quoteShell} " &
  fmt"--passL:{rpathOpt.quoteShell}"

discard runCmd(fmt"{nim.quoteShell} c -r --hints:off " &
  fmt"--nimcache:{consCache.quoteShell} {linkOpts} {consumer.quoteShell}")
checkHookWrapperOrder(prodCache / "producer_abi.nim")
checkInitCallPlacement(prodCache / "producer_abi.nim")
checkDirectProcImports(prodCache / "producer_abi.nim")
checkGenericObjectNames(prodCache / "producer_abi.nim")

for (define, expected) in [
  ("nimAbiMismatchLayout", "Nim ABI layout mismatch"),
  ("nimAbiMismatchHookWrappers", "Nim ABI hook wrapper mismatch"),
  ("nimAbiMismatchCompiler", "Nim ABI compiler mismatch"),
  ("nimAbiMismatchAllocator", "Nim ABI allocator mismatch"),
  ("nimAbiMismatchMemoryManager", "Nim ABI memory manager mismatch")]:
  let cache = root / ("mismatch_" & define)
  let outp = runCmdFailure(fmt"{nim.quoteShell} c -r --hints:off " &
    fmt"--nimcache:{cache.quoteShell} {linkOpts} -d:{define} " &
    mismatch.quoteShell)
  doAssert expected in outp, define & "\n" & outp

removeDir(root)
