discard """
  output: "ok"
  targets: "c"
  matrix: "--experimental:abi --emitBif:on"
  ccodecheck: "'N_LIB_EXPORT N_NIMCALL\\(NI, _ZN10texportnim6chooseE3int\\)'"
  ccodecheck: "'N_LIB_EXPORT N_NIMCALL\\(NI, _ZN10texportnim6chooseE6string\\)'"
  ccodecheck: "'N_LIB_EXPORT N_NIMCALL\\(NI, _ZN10texportnim3tagE3BoxI3intE\\)'"
  ccodecheck: "'N_LIB_EXPORT N_NIMCALL\\(NI, _ZN10texportnim3tagE3BoxI6stringE\\)'"
"""

import std/[compilesettings, os, strutils, syncio]
import mexportabi_support

type
  Box[T] = object
    value: T

proc choose(x: int): int {.exportabi.} =
  x

proc choose(x: string): int {.exportabi.} =
  x.len

proc tag[T](box: Box[T]): int {.exportabi.} =
  when T is int:
    box.value
  else:
    box.value.len

discard tag(Box[int](value: 3))
discard tag(Box[string](value: "nim"))
doAssert exportedFromSupport(1) == 2

let manifestPath = querySetting(nimcacheDir) / "texportnim.abi.nif"
doAssert fileExists(manifestPath)

var hasSemanticBif = false
for path in walkFiles(querySetting(nimcacheDir) / "*.s.bif"):
  hasSemanticBif = true
doAssert hasSemanticBif

let manifest = readFile(manifestPath)
doAssert manifest.startsWith("(.nif27)")
doAssert manifest.contains("(.dialect \"nim-native-dynlib\")")
doAssert manifest.contains("(format 2)")
doAssert manifest.contains("(library \"")
doAssert manifest.contains("(modules\n  (module \"")
doAssert manifest.contains("\" \"texportnim\")")
doAssert manifest.contains("\" \"mexportabi_support\")")
doAssert manifest.count("(module \"") == 2
doAssert manifest.count("(proc \"") == 5
doAssert manifest.count(" true)") == 2
doAssert manifest.count(" false)") == 3
echo "ok"
