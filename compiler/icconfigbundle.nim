# Experimental bundle checks, deliberately not connected to cache selection.
# Completeness and identity records are caller assertions; the compiler does not
# yet produce trusted snapshots or immutable bundles for cross-config reuse.
import std/[json, os, sets, tables]
import ../dist/checksums/src/checksums/sha2
import options, icconfigmanifest, icconfigdeps

type
  BundleIdentity* = object
    compilerHash*: string    # SHA-256 of compiler and format identity, supplied by caller
    baseConfigHash*: string  # SHA-256 of the independently classified base configuration
    project*: string
    members*: seq[string]    # resolved source paths, including every cycle member

  BundleFile* = object
    path*: string
    hash*: string            # lowercase SHA-256 of the file bytes

  BundleArtifactKind* = enum
    bakSemantic, bakInterface, bakImplementation, bakEdges, bakImports

  BundleArtifact* = object
    member*: string
    suffix*: string          # module suffix associated with this group member
    kind*: BundleArtifactKind
    file*: BundleFile

  BundleSnapshot* = object
    version*: int
    complete*: bool
    identity*: BundleIdentity
    sources*: seq[BundleFile] # includes each member and all resolved includes
    artifacts*: seq[BundleArtifact]
    observations*: JsonNode
    dependencies*: seq[DependencyObservation]
    dependenciesComplete*: bool

  BundleCurrent* = object
    identity*: BundleIdentity
    sources*: seq[string]     # independently discovered current source/include set
    sourcesComplete*: bool
    dependencies*: seq[CurrentDependency]
    dependenciesComplete*: bool

  BundleCheck* = enum
    bcInvalid, bcIncomplete, bcConfig, bcDependencies, bcIdentityChanged,
    bcSourceChanged, bcArtifactChanged, bcMatch

proc fingerprintFile*(path: string): string =
  ## Streams bytes; errors are reported to the caller, never treated as a match.
  let f = open(path, fmRead)
  defer: f.close()
  var state = initSha_256()
  var buffer: array[8192, char]
  while true:
    let size = f.readBuffer(addr buffer[0], buffer.len)
    if size <= 0: break
    state.update(buffer.toOpenArray(0, size - 1))
  result = $state.digest()

proc validHash(hash: string): bool =
  if hash.len != 64: return false
  for c in hash:
    if c notin {'0'..'9', 'a'..'f'}: return false
  result = true

proc validPath(path: string): bool =
  path.len > 0 and path.isAbsolute

proc artifactExtension*(kind: BundleArtifactKind): string =
  case kind
  of bakSemantic: ".s.bif"
  of bakInterface: ".iface.bif"
  of bakImplementation: ".impl.bif"
  of bakEdges: ".edges.bif"
  of bakImports: ".s.deps.bif"

proc checkBundle*(conf: ConfigRef; candidate: BundleSnapshot;
                  current: BundleCurrent): BundleCheck =
  ## Checks only supplied evidence. A match is NOT authorization to reuse:
  ## producers, complete graph discovery and immutable publication/reads are
  ## not established. In particular, files may change after hashing.
  if candidate.version != 1: return bcInvalid
  if not candidate.complete or not current.sourcesComplete or
      not candidate.dependenciesComplete or not current.dependenciesComplete:
    return bcIncomplete
  if checkConfigObservations(conf, candidate.observations) != cocMatch:
    return bcConfig
  if checkDependencies(candidate.dependencies, current.dependencies,
                       candidate.dependenciesComplete, current.dependenciesComplete) != dcMatch:
    return bcDependencies
  let old = candidate.identity
  let now = current.identity
  if not validHash(old.compilerHash) or not validHash(old.baseConfigHash) or
      not validHash(now.compilerHash) or not validHash(now.baseConfigHash) or
      not validPath(old.project) or not validPath(now.project) or
      old.members.len == 0 or now.members.len == 0:
    return bcInvalid
  if old.compilerHash != now.compilerHash or old.baseConfigHash != now.baseConfigHash or
      old.project != now.project:
    return bcIdentityChanged
  var members = initHashSet[string]()
  for member in old.members:
    if not validPath(member) or members.containsOrIncl(member): return bcInvalid
  var currentMembers = initHashSet[string]()
  for member in now.members:
    if not validPath(member) or currentMembers.containsOrIncl(member): return bcInvalid
  if members != currentMembers: return bcIdentityChanged
  # Config observations are process-wide. They must belong to this exact
  # compilation group, including all members of an SCC.
  let observedProject = candidate.observations["project"].getStr
  if observedProject notin members: return bcInvalid
  var observedMembers = initHashSet[string]()
  for member in candidate.observations["group"]:
    if observedMembers.containsOrIncl(member.getStr): return bcInvalid
  if observedMembers.len == 0:
    if members.len != 1: return bcInvalid
  elif observedMembers != members:
    return bcInvalid
  var sources = initHashSet[string]()
  for source in candidate.sources:
    if not validPath(source.path) or not validHash(source.hash) or
        sources.containsOrIncl(source.path): return bcInvalid
  for member in members:
    if member notin sources: return bcInvalid
  var currentSources = initHashSet[string]()
  for path in current.sources:
    if not validPath(path) or currentSources.containsOrIncl(path): return bcInvalid
  if sources != currentSources: return bcSourceChanged
  try:
    for source in candidate.sources:
      if fingerprintFile(source.path) != source.hash: return bcSourceChanged
  except IOError, OSError:
    return bcSourceChanged
  var roles = initHashSet[(string, BundleArtifactKind)]()
  var artifactPaths = initHashSet[string]()
  var suffixByMember = initTable[string, string]()
  var memberBySuffix = initTable[string, string]()
  for artifact in candidate.artifacts:
    if artifact.member notin members or not validPath(artifact.file.path) or
        artifact.suffix.len == 0 or '/' in artifact.suffix or '\\' in artifact.suffix or
        artifact.file.path.extractFilename != artifact.suffix & artifact.kind.artifactExtension or
        not validHash(artifact.file.hash) or artifact.file.path in sources or
        roles.containsOrIncl((artifact.member, artifact.kind)) or
        artifactPaths.containsOrIncl(artifact.file.path):
      return bcInvalid
    if (suffixByMember.hasKey(artifact.member) and
        suffixByMember[artifact.member] != artifact.suffix) or
        (memberBySuffix.hasKey(artifact.suffix) and
         memberBySuffix[artifact.suffix] != artifact.member):
      return bcInvalid
    suffixByMember[artifact.member] = artifact.suffix
    memberBySuffix[artifact.suffix] = artifact.member
  for member in members:
    for kind in BundleArtifactKind:
      if (member, kind) notin roles: return bcInvalid
  try:
    for artifact in candidate.artifacts:
      if fingerprintFile(artifact.file.path) != artifact.file.hash: return bcArtifactChanged
  except IOError, OSError:
    return bcArtifactChanged
  result = bcMatch
