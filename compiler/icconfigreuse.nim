# Conservative, opt-in cross-configuration semantic bundle reuse.
# Unlike the diagnostic manifests, these records have a deliberately narrow
# eligibility contract: no macros, VM callbacks/FFI or effects, no source define mutation or other
# untracked observations, exact parsed source bytes and cached dependency contexts.
import std/[algorithm, json, os, sets, strtabs, strutils, tempfiles]
import options, icconfigbundle, icfilehashes
from icmodnames import moduleSuffix
export fingerprintBytes
when defined(nimPreviewSlimSystem):
  import std/syncio

when defined(posix):
  # The lock lives outside the cache: a format reset must not unlink its inode.
  # Close-on-exec keeps children from extending the driver's lock lifetime.
  import std/posix
  proc flock(fd, operation: cint): cint {.importc, header: "<sys/file.h>".}

proc lockReuseCache*(cacheDir: string): File =
  when defined(posix):
    createDir(cacheDir.parentDir)
    let canonical = if dirExists(cacheDir): expandFilename(cacheDir)
                    else: expandFilename(cacheDir.parentDir) / cacheDir.lastPathPart
    let path = canonical & ".ic-config.lock"
    result = open(path, fmAppend)
    let fd = getFileHandle(result)
    if fcntl(fd, F_SETFD, FD_CLOEXEC) < 0 or flock(fd, 2) < 0:
      result.close()
      raise newException(IOError, "cannot lock IC cache: " & path)
  else:
    raise newException(IOError, "IC configuration reuse currently requires POSIX file locks")

proc compilerFileStamp*(path: string): string =
  ## The driver hashes the binary once. Children verify its file identity has
  ## not changed, including inode and nanosecond change time, before using that
  ## hash. This avoids hashing the same executable in every semantic child.
  result = fileStamp(path)

proc ordinaryDefine*(name: string): bool =
  ## specialDefine changes effective options while processing a define. Keep
  ## these names, including undef and opposing switches, in the base key.
  name.normalize notin ["release", "danger", "quick", "nimquirky"]

proc ordinaryDefineArg*(arg: string): bool =
  if not arg.startsWith("-"): return false
  let start = if arg.startsWith("--"): 2 else: 1
  let sep = arg.find({':', '='}, start)
  if sep < 0 or arg[start..<sep].normalize notin ["d", "define", "u", "undef"]:
    return false
  let value = arg[sep+1..^1]
  let finish = value.find({':', '='})
  let name = if finish < 0: value else: value[0..<finish]
  result = name.len > 0 and ordinaryDefine(name)

proc defineState(conf: ConfigRef): JsonNode =
  result = newJObject()
  for key, value in conf.symbols: result[key.normalize] = %value

proc stableWrite(path, bytes: string; always = false) =
  if not always and fileExists(path) and readFile(path) == bytes: return
  createDir(path.parentDir)
  let temporary = path & ".reuse-tmp." & $getCurrentProcessId()
  try:
    writeFile(temporary, bytes)
    moveFile(temporary, path)
  finally:
    if fileExists(temporary): removeFile(temporary)

proc artifactContext*(conf: ConfigRef; suffix, digests: string): JsonNode =
  ## A producer computes its artifact context once. Consumers only check file
  ## identities, then compare the saved content IDs across configurations.
  result = newJArray()
  for kind in BundleArtifactKind:
    let path = semanticFile(conf, suffix, artifactExtension(kind)).string
    let stamp = fileStamp(path)
    let hash = fingerprintFileCached(path, digests)
    if fileStamp(path) != stamp:
      raise newException(IOError, "artifact changed while saving context")
    result.add %*{"stamp": stamp, "hash": hash}

