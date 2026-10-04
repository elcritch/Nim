discard """
  output: "IC shared merge snapshot OK"
  cmd: "nim c --skipParentCfg --threads:on -r $options $file"
  matrix: "--mm:arc; --mm:atomicArc"
"""

import std/[os, tempfiles, tables, sets, times]
import ../../compiler/cnif
import ../../compiler/ic/mergecache

static:
  doAssert not compiles(block:
    var frozen: MergeSnapshot
    frozen[].live.incl "mutation")

proc decision(name: string): MergeDecision =
  result.live.incl name
  result.owners[name] = name & ".c.nif"

type Work = tuple[path: string, expected: pointer]
proc worker(work: Work) {.thread.} =
  {.cast(gcsafe).}:
    for i in 0..<100:
      let shared = acquireMergeSnapshot(work.path)
      doAssert cast[pointer](unsafeAddr shared[]) == work.expected,
        "readers must borrow the same frozen tables"
      doAssert "old" in shared[].live
      doAssert shared[].owners["old"] == "old.c.nif"

let dir = createTempDir("nim-ic-mergecache-", "")
try:
  let path = dir / "merge.nif"
  writeMergeDecision(path, decision("old"))
  publishMergeSnapshot(path, decision("old"))
  let old = acquireMergeSnapshot(path)
  var readers: array[4, Thread[Work]]
  for reader in readers.mitems:
    createThread(reader, worker, (path, cast[pointer](unsafeAddr old[])))
  joinThreads(readers)

  # File replacement invalidates the shared cache even at equal size/mtime.
  let stamp = getLastModificationTime(path)
  let replacement = dir / "replacement.nif"
  writeMergeDecision(replacement, decision("new"))
  doAssert getFileSize(path) == getFileSize(replacement)
  setLastModificationTime(replacement, stamp)
  moveFile(replacement, path)
  let fresh = acquireMergeSnapshot(path)
  doAssert "new" in fresh[].live and "old" notin fresh[].live
  doAssert "old" in old[].live
  clearMergeSnapshot()
  doAssert fresh[].owners["new"] == "new.c.nif", "leases survive cache clear"
  removeFile(path)
  doAssert acquireMergeSnapshot(path)[].broken, "missing files cannot reuse a snapshot"
finally:
  clearMergeSnapshot()
  removeDir(dir)
echo "IC shared merge snapshot OK"
