discard """
  output: "IC actors OK"
  cmd: "nim c --skipParentCfg -r $options $file"
  matrix: "--ic:off; --ic:on"
"""

import std/[os, times, tempfiles, atomics, strutils, assertions]
import compiler/ic/actors
import compiler/ic/workercontext

var entered: Atomic[int]
var calls: Atomic[int]
var workerVisits {.threadvar.}: int
var reusedWorker: Atomic[int]
let mainThread = getThreadId()

proc execute(args: seq[string]): IcJobResult {.gcsafe.} =
  doAssert getThreadId() != mainThread
  calls.atomicInc()
  case args[0]
  of "reuse":
    inc workerVisits
    reusedWorker.store(workerVisits)
    return
  of "parallel":
    entered.atomicInc()
    let deadline = epochTime() + 5
    while entered.load() < 2 and epochTime() < deadline: sleep(1)
    doAssert entered.load() == 2, "two independent actors must overlap"
  of "fail": return IcJobResult(exitCode: 7, output: "intentional failure")
  of "raise": raise newException(ValueError, "worker exception")
  of "environment":
    beginIcWorker()
    try:
      doAssert not compilerExistsEnv("NIM_IC_ACTOR_UNIT_LOCAL")
      compilerPutEnv("NIM_IC_ACTOR_UNIT_LOCAL", "private")
      doAssert compilerGetEnv("NIM_IC_ACTOR_UNIT_LOCAL") == "private"
    finally:
      endIcWorker()
    return
  else: discard
  for i in 2..<args.len: doAssert fileExists(args[i])
  writeFile(args[1], "done")

let dir = createTempDir("nim-ic-actors-", "")
try:
  let left = dir / "left"
  let right = dir / "right"
  let root = dir / "root"
  let jobs = @[
    IcJob(arguments: @["parallel", left], outputs: @[left]),
    IcJob(arguments: @["parallel", right], outputs: @[right]),
    IcJob(arguments: @["join", root, left, right], inputs: @[left, right],
      outputs: @[root], dependencies: @[0, 1])]
  doAssert runIcJobs(jobs, execute, workers = 2) == 0
  doAssert calls.load() == 3
  doAssert runIcJobs(jobs, execute, workers = 2) == 0
  doAssert calls.load() == 3, "a warm build must schedule no compiler jobs"

  # A cookie preserving its timestamp must not make a multi-output rule stale
  # forever; a missing output must still force the producer to run.
  let base = initTime(1_700_000_000, 0)
  setLastModificationTime(left, base)
  setLastModificationTime(right, base + initDuration(milliseconds = 100))
  setLastModificationTime(root, base + initDuration(milliseconds = 200))
  doAssert not needsRebuild(IcJob(inputs: @[right], outputs: @[left, root]))
  doAssert needsRebuild(IcJob(inputs: @[root], outputs: @[right]))
  doAssert needsRebuild(IcJob(outputs: @[dir / "missing"]))

  let failedOutput = dir / "failed"
  let blockedOutput = dir / "blocked"
  let independent = dir / "independent"
  var diagnostics = ""
  doAssert runIcJobs(@[
    IcJob(arguments: @["fail", failedOutput], outputs: @[failedOutput]),
    IcJob(arguments: @["join", blockedOutput], outputs: @[blockedOutput], dependencies: @[0]),
    IcJob(arguments: @["join", independent], outputs: @[independent])],
    execute, workers = 2, report = proc(s: string) = diagnostics.add s) == 7
  doAssert "intentional failure" in diagnostics
  doAssert not fileExists(blockedOutput)
  doAssert fileExists(independent)
  doAssert runIcJobs(@[IcJob(arguments: @["raise"], outputs: @[failedOutput])],
    execute, workers = 1) == 1

  var rejected = false
  try:
    discard runIcJobs(@[IcJob(dependencies: @[1]), IcJob(dependencies: @[0])], execute)
  except ValueError: rejected = true
  doAssert rejected, "cycles must be rejected without waiting for a signal"

  var external: seq[IcJob] = @[]
  for i in 0..<64:
    external.add IcJob(command: "echo", arguments: @["echo", $i])
  var replies = 0
  doAssert runIcJobs(external, runExternalJob, workers = 8,
    report = proc(s: string) =
      discard parseInt(s.strip())
      inc replies) == 0
  doAssert replies == 64

  # The same OS worker must start each compiler invocation with fresh state.
  doAssert runIcJobs(@[IcJob(arguments: @["environment"]),
    IcJob(arguments: @["environment"])], execute, workers = 1) == 0
  doAssert not existsEnv("NIM_IC_ACTOR_UNIT_LOCAL")

  # Discovery rounds and backend work retain the same OS workers, including
  # after a failed job. The caller closes the pool after the final round.
  let session = newIcWorkerPool(workers = 1)
  try:
    doAssert runIcJobs(@[IcJob(arguments: @["reuse"])], execute, session = session) == 0
    doAssert reusedWorker.load() == 1
    doAssert runIcJobs(@[IcJob(arguments: @["raise"])], execute, session = session) == 1
    doAssert runIcJobs(@[IcJob(arguments: @["reuse"])], execute, session = session) == 0
    doAssert reusedWorker.load() == 2
  finally:
    session.close()
  session.close() # idempotent cleanup
finally:
  removeDir(dir)

echo "IC actors OK"