proc dependencyFiles(conf: ConfigRef; plan: JsonNode; directOnly = false): JsonNode =
  result = newJArray()
  for dep in plan["dependencies"]:
    if directOnly and dep.hasKey("direct") and not dep["direct"].getBool: continue
    let statusPath = semanticFile(conf, dep["suffix"].getStr, ".reuse-inputs.json").string
    let status = parseFile(statusPath)
    if status.kind != JObject or status["version"].getInt != 2 or
        status["complete"].kind != JBool or not status["complete"].getBool or
        status["source"] != dep["source"] or status["compiler"] != plan["compiler"] or
        status["externalInputs"].kind != JBool or status["externalInputs"].getBool or
        status["artifacts"].kind != JArray or
        status["artifacts"].len != ord(high(BundleArtifactKind)) + 1:
      raise newException(ValueError, "dependency has no reusable context")
    var hashes = newJArray()
    for kind in BundleArtifactKind:
      let artifact = status["artifacts"][ord(kind)]
      let path = semanticFile(conf, dep["suffix"].getStr, artifactExtension(kind)).string
      if artifact.kind != JObject or not validFingerprint(artifact["hash"].getStr) or
          artifact["stamp"].getStr != fileStamp(path):
        raise newException(ValueError, "dependency context changed")
      hashes.add artifact["hash"]
    if status["dependencies"].kind != JArray:
      raise newException(ValueError, "missing dependency contexts")
    let context = fingerprintBytes($( %*{"hashes": hashes, "dependencies": status["dependencies"]}))
    if status["context"].getStr != context:
      raise newException(ValueError, "invalid dependency context")
    result.add %*{"source": dep["source"], "suffix": dep["suffix"],
                   "hashes": hashes, "context": context}

proc sourceFiles(plan: JsonNode): JsonNode =
  result = newJArray()
  for source in plan["sources"]:
    result.add %*{"path": source, "hash": fingerprintFileCached(source.getStr, plan["digests"].getStr)}

proc packageSnapshot*(paths: openArray[string]): JsonNode =
  # Package identity affects module ownership and override resolution. Probe
  # with a private cache so validation cannot change compiler lookup behavior.
  let probe = ConfigRef(packageCache: newPackageCache())
  var ordered: seq[string] = @[]
  for path in paths: ordered.add path
  ordered.sort()
  result = newJObject()
  for path in ordered: result[path] = %getNimbleFile(probe, path)

proc validPlan(plan: JsonNode): bool =
  if plan == nil or plan.kind != JObject: return false
  for field in ["store", "digests", "key", "compiler", "compilerStamp", "base", "project", "entry"]:
    if not plan.hasKey(field) or plan[field].kind != JString or plan[field].getStr.len == 0:
      return false
  if not plan["store"].getStr.isAbsolute or not plan["digests"].getStr.isAbsolute or not plan["project"].getStr.isAbsolute or
      not plan["entry"].getStr.isAbsolute or not validFingerprint(plan["key"].getStr) or
      not validFingerprint(plan["base"].getStr): return false
  if not plan.hasKey("packages") or plan["packages"].kind != JObject: return false
  for path, identity in plan["packages"]:
    if not path.isAbsolute or identity.kind != JString or
        (identity.getStr.len > 0 and not identity.getStr.isAbsolute): return false
  for field in ["members", "sources", "dependencies"]:
    if not plan.hasKey(field) or plan[field].kind != JArray: return false
  if plan["members"].len == 0 or plan["sources"].len == 0: return false
  var suffixes = initHashSet[string]()
  var names = initHashSet[string]()
  var sources = initHashSet[string]()
  for member in plan["members"]:
    if member.kind != JObject or not member.hasKey("source") or not member.hasKey("suffix") or
        member["source"].kind != JString or member["suffix"].kind != JString: return false
    let source = member["source"].getStr
    let suffix = member["suffix"].getStr
    if not source.isAbsolute or suffix.len == 0 or '/' in suffix or '\\' in suffix or
        names.containsOrIncl(source) or suffixes.containsOrIncl(suffix): return false
  for source in plan["sources"]:
    if source.kind != JString or not source.getStr.isAbsolute or
        sources.containsOrIncl(source.getStr): return false
  for name in names:
    if name notin sources: return false
  for dep in plan["dependencies"]:
    if dep.kind != JObject or not dep.hasKey("source") or not dep.hasKey("suffix") or
        dep["source"].kind != JString or dep["suffix"].kind != JString: return false
    let suffix = dep["suffix"].getStr
    if not dep["source"].getStr.isAbsolute or suffix.len == 0 or '/' in suffix or '\\' in suffix or
        names.containsOrIncl(dep["source"].getStr) or suffixes.containsOrIncl(suffix): return false
  var packagePaths = initHashSet[string]()
  for path in names: packagePaths.incl path
  for path in sources: packagePaths.incl path
  packagePaths.incl plan["entry"].getStr
  if packagePaths.len != plan["packages"].len: return false
  for path in packagePaths:
    if not plan["packages"].hasKey(path): return false
  result = true

