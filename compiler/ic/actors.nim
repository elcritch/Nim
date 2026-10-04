## IC's build graph, executed by Sigils module actors. The coordinator owns
## dependency counts and file timestamps; workers only receive value jobs.
## Import cycles are already collapsed by deps.nim into one semantic job.

# Sigils templates use Nim's default-initialized containers.
{.push warning[Uninit]: off, warning[ProveInit]: off.}

import std/[os, osproc, times, tables, sets, deques, locks, streams, monotimes, json,
            heapqueue]
import sigils
import sigils/threads
import "../../dist/nimony/src/lib" / [nifcore, nifcoreparse]
import jobtypes
import mergecache
export jobtypes
when defined(icBNodeProf): import ../icprof

type
  IcJob* = object
    command*: string
    arguments*: seq[string]       # executable followed by individual argv entries
    inputs*, outputs*: seq[string]
    dependencies*: seq[int]

  IcJobObserver* = proc(job: IcJob; exitCode: int) {.closure.}

  CommandPart = object
    kind, value: string
    first, last: int
  Rule = object
    job: IcJob
    args, inputsOf: seq[string]

proc invalid(message: string) {.noreturn.} =
  raise newException(ValueError, "invalid IC build graph: " & message)

proc name(c: Cursor): string =
  case c.kind
  of Symbol, SymbolDef: symName(c)
  of Ident, StrLit: strVal(c)
  else: invalid("expected a name")

proc tagName(c: Cursor): string = c.tags.tags[c.cursorTagId]

proc loadIcJobs*(filename: string): seq[IcJob] =
  ## Read the same generated rules used by nifmake, so the two schedulers
  ## share all interface/implementation cookies and discovery dependencies.
  result = @[]
  var commands = initTable[string, seq[CommandPart]]()
  var rules: seq[Rule] = @[]
  var buf = parseFromFile(filename)
  var n = beginRead(buf)
  defer: endRead(n)
  if n.kind != TagLit or tagName(n) != "stmts": invalid("expected stmts")
  n.loopInto:
    if n.kind != TagLit: invalid("expected cmd or do")
    let kind = tagName(n)
    if kind == "cmd":
      n.loopInto:
        let command = name(n)
        inc n
        var parts: seq[CommandPart] = @[]
        while n.hasMore:
          if n.kind == StrLit:
            parts.add CommandPart(kind: "literal", value: strVal(n))
            inc n
          elif n.kind == TagLit:
            var part = CommandPart(kind: tagName(n))
            if part.kind notin ["input", "output", "args"]:
              invalid("unsupported command field " & part.kind)
            n.loopInto:
              if n.kind != IntLit: invalid("expected input/output index")
              part.first = intVal(n).int
              part.last = part.first
              inc n
              if n.hasMore:
                part.last = intVal(n).int
                inc n
            parts.add part
          else: invalid("expected argument")
        commands[command] = move(parts)
    elif kind == "do":
      var rule = default(Rule)
      n.loopInto:
        rule.job.command = name(n)
        inc n
        while n.hasMore:
          if n.kind != TagLit: invalid("expected rule field")
          let field = tagName(n)
          n.loopInto:
            let value = name(n)
            case field
            of "input": rule.job.inputs.add value
            of "output": rule.job.outputs.add value
            of "args": rule.args.add value
            of "inputsof": rule.inputsOf.add value
            else: invalid("unsupported rule field " & field)
            inc n
      rules.add move(rule)
    else: invalid("unsupported statement " & kind)

  var producers = initTable[string, int]()
  var phaseOutputs = initTable[string, seq[string]]()
  for i, rule in rules:
    for output in rule.job.outputs:
      if output in producers: invalid("duplicate output " & output)
      producers[output] = i
      phaseOutputs.mgetOrPut(rule.job.command, @[]).add output
  for i in 0..<rules.len:
    for phase in rules[i].inputsOf:
      if phase notin phaseOutputs: invalid("undeclared input phase " & phase)
      rules[i].job.inputs.add phaseOutputs.getOrDefault(phase)
    var seen = initHashSet[int]()
    for input in rules[i].job.inputs:
      if input in producers:
        let dep = producers[input]
        if dep != i and not seen.containsOrIncl(dep): rules[i].job.dependencies.add dep
    if rules[i].job.command notin commands:
      invalid("undeclared command " & rules[i].job.command)
    for part in commands[rules[i].job.command]:
      case part.kind
      of "literal": rules[i].job.arguments.add part.value
      of "args": rules[i].job.arguments.add rules[i].args
      else:
        let paths = if part.kind == "input": rules[i].job.inputs else: rules[i].job.outputs
        let first = if part.first < 0: paths.len + part.first else: part.first
        let last = if part.last < 0: paths.len + part.last else: part.last
        for j in first..last:
          if j >= 0 and j < paths.len: rules[i].job.arguments.add paths[j]
    result.add move(rules[i].job)

