discard """
  output: "IC actors OK"
  cmd: "nim c --skipParentCfg -r $options $file"
  matrix: "--ic:off --mm:arc; --ic:on --mm:arc; --ic:off --mm:atomicArc; --ic:on --mm:atomicArc"
"""

import std/[os, times, tempfiles, atomics, strutils, assertions, json]
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
  of "defer": return # successful discovery stop, no module output yet
  of "ordered": return IcJobResult(output: args[1])
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

  # Successful discovery stops must not launch dependents before their input
  # exists. This is distinct from a compiler error: the driver will retry the
  # expanded graph, while unrelated branches can finish in the current round.
  let deferredOutput = dir / "deferred"
  let afterDeferred = dir / "after-deferred"
  let independentDeferred = dir / "independent-deferred"
  let beforeDeferred = calls.load()
  doAssert runIcJobs(@[
    IcJob(arguments: @["defer"], outputs: @[deferredOutput]),
    IcJob(arguments: @["join", afterDeferred, deferredOutput],
      outputs: @[afterDeferred], dependencies: @[0]),
    IcJob(arguments: @["join", independentDeferred], outputs: @[independentDeferred])],
    execute, workers = 2) == 0
  doAssert calls.load() == beforeDeferred + 2
  doAssert not fileExists(afterDeferred)
  doAssert fileExists(independentDeferred)
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

  # Profiling is reported by the coordinator after a reply, with the actual
  # worker identity and elapsed execution time. It must not change dispatch.
  var jobProfiles, buildProfiles: seq[JsonNode]
  doAssert runIcJobs(@[IcJob(command: "reuse", arguments: @["reuse"])],
    execute, workers = 2, profile = true,
    report = proc(s: string) =
      if s.startsWith("ICJOB "): jobProfiles.add parseJson(s[6..^1])
      elif s.startsWith("ICBUILD "): buildProfiles.add parseJson(s[8..^1])) == 0
  doAssert jobProfiles.len == 1 and buildProfiles.len == 1
  doAssert jobProfiles[0]["thread"].getInt != mainThread
  doAssert jobProfiles[0]["durationNs"].getBiggestInt >= 0
  doAssert buildProfiles[0]["executed"].getInt == 1
  doAssert buildProfiles[0]["workers"].getInt == 1 # capped by job count

  # Ready jobs that unlock a longer chain take priority over unrelated work.
  var dispatchOrder: seq[string]
  doAssert runIcJobs(@[
    IcJob(arguments: @["ordered", "short"]),
    IcJob(arguments: @["ordered", "critical"]),
    IcJob(arguments: @["ordered", "middle"], dependencies: @[1]),
    IcJob(arguments: @["ordered", "join"], dependencies: @[0, 2])],
    execute, workers = 1, report = proc(s: string) = dispatchOrder.add s) == 0
  doAssert dispatchOrder == @["critical", "short", "middle", "join"]

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
