## One immutable ownership/liveness snapshot shared by every rendering actor.
## ConstPtr uses atomic ownership while the compiler's job-local ASTs use ARC.
## The snapshot contains value tables only: no PSym, PType, cursor or lazy pool.

# The threading smart-pointer generics use default-initialized results.
{.push warning[Uninit]: off, warning[ProveInit]: off.}

import std/[locks, os, isolation]
import threading/smartptrs
import ../cnif

export smartptrs.`[]`

type MergeSnapshot* = ConstPtr[MergeDecision]

var snapshotLock: Lock
var snapshotPath: string
var snapshotStamp: FileInfo
var snapshot: MergeSnapshot
initLock(snapshotLock)

proc sameVersion(a, b: FileInfo): bool =
  a.id == b.id and a.size == b.size and a.lastWriteTime == b.lastWriteTime and
    a.creationTime == b.creationTime

proc clearMergeSnapshot*() =
  ## Called after joining the pool. Existing leases also survive replacement
  ## or a cache clear; only the last reader releases the frozen value.
  withLock snapshotLock:
    reset(snapshot)
    reset(snapshotPath)

proc publishMergeSnapshot*(path: string; decision: sink MergeDecision) =
  ## The merge actor calls this after writing the artifact and before its
  ## completion signal releases the rendering jobs. Move the finished tables
  ## into the snapshot rather than serializing and parsing them again.
  let filename = absolutePath(path)
  let stamp = getFileInfo(filename)
  let frozen = newConstPtr(isolate(move(decision)))
  withLock snapshotLock:
    snapshot = frozen
    snapshotPath = filename
    snapshotStamp = stamp

proc acquireMergeSnapshot*(path: string): MergeSnapshot =
  result = default(MergeSnapshot)
  let filename = absolutePath(path)
  withLock snapshotLock:
    # Serialize a cache miss so concurrent readers parse at most once. The
    # merge producer normally publishes directly, making every reader a hit.
    if fileExists(filename):
      let stamp = getFileInfo(filename)
      if snapshotPath == filename and not snapshot.isNil and
          sameVersion(stamp, snapshotStamp):
        return snapshot
      var decision = readMergeDecision(filename)
      result = newConstPtr(isolate(move(decision)))
      if not result[].broken and sameVersion(stamp, getFileInfo(filename)):
        snapshot = result
        snapshotPath = filename
        snapshotStamp = stamp
    else:
      result = newConstPtr(MergeDecision(broken: true))

{.pop.}
