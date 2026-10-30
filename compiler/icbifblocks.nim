## Experimental block-addressed IC BIF representation inside LMDB.
when defined(icLmdbBlocks) and not defined(icLmdb):
  {.error: "-d:icLmdbBlocks requires -d:icLmdb".}
when defined(icLmdbBlocks):
  import std/[assertions, varints]
  import "../dist/checksums/src/checksums" / sha1
  import "../dist/nimony/src/lib" / [nifcore, bif]
  import iclmdb
  when defined(icBlockStats):
    import std/[exitprocs, syncio]
    var manifestLoads, partialReads, fullReads, tokenBytes, blockBytesRead: int64
    proc reportBlockStats() {.noconv.} =
      if manifestLoads > 0:
        stderr.writeLine("ICBLOCKSTATS ", manifestLoads, " ", partialReads, " ",
                         fullReads, " ", tokenBytes, " ", blockBytesRead)
    addExitProc(reportBlockStats)

  const
    BlockBytes* = 64 * 1024
    Magic = "ICBLK001"

  type BlockManifest* = ref object
    snapshot: Snapshot
    metadata*: pointer
    metadataSize*: int
    tokenCount*: int
    seed*: int32
    widths*: seq[int32]

  proc appendU32(s: var string; v: uint32) =
    for i in 0 .. 3: s.add char((v shr (i * 8)) and 0xff)

  proc readU32(p: ptr UncheckedArray[char]; pos: int): uint32 =
    result = 0
    for i in 0 .. 3: result = result or (uint32(uint8(p[pos + i])) shl (i * 8))

  proc appendVarint(s: var string; n: uint64) =
    var b = default(array[maxVarIntLen, byte])
    let used = writeVu64(b, n)
    for i in 0 ..< used: s.add char(b[i])

  proc readVarint(s: string; pos: var int): uint64 =
    result = 0
    pos += readVu64(toOpenArrayByte(s, pos, min(pos + maxVarIntLen, s.len) - 1), result)

  proc unusedId(b: var TokenBuf): int32 =
    result = 0
    if b.len == 0: return
    var c = b.beginRead()
    if c.kind != TagLit: return
    inc c
    while c.hasMore:
      if c.kind == TagLit:
        if tagName(c.tags, c.cursorTagId) == "unusedid":
          inc c
          if c.hasMore and c.kind == IntLit: result = int32 intVal(c)
          return
        skip c
      else:
        inc c

  proc storeBlocks*(b: var TokenBuf; path, dottedSuffix: string; stable: bool) =
    let full = bif.storeToString(b, dottedSuffix)
    var pos = 16
    let tokenCount = int readVarint(full, pos)
    let countsStart = pos
    for _ in 0 ..< 4: discard readVarint(full, pos)
    let countsEnd = pos
    let tokenStart = (pos + 3) and not 3
    let tokenEnd = tokenStart + tokenCount * sizeof(NifToken)
    doAssert tokenCount == b.len and tokenEnd <= full.len
    var metadata = full[0 ..< 16]
    metadata.appendVarint(0)
    metadata.add full[countsStart ..< countsEnd]
    while (metadata.len and 3) != 0: metadata.add '\0'
    metadata.add full[tokenEnd .. ^1]
    let index = bif.buildIndex(b, dottedSuffix)
    var manifest = Magic
    manifest.appendU32(uint32 unusedId(b))
    manifest.appendU32(uint32 tokenCount)
    manifest.appendU32(uint32 index.len)
    manifest.appendU32(uint32 metadata.len)
    manifest.add $secureHash(full)
    for entry in index:
      var c = cursorAt(b, int(entry.pos))
      manifest.appendU32(uint32 subtreeWidth(c))
    manifest.add metadata
    var blocks: seq[string] = @[]
    var start = tokenStart
    while start < tokenEnd:
      let stop = min(start + BlockBytes, tokenEnd)
      blocks.add full[start ..< stop]
      start = stop
    putRecords(path, manifest, blocks, stable)

  proc loadManifest*(path: string): BlockManifest =
    when defined(icBlockStats): inc manifestLoads
    new result
    result.snapshot = beginSnapshot(path)
    let blob = result.snapshot.record("")
    if blob.size < 64: raise newException(IOError, "invalid LMDB BIF manifest")
    let p = cast[ptr UncheckedArray[char]](blob.data)
    for i in 0 ..< 8:
      if p[i] != Magic[i]: raise newException(IOError, "invalid LMDB BIF manifest")
    result.seed = cast[int32](readU32(p, 8))
    result.tokenCount = int(readU32(p, 12))
    let n = int(readU32(p, 16))
    result.metadataSize = int(readU32(p, 20))
    let start = 64 + n * 4
    if start < 64 or start > blob.size or result.metadataSize > blob.size - start:
      raise newException(IOError, "truncated LMDB BIF manifest")
    result.widths = newSeq[int32](n)
    for i in 0 ..< n: result.widths[i] = int32(readU32(p, 64 + i * 4))
    # Keep metadata aligned for the BIF reader regardless of LMDB's value alignment.
    result.metadata = alloc(result.metadataSize)
    copyMem(result.metadata, addr p[start], result.metadataSize)

  proc copyTokens*(m: BlockManifest; start, count: int; dest: pointer) =
    if start < 0 or count < 0 or start > m.tokenCount or count > m.tokenCount - start:
      raise newException(IOError, "invalid LMDB BIF token range")
    var offset = start * sizeof(NifToken)
    var remaining = count * sizeof(NifToken)
    when defined(icBlockStats):
      if start == 0 and count == m.tokenCount: inc fullReads
      else: inc partialReads
      tokenBytes += int64(remaining)
    var outOffset = 0
    while remaining > 0:
      let blockIndex = offset div BlockBytes
      let blockOffset = offset mod BlockBytes
      let blob = m.snapshot.record("#" & $blockIndex)
      when defined(icBlockStats): blockBytesRead += int64(blob.size)
      let n = min(remaining, blob.size - blockOffset)
      if n <= 0: raise newException(IOError, "truncated LMDB BIF block")
      copyMem(cast[pointer](cast[uint](dest) + uint(outOffset)),
              cast[pointer](cast[uint](blob.data) + uint(blockOffset)), n)
      inc offset, n
      inc outOffset, n
      dec remaining, n
