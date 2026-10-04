const hasIcActors* = (defined(gcArc) or defined(gcAtomicArc)) and compileOption("threads") and
  not defined(nimKochBootstrap) and not defined(nimHasLibFFI) and
  not defined(icLocalSymStats) and not defined(icSymCount) and
  not defined(icDbgHash) and not defined(icDbgHashDump)
  # FFI may call process-global native state. These optional diagnostics keep
  # process-wide counters and exit hooks. icBNodeProf has per-job counters.
  # Ordinary ARC is sufficient: compiler graphs and caches stay on their OS
  # worker. Sigils moves actors/payloads and synchronizes its shared endpoints.

type
  IcJobResult* = object
    exitCode*: int
    output*: string
    when defined(icBNodeProf):
      profile*: string

  IcExecutor* = proc(arguments: seq[string]): IcJobResult {.nimcall, gcsafe.}
  IcReporter* = proc(message: string) {.closure.}
