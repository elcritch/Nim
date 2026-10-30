# Content digests for immutable compiler artifacts. Reuse is coordinated by the
# IC driver's cache lock and semantic BIFs are published by atomic replacement.
# Inode identity plus nanosecond ctime/mtime detects replacement/in-place edits;
# each record is itself integrity checked and atomically published.
import std/[json, os, strutils, tempfiles, times]
import ../dist/checksums/src/checksums/sha2
from icconfigbundle import fingerprintFile
when defined(nimPreviewSlimSystem):
  import std/syncio

proc fingerprintBytes*(bytes: string): string = $Sha_256.secureHash(bytes)

proc validFingerprint*(value: string): bool =
  if value.len != 64: return false
  for c in value:
    if c notin {'0'..'9', 'a'..'f'}: return false
  result = true

proc fileStamp*(path: string): string =
  let info = getFileInfo(path)
  result = $info.id & ":" & $info.size & ":" &
    $info.lastWriteTime.toUnix & ":" & $info.lastWriteTime.nanosecond & ":" &
    $info.creationTime.toUnix & ":" & $info.creationTime.nanosecond

proc digestPath(store, path, stamp: string): string =
  store / (fingerprintBytes(path & "\0" & stamp) & ".json")

proc readCachedDigest*(store, path, stamp: string): string =
  result = ""
  if store.len == 0: return
  try:
    let parts = readFile(digestPath(store, path, stamp)).splitLines()
    if parts.len != 3 or parts[2].len != 0 or fingerprintBytes(parts[0]) != parts[1]: return
    let doc = parseJson(parts[0])
    if doc.kind != JObject or doc["version"].getInt != 1 or
        doc["path"].getStr != path or doc["stamp"].getStr != stamp or
        not validFingerprint(doc["hash"].getStr): return
    result = doc["hash"].getStr
  except CatchableError: discard

proc cacheDigest*(store, path, stamp, hash: string) =
  if store.len == 0 or not validFingerprint(hash): return
  var temporary = ""
  try:
    createDir(store)
    let (file, name) = createTempFile("digest-", ".tmp", store)
    temporary = name
    file.close()
    let bytes = $(%*{"version": 1, "path": path, "stamp": stamp, "hash": hash})
    writeFile(temporary, bytes & "\n" & fingerprintBytes(bytes) & "\n")
    moveFile(temporary, digestPath(store, path, stamp))
  except CatchableError: discard
  finally:
    if temporary.len > 0 and fileExists(temporary):
      try: removeFile(temporary)
      except OSError: discard

proc fingerprintFileCached*(path, store: string): string =
  let before = fileStamp(path)
  result = readCachedDigest(store, path, before)
  if result.len > 0:
    if fileStamp(path) == before: return
    result = ""
  # A changed identity must never be cached under the old one. Hashing callers
  # either compare against consumed bytes or independently verify immutable
  # publication; this routine does not authorize reuse of mutable source files.
  result = fingerprintFile(path)
  if fileStamp(path) == before: cacheDigest(store, path, before, result)
