## Nested procedure jobs share the module pool's admission budget. Reserve a
## slot BEFORE queuing either kind of actor: a waiting module can never occupy
## the last worker needed by its children.
{.push warning[Uninit]: off, warning[ProveInit]: off.}
import std/[atomics, locks]
import sigils
import sigils/threads

type
  BodyPool* = object
    pool*: SigilThreadPoolPtr
    occupied: Atomic[int]
  BodyExecutor* = proc(data: pointer) {.nimcall, gcsafe.}
  BodyCompletion = object
    lock: Lock
    cond: Cond
    done: bool
  BodyAgent = ref object of AgentActor
    data: pointer
    execute: BodyExecutor
    budget: ptr BodyPool
    completion: ptr BodyCompletion
  BodyRequest = ref object of Agent
  BodyTicket* = object
    proxy: AgentProxy[BodyAgent]
    request: BodyRequest
    completion: ptr BodyCompletion

var currentBodyPool* {.threadvar.}: ptr BodyPool

proc tryOccupy*(p: ptr BodyPool; slots = 1): bool =
  doAssert slots > 0
  var n = p.occupied.load(moRelaxed)
  while n <= p.pool.workerCount - slots:
    if p.occupied.compareExchange(n, n + slots, moAcquireRelease, moRelaxed):
      return true

proc release*(p: ptr BodyPool) =
  discard p.occupied.fetchSub(1, moRelease)

proc requested(self: BodyRequest) {.signal.}

proc process(self: BodyAgent) {.slot.} =
  try:
    self.execute(self.data)
  finally:
    self.budget.release()
    let completion = self.completion
    acquire(completion.lock)
    completion.done = true
    signal(completion.cond)
    release(completion.lock)

proc submitBody*(p: ptr BodyPool; data: pointer; execute: BodyExecutor): BodyTicket =
  ## Caller owns a reservation. Payload ownership passes to execute until join.
  result.completion = createShared(BodyCompletion)
  initLock(result.completion.lock)
  initCond(result.completion.cond)
  var actor = BodyAgent(data: data, execute: execute, budget: p,
    completion: result.completion)
  result.proxy = actor.moveToThread(p.pool)
  result.request = BodyRequest()
  connectThreaded(result.request, requested, result.proxy, process)
  emit result.request.requested()

proc joinBody*(ticket: var BodyTicket) =
  let completion = ticket.completion
  acquire(completion.lock)
  while not completion.done: wait(completion.cond, completion.lock)
  release(completion.lock)
  reset(ticket.proxy)
  reset(ticket.request)
  deinitCond(completion.cond)
  deinitLock(completion.lock)
  deallocShared(completion)
  ticket.completion = nil

{.pop.}
