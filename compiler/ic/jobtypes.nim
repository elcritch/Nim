import semhandoff
export semhandoff.IcHeaderUse

const hasIcActors* = (defined(gcArc) or defined(gcAtomicArc)) and compileOption("threads") and
  not defined(nimKochBootstrap) and not defined(nimHasLibFFI) and
  not defined(icLocalSymStats) and not defined(icSymCount) and
  not defined(icDbgHash) and not defined(icDbgHashDump)
  # FFI may call process-global native state. These optional diagnostics keep
  # process-wide counters and exit hooks. icBNodeProf has per-job counters.
  # Ordinary ARC is sufficient: compiler graphs and caches stay on their OS
  # worker. Sigils moves actors/payloads and synchronizes its shared endpoints.

const hasIcBodyHandoff* = hasIcActors and not compileOption("panics")
  # Pending-body control flow must unwind to the worker, including through
  # lazy AST accessors. A compiler built with panics enabled cannot catch it.

type
  IcJobResult* = object
    exitCode*: int
    output*: string
    waitFor*: string              # retry after this semantic artifact is complete
    waitReason*: string
    usedHeaders*: seq[IcHeaderUse] # immutable early interfaces read by this job
    changedHeader*: bool          # final semantics changed its published interface
    headerSnapshot*: string
    when defined(icBNodeProf):
      profile*: string

  IcExecutor* = proc(arguments: seq[string]): IcJobResult {.nimcall, gcsafe.}
  IcReporter* = proc(message: string) {.closure.}
