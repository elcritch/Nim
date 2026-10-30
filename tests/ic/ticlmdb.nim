## Run with -d:icLmdb and LMDB's include/library paths configured.
when defined(icLmdb):
  import std/[assertions, os, times]
  import ../../compiler/iclmdb

  let dir = getTempDir() / ("nim-iclmdb-test-" & $getCurrentProcessId())
  createDir(dir)
  let path = dir / "module.s.bif"
  let first = "first\0binary content"
  putBif(path, first, true)
  let old = borrowBif(path)
  doAssert old.size == first.len
  doAssert equalMem(old.data, unsafeAddr first[0], first.len)

  let oldTime = fromUnix(1234567890)
  setLastModificationTime(path, oldTime)
  putBif(path, first, true)
  doAssert getLastModificationTime(path) == oldTime

  let second = "replacement\0binary content"
  putBif(path, second, true)
  doAssert getLastModificationTime(path) != oldTime
  let current = borrowBif(path)
  doAssert current.size == second.len
  doAssert equalMem(current.data, unsafeAddr second[0], second.len)
  # Borrowed data remains valid after a concurrent replacement.
  doAssert equalMem(old.data, unsafeAddr first[0], first.len)

  doAssertRaises IOError:
    discard borrowBif(dir / "missing.s.bif")
  when not defined(windows):
    removeDir(dir) # Unix permits unlinking the still-mapped test environment.
