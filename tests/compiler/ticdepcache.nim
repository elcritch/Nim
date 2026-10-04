discard """
  output: "IC dependency cache OK"
  cmd: "nim c --skipParentCfg --threads:on -r $options $file"
  matrix: "--mm:arc; --mm:atomicArc"
"""

import std/[os, times, tempfiles, atomics, memfiles]
import ../../dist/nimony/src/lib/[nifcore, bif, vfs]
import ../../compiler/icbif
import ../../compiler/ic/workercontext

var opened, closed: Atomic[int]

proc countedClose(blob: var VfsBlob) =
  let backing = cast[ptr VfsBlob](blob.cookie)
  closeBlob(backing[])
  deallocShared(backing)
  discard closed.fetchAdd(1)

proc countedOpen(path: string): VfsBlob =
  let backing = cast[ptr VfsBlob](allocShared0(sizeof(VfsBlob)))
  backing[] = fromMemFile(memfiles.open(path))
  discard opened.fetchAdd(1)
  initBlob(backing.data, backing.size, backing, countedClose)

proc writeModule(path, value: string) =
  var buffer = createTokenBuf()
  buffer.buildTree buffer.tags.registerTag("stmts"):
    # The final declaration of a repeated name must win, including on a hit.
    for i in 0..<2:
      buffer.buildTree buffer.tags.registerTag("sd"):
        buffer.addSymDef("value.0.cache")
        buffer.addIdent("x")
        buffer.addStrLit(value)
  bif.store(buffer, path)

proc valueCursor(module: var IndexedBif): Cursor =
  doAssert module.index.entries.len == 2
  let symbol = module.index.entries[0].sym
  doAssert module.index.bySym[symbol.int] == 1
  doAssert icbif.findSym(module.buf.pool, "value.0.cache") == symbol
  doAssert icbif.poolSym(module.buf.pool, symbol) == "value.0.cache"
  result = module.buf.cursorAt(module.index.entries[1].pos)
  inc result # sd
  inc result # symbol
  inc result # visibility

proc readValue(path: string): string =
  var module = loadIndexed(path)
  var cursor = valueCursor(module)
  result = icbif.strVal(cursor)

proc finishJob() =
  clearLazyPools()
  endIcWorker()

proc cacheWorker(path: string) {.thread.} =
  {.cast(gcsafe).}:
    setDependencyCacheBudget(DefaultDependencyCacheBytes)
    for i in 0..<20:
      beginIcWorker()
      doAssert readValue(path) == "new"
      finishJob()
    let stats = dependencyCacheStats()
    doAssert stats.misses == 1 and stats.hits == 19
    # The thread destruction handler must release the final cached mapping.

let directory = createTempDir("nim-ic-depcache-", "")
let previousOpen = openMmapRelay
openMmapRelay = countedOpen
try:
  let path = directory / "module.bif"
  let other = directory / "other.bif"
  writeModule(path, "old")
  writeModule(other, "two")
  setDependencyCacheBudget(DefaultDependencyCacheBytes)
  beginIcWorker()
  var firstPool: Pool
  var firstIndex: BifIndex
  block:
    var module = loadIndexed(path)
    firstPool = module.buf.pool
    firstIndex = module.index
    var cursor = valueCursor(module)
    doAssert icbif.strVal(cursor) == "old"
  finishJob()
  let weight = dependencyCacheStats().retainedBytes
  doAssert opened.load() == 1 and closed.load() == 0
  beginIcWorker()
  block:
    var module = loadIndexed(path)
    doAssert module.buf.pool == firstPool
    doAssert module.index == firstIndex
    var oldCursor = valueCursor(module)
    let stamp = getLastModificationTime(path)
    let size = getFileSize(path)
    writeModule(path, "new") # atomic replacement, same size and restored mtime
    setLastModificationTime(path, stamp)
    doAssert getFileSize(path) == size
    doAssert readValue(path) == "new"
    clearDependencyCache()
    doAssert icbif.strVal(oldCursor) == "old", "replaced images need job leases"
  reset(firstPool)
  reset(firstIndex)
  finishJob()
  doAssert opened.load() == closed.load()
  doAssert dependencyCacheStats().hits == 1

  # Eviction must keep an active cursor valid; retained cache data is bounded.
  setDependencyCacheBudget(weight)
  beginIcWorker()
  block:
    var module = loadIndexed(path)
    var cursor = valueCursor(module)
    doAssert readValue(other) == "two"
    doAssert dependencyCacheStats().evictions > 0
    doAssert dependencyCacheStats().retainedBytes <= weight
    doAssert icbif.strVal(cursor) == "new"
  finishJob()
  setDependencyCacheBudget(1) # oversized entries are usable but not retained
  beginIcWorker()
  doAssert readValue(path) == "new"
  finishJob()
  doAssert dependencyCacheStats().entries == 0
  doAssert opened.load() == closed.load()

  # A failed load must neither populate the cache nor keep its mapping alive.
  setDependencyCacheBudget(DefaultDependencyCacheBytes)
  let bad = directory / "bad.bif"
  writeFile(bad, "invalid!")
  beginIcWorker()
  var rejected = false
  try:
    discard readValue(bad)
  except IcJobExit:
    rejected = true
  finishJob()
  doAssert rejected
  doAssert dependencyCacheStats().entries == 0
  doAssert opened.load() == closed.load()

  var workers: array[2, Thread[string]]
  for worker in workers.mitems: createThread(worker, cacheWorker, path)
  joinThreads(workers)
  doAssert opened.load() == closed.load(), "worker exit must unmap cached files"
finally:
  clearLazyPools()
  clearDependencyCache()
  openMmapRelay = previousOpen
  removeDir(directory)

echo "IC dependency cache OK"