type ReuseAttempt* = object
  plan, initialDefines, queries: JsonNode

proc observedDefines(conf: ConfigRef; attempt: ReuseAttempt): JsonNode =
  var queried = initHashSet[string]()
  if attempt.queries != nil:
    for key in attempt.queries.keys: queried.incl key
  for event in conf.icConfigTraceEvents:
    if event.kind in ["defined", "value"]: queried.incl event.key.normalize
  var keys: seq[string] = @[]
  for key in queried: keys.add key
  keys.sort()
  result = newJObject()
  for key in keys:
    result[key] = if attempt.initialDefines.hasKey(key): attempt.initialDefines[key] else: newJNull()

proc beginReuse*(conf: ConfigRef): ReuseAttempt =
  ## Called in a driver-launched `nim m`, after config replay and before sem.
  ## The independently scanned graph is part of the key, never obtained from
  ## a candidate's imports. A different graph or SCC selects a different key.
  result = default(ReuseAttempt)
  if conf.icReusePlan.len == 0 or conf.projectIsStdin or conf.projectIsCmd: return
  try:
    let plan = parseFile(conf.icReusePlan)
    if not validPlan(plan) or
        plan["compilerStamp"].getStr != compilerFileStamp(getAppFilename()) or plan["project"].getStr != conf.projectFull.string or
        plan["entry"].getStr != conf.icProject: return
    var group = initHashSet[string]()
    group.incl conf.projectFull.string
    for member in conf.icGroup: group.incl member
    var planned = initHashSet[string]()
    for member in plan["members"]: planned.incl member["source"].getStr
    if group != planned: return
    conf.icReuseDigests = plan["digests"].getStr
    result.plan = plan
    result.initialDefines = defineState(conf)
    result.queries = newJObject()
  except CatchableError:
    result = default(ReuseAttempt)

proc resetReuseInputs*(conf: ConfigRef; attempt: ReuseAttempt) =
  if conf.icReusePlan.len == 0: return
  var suffixes: seq[string] = @[]
  if attempt.plan != nil:
    for member in attempt.plan["members"]: suffixes.add member["suffix"].getStr
  else:
    # Invalid plans or missing sources must not preserve a previous child's
    # success status. The actual invocation still identifies its group.
    suffixes.add moduleSuffix(conf.projectFull.string, [])
    for source in conf.icGroup: suffixes.add moduleSuffix(source, [])
  for suffix in suffixes:
    try: removeFile(semanticFile(conf, suffix, ".reuse-inputs.json").string)
    except OSError: discard

proc writeReuseInputs*(conf: ConfigRef; attempt: ReuseAttempt) =
  if attempt.plan == nil: return
  try:
    var external = conf.icReuseExternalInputs
    for event in conf.icConfigTraceEvents:
      if event.kind == "untracked" and event.key notin
          ["compileOption", "compileOptionArg", "compiles", "defineMutation", "undefMutation",
           "compilePragma", "linkPragma"]:
        external = true
    var dependencies = newJArray()
    try: dependencies = dependencyFiles(conf, attempt.plan, directOnly = true)
    except CatchableError: external = true
    for member in attempt.plan["members"]:
      if not fileExists(semanticFile(conf, member["suffix"].getStr, ".s.bif").string): return
    for member in attempt.plan["members"]:
      let artifacts = artifactContext(conf, member["suffix"].getStr,
                                      attempt.plan["digests"].getStr)
      var hashes = newJArray()
      for artifact in artifacts: hashes.add artifact["hash"]
      let status = %*{"version": 2, "complete": true, "source": member["source"],
        "compiler": attempt.plan["compiler"], "externalInputs": external,
        "artifacts": artifacts, "dependencies": dependencies,
        "queries": observedDefines(conf, attempt), "context": fingerprintBytes($( %*{"hashes": hashes, "dependencies": dependencies}))}
      stableWrite(semanticFile(conf, member["suffix"].getStr, ".reuse-inputs.json").string,
                  $status & "\n", always = true)
  except CatchableError: discard # Missing evidence forces a downstream miss.

