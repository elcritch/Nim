discard """
  matrix: "-d:nimIcConfigReuse"
  disabled: windows
  outputsub: "restricted bundle reuse passed"
  joinable: false
"""

import std/[json, os, strtabs, strutils, tempfiles]
import compiler/icbif
import ../../dist/nimony/src/lib/bif as rawbif
import ../../dist/nimony/src/lib/nifcore except symName, strVal, poolSym, poolStr, lineInfoFile
import compiler/[icconfigreuse, icconfigbundle, icfilehashes, options, pathutils]

for flag in ["-d:unrelated", "--define:probe_value=hello world", "-u:probeValue"]:
  doAssert ordinaryDefineArg(flag)
for flag in ["-d:release", "--define:d_a_n_g_e_r=true", "--undef:nimQuirky",
             "-d:QUICK", "--checks:off", "--define:", "file.nim"]:
  doAssert not ordinaryDefineArg(flag)

let dir = createTempDir("nim_restricted_reuse_", "")
try:
  when defined(posix):
    let realCache = dir / "cache"
    let aliasCache = dir / "alias"
    createDir(realCache)
    createSymlink(realCache, aliasCache)
    let firstLock = lockReuseCache(realCache)
    let lockId = getFileInfo(firstLock).id
    firstLock.close()
    let aliasLock = lockReuseCache(aliasCache)
    doAssert getFileInfo(aliasLock).id == lockId
    aliasLock.close()
  let digests = dir / "digests"
  let hashInput = dir / "input.bin"
  writeFile(hashInput, "first")
  let firstStamp = fileStamp(hashInput)
  let firstTime = getLastModificationTime(hashInput)
  doAssert fingerprintFileCached(hashInput, digests) == fingerprintBytes("first")
  doAssert readCachedDigest(digests, hashInput, firstStamp) == fingerprintBytes("first")
  writeFile(hashInput, "other")
  setLastModificationTime(hashInput, firstTime)
  doAssert fileStamp(hashInput) != firstStamp
  doAssert fingerprintFileCached(hashInput, digests) == fingerprintBytes("other")
  for kind, path in walkDir(digests):
    if kind == pcFile: writeFile(path, "corrupt")
  doAssert readCachedDigest(digests, hashInput, fileStamp(hashInput)) == ""
  doAssert fingerprintFileCached(hashInput, digests) == fingerprintBytes("other")
  # Digest evidence describes the mapping consumed; atomic replacement keeps
  # the old decoder buffer alive and gives a new file identity to later loads.
  let bifPath = dir / "mapped.s.bif"
  var tags = newTagPool()
  var builder = createTokenBuf(16, newPool(), tags)
  builder.openTag tags.registerTag("stmts")
  builder.addIntLit 42
  builder.closeTag()
  rawbif.store(builder, bifPath, ".mapped")
  var hash = ""
  var mapped = icbif.load(bifPath, addr hash, digests)
  doAssert hash == fingerprintFile(bifPath)
  var cursor = mapped.buf.beginRead()
  inc cursor
  doAssert cursor.intVal == 42
  var changedBuilder = createTokenBuf(16, newPool(), tags)
  changedBuilder.openTag tags.registerTag("stmts")
  changedBuilder.addIntLit 43
  changedBuilder.closeTag()
  rawbif.store(changedBuilder, bifPath, ".mapped")
  doAssert cursor.intVal == 42
  var changedMapping = icbif.load(bifPath, addr hash, digests)
  doAssert hash == fingerprintFile(bifPath)
  cursor = changedMapping.buf.beginRead()
  inc cursor
  doAssert cursor.intVal == 43
  let source = dir / "source.nim"
  writeFile(source, "const value = 1\n")
  let conf = newConfigRef()
  conf.cmd = cmdM
  conf.projectFull = AbsoluteFile(source)
  conf.icProject = source
  conf.icSemDir = AbsoluteDir(dir / "sem")
  createDir(conf.icSemDir.string)
  let suffix = "source1"
  let plan = %*{"store": dir / "store", "digests": dir / "digests", "key": repeat('a', 64),
    "compiler": fingerprintFile(getAppFilename()) & ":" & icFormatVersion,
    "compilerStamp": compilerFileStamp(getAppFilename()), "base": repeat('b', 64),
    "project": source, "entry": source,
    "members": [{"source": source, "suffix": suffix}], "sources": [source],
    "dependencies": newJArray(), "packages": packageSnapshot([source])}
  conf.icReusePlan = dir / "plan.json"
  writeFile(conf.icReusePlan, $plan)
  conf.icReuseSources.add (source, fingerprintFile(source))
  conf.icConfigTraceEvents.add ("defined", source, source, "1", "probeFlag", "0")
  for kind in BundleArtifactKind:
    writeFile(semanticFile(conf, suffix, artifactExtension(kind)).string, $kind)
  let attempt = beginReuse(conf)
  doAssert not restoreReuse(conf, attempt)
  publishReuse(conf, attempt)
  var bundle = ""
  for kind, path in walkDir(plan["store"].getStr / plan["key"].getStr):
    if kind == pcDir and fileExists(path / "READY"): bundle = path
  doAssert bundle.len > 0
  for kind in BundleArtifactKind:
    removeFile(semanticFile(conf, suffix, artifactExtension(kind)).string)
  let observations = conf.icConfigTraceEvents
  conf.icConfigTraceEvents = @[]
  doAssert restoreReuse(conf, attempt)
  writeReuseInputs(conf, attempt)
  let savedContext = parseFile(semanticFile(conf, suffix, ".reuse-inputs.json").string)
  doAssert savedContext["queries"].hasKey("probeflag")
  doAssert savedContext["queries"]["probeflag"].kind == JNull
  conf.icConfigTraceEvents = observations
  let packageFile = dir / "new_package.nimble"
  writeFile(packageFile, "")
  doAssert not restoreReuse(conf, beginReuse(conf))
  removeFile(packageFile)
  conf.projectIsStdin = true
  doAssert not restoreReuse(conf, beginReuse(conf))
  conf.projectIsStdin = false
  conf.projectIsCmd = true
  doAssert not restoreReuse(conf, beginReuse(conf))
  conf.projectIsCmd = false
  for kind in BundleArtifactKind:
    doAssert readFile(semanticFile(conf, suffix, artifactExtension(kind)).string) == $kind
  conf.symbols["unused"] = "true"
  let unused = beginReuse(conf)
  doAssert restoreReuse(conf, unused)
  conf.symbols["probe_flag"] = "true"
  let changed = beginReuse(conf)
  doAssert not restoreReuse(conf, changed)
  conf.symbols.del("probe_flag")
  writeFile(source, "const value = 2\n")
  let edited = beginReuse(conf)
  doAssert not restoreReuse(conf, edited)
  writeFile(source, "const value = 1\n")
  let artifact = bundle / (suffix & artifactExtension(bakSemantic))
  let original = readFile(artifact)
  writeFile(artifact, "corrupt")
  doAssert not restoreReuse(conf, attempt)
  # No partial install: even valid sidecars remain untouched on a miss.
  for kind in BundleArtifactKind:
    doAssert readFile(semanticFile(conf, suffix, artifactExtension(kind)).string) == $kind
  writeFile(artifact, original)
  let manifestPath = bundle / "manifest.json"
  let bytes = readFile(manifestPath)
  for field in ["version", "complete", "contract", "plan", "sources", "dependencies", "contexts", "queries", "artifacts"]:
    var malformed = parseJson(bytes)
    malformed.delete(field)
    let raw = $malformed & "\n"
    writeFile(manifestPath, raw)
    writeFile(bundle / "READY", fingerprintBytes(raw) & "\n")
    doAssert not restoreReuse(conf, attempt), field
  for (field, value) in [("version", %99), ("complete", %false), ("contract", %"unknown")]:
    var invalid = parseJson(bytes)
    invalid[field] = value
    let raw = $invalid & "\n"
    writeFile(manifestPath, raw)
    writeFile(bundle / "READY", fingerprintBytes(raw) & "\n")
    doAssert not restoreReuse(conf, attempt)
  writeFile(manifestPath, bytes)
  writeFile(bundle / "READY", fingerprintBytes(bytes) & "\n")
  doAssert restoreReuse(conf, attempt)
  removeFile(bundle / "READY")
  doAssert not restoreReuse(conf, attempt)
  # Unsupported effects and incomplete consumption evidence cannot publish.
  conf.icReuseUnsupportedVm = true
  publishReuse(conf, attempt)
  conf.icReuseUnsupportedVm = false
  conf.icConfigTraceEvents.add ("untracked", source, source, "1", "compiles", "")
  publishReuse(conf, attempt)
  conf.icConfigTraceEvents.setLen(1)
  conf.icReuseSources[0].hash = repeat('c', 64)
  publishReuse(conf, attempt)
  var ready = 0
  for kind, path in walkDir(plan["store"].getStr / plan["key"].getStr):
    if kind == pcDir and fileExists(path / "READY"): inc ready
  doAssert ready == 0
  for malformed in [newJNull(), %*[42], %*{"key": "../escape"}]:
    writeFile(conf.icReusePlan, $malformed)
    let invalid = beginReuse(conf)
    doAssert not restoreReuse(conf, invalid)
  # Dependencies with unknown external inputs invalidate consumers even when
  # every semantic artifact byte remains unchanged.
  var withDep = parseJson($plan)
  withDep["key"] = %repeat('d', 64)
  let depSource = dir / "dependency.nim"
  let depSuffix = "dependency1"
  writeFile(depSource, "const value = 2\n")
  withDep["dependencies"].add %*{"source": depSource, "suffix": depSuffix}
  withDep["packages"] = packageSnapshot([source, depSource])
  writeFile(conf.icReusePlan, $withDep)
  conf.icReuseSources[0].hash = fingerprintFile(source)
  for kind in BundleArtifactKind:
    writeFile(semanticFile(conf, depSuffix, artifactExtension(kind)).string, "dependency " & $kind)
  conf.icReuseLoads.add (depSuffix, fingerprintFile(semanticFile(conf, depSuffix, ".s.bif").string))
  conf.icDepTraceIfaceReads.add (suffix, depSuffix,
    readFile(semanticFile(conf, depSuffix, ".iface.bif").string), true)
  let depAttempt = beginReuse(conf)
  publishReuse(conf, depAttempt) # absent status cannot authorize publication
  doAssert not restoreReuse(conf, depAttempt)
  let statusPath = semanticFile(conf, depSuffix, ".reuse-inputs.json").string
  let artifacts = artifactContext(conf, depSuffix, withDep["digests"].getStr)
  var hashes = newJArray()
  for artifact in artifacts: hashes.add artifact["hash"]
  var status = %*{"version": 2, "complete": true, "source": depSource,
    "compiler": withDep["compiler"], "externalInputs": false,
    "artifacts": artifacts, "dependencies": newJArray(),
    "context": fingerprintBytes($( %*{"hashes": hashes, "dependencies": newJArray()}))}
  writeFile(statusPath, $status)
  publishReuse(conf, depAttempt)
  doAssert restoreReuse(conf, depAttempt)
  # A transitive input changes the direct producer's context even when its
  # own BIF bytes are identical; the consumer must select another variant.
  let originalStatus = $status
  status["dependencies"].add %*{"context": repeat('e', 64)}
  status["context"] = %fingerprintBytes($( %*{"hashes": hashes,
    "dependencies": status["dependencies"]}))
  writeFile(statusPath, $status)
  doAssert not restoreReuse(conf, depAttempt)
  status = parseJson(originalStatus)
  writeFile(statusPath, $status)
  doAssert restoreReuse(conf, depAttempt)
  let depBif = semanticFile(conf, depSuffix, ".s.bif").string
  let savedBif = readFile(depBif)
  writeFile(depBif, "replaced dependency")
  doAssert not restoreReuse(conf, depAttempt)
  writeFile(depBif, savedBif)
  status["artifacts"] = artifactContext(conf, depSuffix, withDep["digests"].getStr)
  status["externalInputs"] = %true
  writeFile(statusPath, $status)
  doAssert not restoreReuse(conf, depAttempt)
  status["externalInputs"] = %false
  writeFile(statusPath, $status)
  doAssert restoreReuse(conf, depAttempt)
  removeFile(statusPath)
  doAssert not restoreReuse(conf, depAttempt)
  conf.icReuseExternalInputs = true
  writeReuseInputs(conf, depAttempt)
  doAssert parseFile(semanticFile(conf, suffix, ".reuse-inputs.json").string)["externalInputs"].getBool
  resetReuseInputs(conf, depAttempt)
  doAssert not fileExists(semanticFile(conf, suffix, ".reuse-inputs.json").string)
  echo "restricted bundle reuse passed"
finally:
  removeDir(dir)
