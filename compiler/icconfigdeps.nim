# Experimental checks for the two observations needed by a future cache gate.
# A match is not authorization to reuse: source, base configuration, compiler
# identity, artifact integrity, group membership and other inputs remain to be
# validated separately. Nothing in this module selects or copies cache files.
import std/[json, tables]
import options, icconfigmanifest

type
  DependencyObservation* = object
    # Stable resolved identity, including direct imports and transitive
    # implementation dependencies. Cookies are the actual sidecar bytes.
    identity*: string
    ifaceCookie*: string
    needsImpl*: bool
    implCookie*: string

  CurrentDependency* = object
    observation*: DependencyObservation
    # Set only after independently validating this dependency for the current
    # build, including its own transitive dependencies.
    validated*: bool

  DependencyCheck* = enum
    dcInvalid, dcIncomplete, dcUnvalidated, dcChanged, dcMatch

  ConfigDependencyCheck* = object
    config*: ConfigObservationCheck
    dependencies*: DependencyCheck

proc checkDependencies*(recorded: openArray[DependencyObservation];
                        current: openArray[CurrentDependency];
                        recordedComplete, currentComplete: bool): DependencyCheck =
  ## Compare exact dependency identities, edge kinds and cookie bytes. The
  ## caller must construct both complete sets independently: a previous
  ## import list alone is not proof of the graph for the current build.
  if not recordedComplete or not currentComplete: return dcIncomplete
  var old = initTable[string, DependencyObservation]()
  for dep in recorded:
    if dep.identity.len == 0 or dep.ifaceCookie.len == 0 or
        (dep.needsImpl and dep.implCookie.len == 0) or
        (not dep.needsImpl and dep.implCookie.len != 0) or
        old.hasKey(dep.identity):
      return dcInvalid
    old[dep.identity] = dep
  var seen = initTable[string, bool]()
  for dep in current:
    let obs = dep.observation
    if obs.identity.len == 0 or obs.ifaceCookie.len == 0 or
        (obs.needsImpl and obs.implCookie.len == 0) or
        (not obs.needsImpl and obs.implCookie.len != 0) or
        seen.hasKey(obs.identity):
      return dcInvalid
    seen[obs.identity] = true
    if not dep.validated: return dcUnvalidated
    if not old.hasKey(obs.identity) or old[obs.identity] != obs:
      return dcChanged
  if old.len != seen.len: return dcChanged
  result = dcMatch

proc checkConfigAndDependencies*(conf: ConfigRef; manifest: JsonNode;
    recorded: openArray[DependencyObservation];
    current: openArray[CurrentDependency];
    recordedComplete, currentComplete: bool): ConfigDependencyCheck =
  ## Both fields must match, but even a double match checks only these two
  ## aspects of reuse. Production trace manifests are always incomplete.
  result.config = checkConfigObservations(conf, manifest)
  result.dependencies = checkDependencies(recorded, current,
                                           recordedComplete, currentComplete)
