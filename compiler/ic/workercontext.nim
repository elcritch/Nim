## Process-exit requests become job completion when the compiler runs in a
## Sigils worker. This also covers `quit` in the compile-time VM and the
## successful early stop used to discover macro-generated imports.

import std/[envvars, strtabs]

type
  IcJobExit* = object of CatchableError
    exitCode*: int

var inIcWorker* {.threadvar.}: bool
var icEnvironment* {.threadvar.}: StringTableRef

proc beginIcWorker*() =
  icEnvironment = newStringTable(when defined(windows): modeCaseInsensitive
                                else: modeCaseSensitive)
  for key, value in envPairs(): icEnvironment[key] = value
  inIcWorker = true

proc endIcWorker*() =
  inIcWorker = false
  reset(icEnvironment)

proc compilerGetEnv*(key: string; default = ""): string =
  if inIcWorker: icEnvironment.getOrDefault(key, default)
  else: getEnv(key, default)

proc compilerExistsEnv*(key: string): bool =
  if inIcWorker: icEnvironment.hasKey(key)
  else: existsEnv(key)

proc compilerPutEnv*(key, value: string) =
  if inIcWorker: icEnvironment[key] = value
  else: putEnv(key, value)

proc compilerDelEnv*(key: string) =
  if inIcWorker: icEnvironment.del(key)
  else: delEnv(key)

iterator compilerEnvPairs*(): (string, string) =
  if inIcWorker:
    for key, value in pairs(icEnvironment): yield (key, value)
  else:
    for key, value in envPairs(): yield (key, value)

proc exitIcJob*(code: int; message = "") {.noreturn.} =
  var e = newException(IcJobExit, message)
  e.exitCode = code
  raise e
