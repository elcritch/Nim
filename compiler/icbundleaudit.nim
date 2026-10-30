# Opt-in diagnostic bundle publication. Published data is never selected for
# compilation: observations and dependency snapshots are still incomplete.
import std/[json, os, sets, tables, tempfiles]
import icconfigbundle

when defined(nimPreviewSlimSystem):
  import std/syncio

type
  AuditMember* = object
    source*: string
    suffix*: string
    artifacts*: array[BundleArtifactKind, string]

proc readDiagnostic(path: string): JsonNode =
  try:
    result = parseFile(path)
  except CatchableError:
    result = newJNull()

proc isDigest(value: string): bool =
  if value.len != 64: return false
  for c in value:
    if c notin {'0'..'9', 'a'..'f'}: return false
  result = true

proc publishAuditBundle*(store, project, compilerHash, fullConfigHash, formatVersion: string;
                         members: openArray[AuditMember]; sources: openArray[string];
                         configTracePath, dependencyTracePath: string): string =
  ## Copies a complete group into a private directory, checks each copy, and
  ## publishes a READY marker only after all files and metadata are in place.
  ## The observations are diagnostic and can never authorize cache reuse.
  createDir(store)
  let dir = createTempDir("bundle-", "", store)
  var published = false
  defer:
    if not published:
      try: removeDir(dir)
      except OSError: discard
  var membersJson = newJArray()
  var sourcesJson = newJArray()
  var artifactsJson = newJArray()
  var memberNames = initHashSet[string]()
  var suffixes = initHashSet[string]()
  for member in members:
    if member.source.len == 0 or member.suffix.len == 0 or
        '/' in member.suffix or '\\' in member.suffix or
        memberNames.containsOrIncl(member.source) or suffixes.containsOrIncl(member.suffix):
      raise newException(ValueError, "invalid bundle member")
    membersJson.add %*{"source": member.source, "suffix": member.suffix}
    for kind in BundleArtifactKind:
      let source = member.artifacts[kind]
      let name = member.suffix & artifactExtension(kind)
      if source.extractFilename != name:
        raise newException(ValueError, "invalid artifact name")
      let expected = fingerprintFile(source)
      let destination = dir / name
      copyFile(source, destination)
      if fingerprintFile(destination) != expected:
        raise newException(IOError, "artifact changed during copy")
      artifactsJson.add %*{"member": member.source, "suffix": member.suffix,
                            "kind": $kind, "name": name, "sha256": expected}
  if members.len == 0: raise newException(ValueError, "empty bundle")
  var sourceNames = initHashSet[string]()
  for source in sources:
    if not sourceNames.containsOrIncl(source):
      sourcesJson.add %*{"path": source, "sha256": fingerprintFile(source)}
  for member in members:
    if member.source notin sourceNames: raise newException(ValueError, "missing member source")
  let manifest = %*{"version": 1, "complete": false, "project": project,
    "compilerSha256": compilerHash, "fullConfigSha256": fullConfigHash,
    "icFormatVersion": formatVersion, "members": membersJson,
    "sources": sourcesJson, "artifacts": artifactsJson,
    "configTrace": readDiagnostic(configTracePath),
    "dependencyTrace": readDiagnostic(dependencyTracePath),
    "ineligibleReasons": ["unprovenConfigCoverage", "unprovenDependencySnapshot",
                          "unprovenInputSnapshot", "unprovenPublicationIsolation"]}
  let manifestPath = dir / "manifest.json"
  writeFile(manifestPath, $manifest & "\n")
  let readyTemp = dir / "READY.tmp"
  writeFile(readyTemp, fingerprintFile(manifestPath) & "\n")
  moveFile(readyTemp, dir / "READY")
  published = true
  result = dir

proc readAuditBundle*(dir: string): JsonNode =
  ## Return nil for interrupted, malformed or corrupted publications. This
  ## integrity check is diagnostic, not a reuse or concurrency guarantee.
  try:
    let manifestPath = dir / "manifest.json"
    let ready = readFile(dir / "READY")
    if ready != fingerprintFile(manifestPath) & "\n": return nil
    let document = parseFile(manifestPath)
    if document.kind != JObject or document["version"].getInt != 1 or
        document["complete"].kind != JBool or document["complete"].getBool or
        document["project"].kind != JString or not document["project"].getStr.isAbsolute or
        document["compilerSha256"].kind != JString or not isDigest(document["compilerSha256"].getStr) or
        document["fullConfigSha256"].kind != JString or not isDigest(document["fullConfigSha256"].getStr) or
        document["icFormatVersion"].kind != JString or document["icFormatVersion"].getStr.len == 0 or
        document["members"].kind != JArray or document["members"].len == 0 or
        document["sources"].kind != JArray or document["artifacts"].kind != JArray or
        document["ineligibleReasons"].kind != JArray or
        document["configTrace"].kind notin {JNull, JObject} or
        document["dependencyTrace"].kind notin {JNull, JObject}:
      return nil
    var suffixes = initHashSet[string]()
    var members = initHashSet[string]()
    var memberSuffixes = initTable[string, string]()
    for member in document["members"]:
      if member.kind != JObject: return nil
      let source = member["source"].getStr
      let suffix = member["suffix"].getStr
      if not source.isAbsolute or suffix.len == 0 or '/' in suffix or '\\' in suffix or
          members.containsOrIncl(source) or suffixes.containsOrIncl(suffix): return nil
      memberSuffixes[source] = suffix
    var sources = initHashSet[string]()
    for source in document["sources"]:
      if source.kind != JObject: return nil
      let path = source["path"].getStr
      if not path.isAbsolute or not isDigest(source["sha256"].getStr) or
          sources.containsOrIncl(path): return nil
    for member in members:
      if member notin sources: return nil
    var files = initHashSet[string]()
    var roles = initHashSet[(string, string)]()
    for artifact in document["artifacts"]:
      if artifact.kind != JObject: return nil
      let source = artifact["member"].getStr
      let suffix = artifact["suffix"].getStr
      let name = artifact["name"].getStr
      let kind = artifact["kind"].getStr
      if source notin members or memberSuffixes[source] != suffix or name.extractFilename != name or
          files.containsOrIncl(name) or roles.containsOrIncl((source, kind)):
        return nil
      var validKind = false
      for k in BundleArtifactKind:
        if kind == $k and name == suffix & artifactExtension(k): validKind = true
      if not validKind or not isDigest(artifact["sha256"].getStr) or
          fingerprintFile(dir / name) != artifact["sha256"].getStr:
        return nil
    if roles.len != members.len * (ord(high(BundleArtifactKind)) + 1): return nil
    result = document
  except CatchableError:
    result = nil
