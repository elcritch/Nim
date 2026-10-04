discard """
  output: "IC worker profiling OK"
  cmd: "nim c --skipParentCfg --threads:on -d:icBNodeProf -r $options $file"
  matrix: "--mm:arc; --mm:atomicArc"
"""

import std/[os, strutils]
import ../../compiler/icprof

proc worker(id: int) {.thread.} =
  for job in 1..10:
    beginIcProfile()
    profStageName = "worker" & $id
    prof pKind, id * 100 + job
    timedOutermost tSemBody:
      timedOutermost tSemBody:
        sleep(1) # allow the other worker to update its counters
    let report = endIcProfile()
    doAssert ("stage=worker" & $id & " ") in report, report
    doAssert (" Kind=" & $(id * 100 + job) & " ") in report, report
    doAssert " SemBodyn=1 " in report, report
    beginIcProfile()
    doAssert endIcProfile() == "", "an empty job must not report earlier counters"

var workers: array[2, Thread[int]]
for i in 0..<workers.len: createThread(workers[i], worker, i + 1)
joinThreads(workers)
echo "IC worker profiling OK"
