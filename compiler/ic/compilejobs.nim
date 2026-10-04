## A complete compiler invocation with job-owned configuration and graph.
## Only argv and diagnostics cross the actor boundary; ASTs and VM state do not.

import std/[os, parseopt, strutils, strtabs, monotimes, times, json]
import ../[options, commands, cmdlinehelper, pathutils, idents, modulegraphs,
  ast, ast2nif, icbif, icconfig, extccomp, condsyms, cgendata, vmdef, debugutils,
  icprof]
import jobtypes, workercontext, sharedcounters
when defined(icBNodeProf):
  from ../icmodnames import moduleSuffix

proc processArgs(pass: TCmdLinePass; args: seq[string]; conf: ConfigRef) =
  var parser = initOptParser(args)
  var count = 0
  conf.commandLine.setLen 0
  while true:
    parser.next()
    case parser.kind
    of cmdEnd: break
    of cmdLongOption, cmdShortOption:
      conf.commandLine.add " "
      conf.commandLine.addCmdPrefix parser.kind
      conf.commandLine.add quoteShell(parser.key)
      if parser.val.len > 0:
        conf.commandLine.add ':'
        conf.commandLine.add quoteShell(parser.val)
      processSwitch(pass, parser, conf)
    of cmdArgument:
      conf.commandLine.add " " & quoteShell(parser.key)
      if processArgument(pass, parser, count, conf): break

proc compileIcJob*(args: seq[string];
                   dispatch: proc(graph: ModuleGraph) {.nimcall.}): IcJobResult =
  result = default(IcJobResult)
  let started = getMonoTime()
  var workStarted = started
  var dispatched = false
  var reportProfile = false
  var stage = "frontend"
  when defined(icBNodeProf): beginIcProfile()
  beginIcWorker()
  clearIcDecodeState()
  registerNifAstTags()
  var output = ""
  var graph: ModuleGraph = nil
  let cacheBefore = dependencyCacheStats()
  var reportCache = false
  when defined(icWorkerStats):
    let memoryBefore = getOccupiedMem()
  try:
    let conf = newConfigRef()
    conf.writelnHook = proc(message: string) {.gcsafe.} =
      output.add message
      output.add '\n'
    initDefines(conf.symbols)
    defineSymbol(conf.symbols, "nim_compiler")
    processArgs(passCmd1, args, conf)
    setFromProjectName(conf, conf.projectName)
    if conf.cmd == cmdM and conf.icProject.len > 0:
      conf.projectPath = AbsoluteDir conf.icProject.splitFile.dir
    setDefaultLibpath(conf)
    if not applyIcConfig(conf, conf.icPreparsedConfig):
      raise newException(ValueError, "missing or incompatible IC configuration")
    extccomp.initVars(conf)
    processArgs(passCmd2, args, conf)
    var cacheBudget = DefaultDependencyCacheBytes
    if isDefined(conf, "icDepCacheMiB"):
      let mib = parseInt(conf.symbols["icDepCacheMiB"])
      if mib < 0 or mib > high(int) div (1024 * 1024):
        raise newException(ValueError, "icDepCacheMiB must be a nonnegative memory budget")
      cacheBudget = mib * 1024 * 1024
    if isDefined(conf, "icNoDepCache"): cacheBudget = 0
    setDependencyCacheBudget(cacheBudget)
    reportCache = isDefined(conf, "icDepCacheStats")
    reportProfile = isDefined(conf, "icProfile")
    if conf.cmd == cmdNifC: stage = conf.icBackendStage
    if conf.selectedGC == gcUnselected: initOrcDefines(conf)
    when defined(icBNodeProf):
      if conf.cmd == cmdM: profTag = moduleSuffix(conf.projectFull.string, [])
    graph = newModuleGraph(newIdentCache(), conf)
    workStarted = getMonoTime()
    dispatched = true
    dispatch(graph)
    result.exitCode = ord(conf.errorCounter != 0)
  except IcJobExit as e:
    result.exitCode = e.exitCode
    if e.msg.len > 0: output.add e.msg & "\n"
  finally:
    let cleanupStarted = getMonoTime()
    if not dispatched: workStarted = cleanupStarted
    when defined(icWorkerStats):
      let memoryPeak = getOccupiedMem()
    releaseSharedCounters()
    # The VM and graph callbacks refer back to the graph. Break those cycles
    # before releasing the job's symbol/type arena and its mapped NIF buffers.
    if graph != nil:
      releaseIcCodegen(graph)
      if graph.vm != nil: reset(PCtx(graph.vm)[])
      reset(graph[])
    onNewConfigRef(nil)
    resetCompilerAst()
    releaseIcAst()
    clearIcDecodeState()
    endIcWorker()
    when defined(icBNodeProf): result.profile = endIcProfile()
    if reportProfile:
      output.add "ICCOMPILE " & $(%*{"thread": getThreadId(), "stage": stage,
        "setupNs": (workStarted - started).inNanoseconds,
        "workNs": (cleanupStarted - workStarted).inNanoseconds,
        "cleanupNs": (getMonoTime() - cleanupStarted).inNanoseconds}) & "\n"
    if reportCache:
      let stats = dependencyCacheStats()
      output.add "ICDEPCACHE " & $getThreadId() &
        " hits=" & $(stats.hits - cacheBefore.hits) &
        " misses=" & $(stats.misses - cacheBefore.misses) &
        " evictions=" & $(stats.evictions - cacheBefore.evictions) &
        " entries=" & $stats.entries & " bytes=" & $stats.retainedBytes & "\n"
    when defined(icWorkerStats):
      output.add "ICMEM " & $getThreadId() & " " & args.join(" ") &
        " before=" & $memoryBefore & " live=" & $memoryPeak &
        " after=" & $getOccupiedMem() & " total=" & $getTotalMem() & "\n"
    result.output = move(output)
