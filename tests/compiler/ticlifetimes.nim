discard """
  output: "IC lifetimes OK"
  cmd: "nim c --skipParentCfg --mm:atomicArc --threads:on -r $options $file"
"""

import std/[os, tempfiles, strutils]
import ../../dist/nimony/src/lib/[nifcore, bif]
import ../../compiler/icbif
import ../../compiler/ic/workercontext

proc survivingCursor(): Cursor =
  var buffer = createTokenBuf()
  buffer.addStrLit("a cursor keeps its pool and tokens alive")
  result = buffer.beginRead()

block:
  var cursor = survivingCursor()
  doAssert nifcore.strVal(cursor) == "a cursor keeps its pool and tokens alive"
  cursor.endRead()

proc borrowedMutation() =
  var tokens = [dotToken()]
  var buffer = adoptForeignTokens(addr tokens[0], tokens.len)
  # A unique borrowed buffer still needs to copy before growing its storage.
  buffer.addIntLit(42)
  var cursor = buffer.beginRead()
  doAssert cursor.kind == DotToken
  inc cursor
  doAssert cursor.intVal == 42
  doAssert kind(tokens[0]) == DotToken

borrowedMutation()

let directory = createTempDir("nim-ic-lifetimes-", "")
try:
  let filename = directory / "module.bif"
  block:
    var buffer = createTokenBuf()
    buffer.buildTree buffer.tags.registerTag("stmts"):
      for i in 0..<64:
        buffer.addStrLit(repeat('x', 4096) & $i)
    bif.store(buffer, filename)

  proc readModule() =
    var module = icbif.load(filename)
    var cursor = module.buf.beginRead()
    inc cursor
    for i in 0..<64:
      doAssert icbif.strVal(cursor) == repeat('x', 4096) & $i
      inc cursor

  proc runJob() =
    beginIcWorker()
    try:
      readModule()
    finally:
      clearLazyPools()
      endIcWorker()

  runJob() # warm allocator and library state before measuring retained memory
  let baseline = getOccupiedMem()
  for i in 0..<100: runJob()
  doAssert getOccupiedMem() - baseline < 1024 * 1024,
    "finished IC jobs must release their NIF pools and borrowed buffer owners"
finally:
  removeDir(directory)

echo "IC lifetimes OK"