proc needsRebuild*(job: IcJob): bool =
  result = false
  if job.outputs.len == 0: return true
  var freshest = initTime(low(int64), 0)
  for path in job.outputs:
    if not fileExists(path): return true
    freshest = max(freshest, getLastModificationTime(path))
  for path in job.inputs:
    if fileExists(path) and getLastModificationTime(path) > freshest:
      return true

proc backendWeight(job: IcJob): int64 =
  ## Lowering/codegen jobs at the same dependency depth vary greatly in cost.
  ## Their first input is their own module image, a cheap estimate that starts
  ## the large modules early enough for smaller jobs to fill the remaining tail.
  ## Other commands retain source order, including frontend discovery.
  if job.command == "nim_nifc" and job.inputs.len > 0 and
      ("--icBackendStage:lower" in job.arguments or
       "--icBackendStage:cg" in job.arguments):
    try: return getFileSize(job.inputs[0])
    except OSError: discard
  result = 0

type
  IcWorkerPool* = ref object
    pool: SigilThreadPoolPtr
  ModuleAgent = ref object of AgentActor
    arguments: seq[string]
    command: string
    id: int
    execute: IcExecutor
    profile: bool
    submitted: MonoTime
  Request = ref object of Agent
  Completion = object
    id: int
    outcome: IcJobResult
    started, finished: MonoTime
    queueNs: int64
    thread: int
  Coordinator = ref object of Agent
    completed: Deque[Completion]

proc requested(self: Request) {.signal.}
proc finished(self: ModuleAgent; value: Completion) {.signal.}

proc process(self: ModuleAgent) {.slot.} =
  let started = if self.profile: getMonoTime() else: default(MonoTime)
  var outcome = default(IcJobResult)
  try:
    outcome = self.execute(self.arguments)
  except CatchableError as e:
    outcome = IcJobResult(exitCode: 1,
      output: "IC " & self.command & ": " & e.msg & "\n" & e.getStackTrace())
  except Defect as e:
    outcome = IcJobResult(exitCode: 1, output: e.msg & "\n" & e.getStackTrace())
  let finished = if self.profile: getMonoTime() else: default(MonoTime)
  emit self.finished(Completion(id: self.id, outcome: move(outcome),
    started: started, finished: finished, thread: getThreadId(),
    queueNs: (if self.profile: (started - self.submitted).inNanoseconds else: 0)))

proc record(self: Coordinator; value: Completion) {.slot.} =
  self.completed.addLast value

proc newIcWorkerPool*(workers = countProcessors()): IcWorkerPool =
  ## One compiler invocation can run several discovery rounds and backend
  ## phases on the same OS workers, retaining their dependency caches.
  startLocalThreadDefault()
  result = IcWorkerPool(pool: newSigilThreadPool(workers = max(1, workers)))
  result.pool.start()

proc close*(workers: IcWorkerPool) =
  if workers == nil or workers.pool == nil: return
  let pool = workers.pool
  workers.pool = nil
  pool.stop()
  pool.join() # also runs dependency-cache cleanup on every OS worker
  clearMergeSnapshot()
  # The pinned Sigils pool is manually allocated and has no dispose API.
  # No proxy or worker may retain it past this point.
  reset(pool[].references)
  reset(pool[].agent)
  reset(pool[].signaled)
  reset(pool[].toCancel)
  reset(pool[].ready)
  reset(pool[].states)
  reset(pool[].workers)
  deinitCond(pool[].queueCond)
  deinitLock(pool[].queueLock)
  deinitLock(pool[].signaledLock)
  deallocShared(pool)