proc restoreReuse*(conf: ConfigRef; attempt: ReuseAttempt): bool =
  result = false
  if attempt.plan == nil or conf.icReuseUnsupportedVm or conf.icReuseExternalInputs: return false
  for event in conf.icConfigTraceEvents:
    if event.kind == "untracked": return false
  let plan = attempt.plan
  let directory = plan["store"].getStr / plan["key"].getStr
  if not dirExists(directory): return false
  var dependencies, sources: JsonNode = nil
  var candidates: seq[string] = @[]
  for kind, path in walkDir(directory):
    if kind == pcDir: candidates.add path
  candidates.sort()
  for candidate in candidates:
    try:
      let bytes = readFile(candidate / "manifest.json")
      if readFile(candidate / "READY") != fingerprintBytes(bytes) & "\n": continue
      let manifest = parseJson(bytes)
      if manifest.kind != JObject or manifest["version"].kind != JInt or
          manifest["version"].getInt != 1 or
          manifest["complete"].kind != JBool or not manifest["complete"].getBool or
          manifest["contract"].getStr != "cached-contexts-no-host-calls-v2" or manifest["plan"] != plan or
          manifest["queries"].kind != JObject or manifest["artifacts"].kind != JObject or
          manifest["dependencies"].kind != JArray or manifest["contexts"].kind != JArray:
        continue
      var match = true
      for key, value in manifest["queries"]:
        if value.kind notin {JNull, JString} or
            attempt.initialDefines{key} != value:
          # Absent table entries and explicit JSON null both represent absence.
          if not (value.kind == JNull and not attempt.initialDefines.hasKey(key)):
            match = false
      if not match: continue
      if dependencies == nil:
        dependencies = dependencyFiles(conf, plan, directOnly = true)
        var packagePaths: seq[string] = @[]
        for path in plan["sources"]: packagePaths.add path.getStr
        packagePaths.add plan["entry"].getStr
        let currentPackages = packageSnapshot(packagePaths)
        for path, identity in currentPackages:
          if plan["packages"]{path} != identity: return false
        sources = sourceFiles(plan)
      if manifest["sources"] != sources or manifest["contexts"] != dependencies: continue
      var copies: seq[tuple[path, bytes: string, stamp: bool]] = @[]
      for member in plan["members"]:
        let suffix = member["suffix"].getStr
        for kind in BundleArtifactKind:
          let name = suffix & artifactExtension(kind)
          let data = readFile(candidate / name)
          if manifest["artifacts"]{name}.getStr.len == 0 or
              fingerprintBytes(data) != manifest["artifacts"][name].getStr:
            match = false
            break
          copies.add (semanticFile(conf, suffix, artifactExtension(kind)).string,
                      data, kind == bakEdges)
        if not match: break
      if not match or manifest["artifacts"].len != copies.len: continue
      # Verify every byte before changing any destination. Rename each private
      # copy into the active configuration. nifmake schedules consumers only
      # after this entire group command succeeds; the driver holds the lock.
      for copy in copies: stableWrite(copy.path, copy.bytes, copy.stamp)
      for key, value in manifest["queries"]: attempt.queries[key] = value
      stderr.write("IC config reuse: hit " & conf.projectFull.string & "\n")
      return true
    except CatchableError:
      discard # Missing, partial, stale or corrupt data is an ordinary miss.

