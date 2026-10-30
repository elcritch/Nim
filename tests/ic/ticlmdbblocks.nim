## Run with -d:icLmdb -d:icLmdbBlocks and LMDB configured.
when defined(icLmdbBlocks):
  import std/[assertions, os, times]
  import ../../compiler/[icbif, icbifblocks]
  import ../../dist/nimony/src/lib/[nifcore, bif]

  let dir = getTempDir() / ("nim-icblocks-test-" & $getCurrentProcessId())
  createDir(dir)
  let path = dir / "module.s.bif"
  var b = createTokenBuf()
  b.openTag(b.tags.registerTag("stmts"))
  b.openTag(b.tags.registerTag("unusedid"))
  b.addIntLit(42)
  b.closeTag()
  b.openTag(b.tags.registerTag("proc"))
  b.addSymDef("f.0.module")
  b.addDotToken()
  for i in 0 ..< 20000: b.addIntLit(i)
  b.closeTag()
  b.closeTag()
  storeBlocks(b, path, ".module", true)
  var partial = icbif.loadPartial(path)
  doAssert partial.blocks.seed == 42
  doAssert partial.blocks.tokenCount == b.len
  doAssert partial.module.index.len > 0
  let e = partial.module.index[0]
  var declaration = b.cursorAt(int(e.pos))
  let width = subtreeWidth(declaration)
  doAssert int(partial.blocks.widths[0]) == width
  var loaded = createTokenBuf(width, partial.module.buf.pool, partial.module.buf.tags)
  partial.blocks.copyTokens(int(e.pos), width, loaded.growRawUninit(width))
  doAssert equalMem(loaded.rawTokenPtr, cast[pointer](cast[uint](b.rawTokenPtr) +
                     uint(e.pos) * sizeof(NifToken).uint), width * sizeof(NifToken))
  var full = icbif.load(path)
  doAssert full.buf.len == b.len
  doAssert equalMem(full.buf.rawTokenPtr, b.rawTokenPtr, b.len * sizeof(NifToken))
  let oldTime = fromUnix(1234567890)
  setLastModificationTime(path, oldTime)
  storeBlocks(b, path, ".module", true)
  doAssert getLastModificationTime(path) == oldTime
  # Replacing a module atomically must not change a reader's old snapshot.
  b[b.len - 1] = b[b.len - 2]
  storeBlocks(b, path, ".module", true)
  var oldCopy = createTokenBuf(width, partial.module.buf.pool, partial.module.buf.tags)
  partial.blocks.copyTokens(int(e.pos), width, oldCopy.growRawUninit(width))
  doAssert equalMem(oldCopy.rawTokenPtr, loaded.rawTokenPtr, width * sizeof(NifToken))
  var newer = icbif.load(path)
  doAssert equalMem(newer.buf.rawTokenPtr, b.rawTokenPtr, b.len * sizeof(NifToken))
  when not defined(windows): removeDir(dir)