proc runIcJobs*(jobs: seq[IcJob]; execute: IcExecutor;
                workers = countProcessors(); report: IcReporter = nil;
                session: IcWorkerPool = nil; profile = false;
                onComplete: IcJobObserver = nil): int =
  let started = if profile: getMonoTime() else: default(MonoTime)
  result = 0
  if jobs.len == 0: return 0
  # Validate and topologically check BEFORE starting any work: a cycle must
  # never strand the coordinator in a blocking poll.
  var pending = newSeq[int](jobs.len)
  var dependents = newSeq[seq[int]](jobs.len)
  var roots = initDeque[int]()
  for i, job in jobs:
    pending[i] = job.dependencies.len
    if pending[i] == 0: roots.addLast i
    for dep in job.dependencies:
      if dep < 0 or dep >= jobs.len: invalid("dependency out of range")
      dependents[dep].add i
  var order: seq[int] = @[]
  block:
    var counts = pending
    var queue = roots
    var visited = 0
    while queue.len > 0:
      let id = queue.popFirst()
      order.add id
      inc visited
      for next in dependents[id]:
        dec counts[next]
        if counts[next] == 0: queue.addLast next
    if visited != jobs.len: invalid("dependency cycle")

  # Start the longest remaining dependency chains first. A FIFO lets a large
  # wave of unrelated parser jobs delay system/sem jobs that unlock the tree.
  # Equal priorities prefer larger backend modules, then source order.
  var rank = newSeq[int](jobs.len)
  for i in countdown(order.high, 0):
    let id = order[i]
    for dep in jobs[id].dependencies:
      rank[dep] = max(rank[dep], rank[id] + 1)
  var ready = initHeapQueue[tuple[priority: int, weight: int64, id: int]]()
  template enqueue(id: int) = ready.push((-rank[id], -backendWeight(jobs[id]), id))
  for id in roots: enqueue(id)

  startLocalThreadDefault()
  let home = getCurrentSigilThread()
  let owner = if session != nil: session
              else: newIcWorkerPool(min(workers, jobs.len))
  let pool = owner.pool
  if pool == nil: invalid("worker pool is closed")
  try:
    block:
      let coordinator = Coordinator()
      var requests = newSeq[Request](jobs.len)
      var proxies = newSeq[AgentProxy[ModuleAgent]](jobs.len)
      var blocked = newSeq[bool](jobs.len)
      var active = 0
      var remaining = jobs.len
      var executed, skipped, deferred, blockedJobs, peakActive: int
      var busyNs: int64

      proc complete(id: int; failed: bool) =
        dec remaining
        for next in dependents[id]:
          blocked[next] = blocked[next] or failed
          dec pending[next]
          if pending[next] == 0: enqueue(next)

      while remaining > 0:
        while ready.len > 0 and active < pool[].workerCount:
          let id = ready.pop().id
          if blocked[id]:
            inc blockedJobs
            complete(id, true)
          elif not needsRebuild(jobs[id]):
            inc skipped
            complete(id, false)
          else:
            var actor = ModuleAgent(arguments: jobs[id].arguments,
              command: jobs[id].command, id: id, execute: execute, profile: profile,
              submitted: (if profile: getMonoTime() else: default(MonoTime)))
            proxies[id] = actor.moveToThread(pool)
            requests[id] = Request()
            connectThreaded(requests[id], requested, proxies[id], process)
            connectThreaded(proxies[id], finished, coordinator, Coordinator.record())
            inc active
            inc executed
            peakActive = max(peakActive, active)
            emit requests[id].requested()
        if active > 0:
          while coordinator.completed.len == 0: discard home.poll()
          while coordinator.completed.len > 0:
            let completion = coordinator.completed.popFirst()
            dec active
            if onComplete != nil:
              onComplete(jobs[completion.id], completion.outcome.exitCode)
            if completion.outcome.output.len > 0 and report != nil:
              report(completion.outcome.output)
            when defined(icBNodeProf):
              if completion.outcome.profile.len > 0:
                writeIcProfile(completion.outcome.profile)
            if profile and report != nil:
              let job = jobs[completion.id]
              let duration = (completion.finished - completion.started).inNanoseconds
              busyNs += duration
              report("ICJOB " & $(%*{"id": completion.id,
                "thread": completion.thread, "command": job.command,
                "output": (if job.outputs.len > 0: job.outputs[0] else: ""),
                "startNs": (completion.started - started).inNanoseconds,
                "queueNs": completion.queueNs,
                "durationNs": duration, "exitCode": completion.outcome.exitCode}))
            let failed = completion.outcome.exitCode != 0
            if failed: result = completion.outcome.exitCode
            # A semantic job stops successfully when it discovers an import
            # that has not been built yet. Its missing outputs mean that its
            # dependents cannot run this round, even though it did not fail.
            # Let independent branches finish and the driver discover the new
            # edges, instead of repeatedly starting the entire importer chain.
            var incomplete = false
            if not failed:
              for output in jobs[completion.id].outputs:
                if not fileExists(output):
                  incomplete = true
                  break
              if incomplete: inc deferred
            complete(completion.id, failed or incomplete)
            # The one request/reply exchange is done. Sigils retains a running
            # actor's lease until its slot returns, including when the proxy
            # closes just after its completion signal reaches us.
            reset(requests[completion.id])
            reset(proxies[completion.id])
      if profile and report != nil:
        report("ICBUILD " & $(%*{"workers": pool[].workerCount,
          "executed": executed, "skipped": skipped, "peakActive": peakActive,
          "deferred": deferred, "blocked": blockedJobs,
          "busyNs": busyNs, "wallNs": (getMonoTime() - started).inNanoseconds}))
      # Drop proxies while their scheduler is alive; all results have arrived.
  finally:
    if session == nil: owner.close()

proc runExternalJob*(arguments: seq[string]): IcJobResult {.gcsafe.} =
  if arguments.len == 0: invalid("empty command")
  let process = startProcess(arguments[0], args = arguments[1..^1],
    options = {poUsePath, poStdErrToStdOut})
  defer: process.close()
  process.inputStream.close()
  result.output = process.outputStream.readAll()
  result.exitCode = process.waitForExit()

{.pop.}