proc publishReuse*(conf: ConfigRef; attempt: ReuseAttempt) =
  if attempt.plan == nil: return
  let plan = attempt.plan
  var reason = ""
  if conf.icReuseUnsupportedVm or conf.icReuseExternalInputs:
    reason = "unsupported compile-time execution"
  for event in conf.icConfigTraceEvents:
    if event.kind == "untracked": reason = "untracked " & event.key
  if reason.len > 0:
    stderr.write("IC config reuse: fallback " & conf.projectFull.string & ": " & reason & "\n")
    return
  var directory = ""
  var published = false
  try:
    # Only the bytes actually parsed authorize reuse. The scanner's input set
    # must agree, including includes; conditional over-approximations miss.
    var parsed = newJObject()
    for source in conf.icReuseSources:
      if parsed.hasKey(source.path) and parsed[source.path].getStr != source.hash: return
      parsed[source.path] = %source.hash
    if parsed.len != plan["sources"].len: return
    var sources = newJArray()
    for source in plan["sources"]:
      let hash = parsed{source.getStr}.getStr
      if hash.len != 64 or fingerprintFileCached(source.getStr, plan["digests"].getStr) != hash: return
      sources.add %*{"path": source, "hash": hash}
    # Snapshot dependencies only for an eligible publication. Each BIF hash
    # describes the exact immutable mapping consumed. These hashes and actual
    # interface-cookie reads must agree with the independently built graph.
    let dependencies = dependencyFiles(conf, plan)
    var packagePaths: seq[string] = @[]
    for path in plan["sources"]: packagePaths.add path.getStr
    packagePaths.add plan["entry"].getStr
    let currentPackages = packageSnapshot(packagePaths)
    for path, identity in currentPackages:
      if plan["packages"]{path} != identity: return
    var loads = newJObject()
    var cookies = newJObject()
    var members = initHashSet[string]()
    for member in plan["members"]: members.incl member["suffix"].getStr
    for dep in dependencies:
      loads[dep["suffix"].getStr] = dep["hashes"][ord(bakSemantic)]
      cookies[dep["suffix"].getStr] = dep["hashes"][ord(bakInterface)]
    for load in conf.icReuseLoads:
      if loads{load.suffix}.getStr != load.hash: return
    for read in conf.icDepTraceIfaceReads:
      if read.suffix notin members and
          (not read.present or cookies{read.suffix}.getStr != fingerprintBytes(read.cookie)):
        return
    # All names queried anywhere in the process are gated against the *initial*
    # define state. This includes compiler-internal isDefined callers. Setup's
    # deterministic additions (e.g. nimcheck) do not confuse driver/child state.
    let queries = observedDefines(conf, attempt)
    let store = plan["store"].getStr / plan["key"].getStr
    createDir(store)
    directory = createTempDir("variant-", "", store)
    var artifacts = newJObject()
    for member in plan["members"]:
      let suffix = member["suffix"].getStr
      for kind in BundleArtifactKind:
        let name = suffix & artifactExtension(kind)
        let bytes = readFile(semanticFile(conf, suffix, artifactExtension(kind)).string)
        writeFile(directory / name, bytes)
        artifacts[name] = %fingerprintBytes(bytes)
    let manifest = %*{"version": 1, "complete": true,
      "contract": "cached-contexts-no-host-calls-v2", "plan": plan, "sources": sources,
      "dependencies": dependencies, "contexts": dependencyFiles(conf, plan, directOnly = true),
      "queries": queries, "artifacts": artifacts}
    let bytes = $manifest & "\n"
    writeFile(directory / "manifest.json", bytes)
    # Publish last. Readers ignore directories without a valid READY digest.
    writeFile(directory / "READY.tmp", fingerprintBytes(bytes) & "\n")
    moveFile(directory / "READY.tmp", directory / "READY")
    published = true
  except CatchableError:
    discard # Optional caching must never turn a successful compilation into failure.
  finally:
    if not published and directory.len > 0:
      try: removeDir(directory)
      except OSError: discard
