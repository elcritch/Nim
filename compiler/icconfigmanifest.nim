# Validation of diagnostic config observations. This does not validate source,
# dependencies, compiler identity, or artifact bundles, and must not by itself
# be used to choose a cached artifact.
import std/[algorithm, json, sets, strtabs, strutils]
import options

const ConfigCoverageAreas* = ["semanticReads", "compilerReads", "discoveryReads",
                             "defineMutation", "compileTimeInputs", "attribution"]

type ConfigObservationCheck* = enum
  cocInvalid, cocIncomplete, cocUntracked, cocChanged, cocMatch

proc incompleteConfigCoverage*(): JsonNode =
  ## No production compilation has established completeness for any area.
  result = newJObject()
  for area in ConfigCoverageAreas: result[area] = %"unknown"

proc configIneligibilityReasons*(coverage, observations: JsonNode): JsonNode =
  ## Called only after validating the shape, or on compiler-constructed nodes.
  var reasons = initHashSet[string]()
  for area in ConfigCoverageAreas:
    if coverage[area].getStr == "unknown": reasons.incl "coverage:" & area
  for event in observations:
    if event["kind"].getStr == "untracked":
      reasons.incl "untracked:" & event["key"].getStr
  var ordered: seq[string] = @[]
  for reason in reasons: ordered.add reason
  ordered.sort()
  result = newJArray()
  for reason in ordered: result.add %reason

proc checkConfigObservations*(conf: ConfigRef; manifest: JsonNode): ConfigObservationCheck =
  ## Compare supported observations with the current resolved configuration.
  ## All manifests currently emitted by the trace are incomplete and are
  ## rejected. This routine is intentionally not wired into cache selection.
  try:
    if manifest.kind != JObject or manifest["version"].kind != JInt or
        manifest["complete"].kind != JBool or
        manifest["scope"].kind != JString or manifest["scope"].getStr != "process" or
        manifest["project"].kind != JString or manifest["group"].kind != JArray or
        manifest["observations"].kind != JArray:
      return cocInvalid
    # Older traces never asserted coverage; do not accept a forged v1 complete
    # flag as a replacement for the versioned coverage contract.
    if manifest["version"].getInt == 1:
      return if manifest["complete"].getBool: cocInvalid else: cocIncomplete
    if manifest["version"].getInt != 2 or manifest["coverage"].kind != JObject or
        manifest["coverage"].len != ConfigCoverageAreas.len or
        manifest["ineligibleReasons"].kind != JArray:
      return cocInvalid
    var incomplete = not manifest["complete"].getBool
    for area in ConfigCoverageAreas:
      if not manifest["coverage"].hasKey(area) or
          manifest["coverage"][area].kind != JString or
          manifest["coverage"][area].getStr notin ["complete", "unknown"]:
        return cocInvalid
      if manifest["coverage"][area].getStr == "unknown": incomplete = true
    for member in manifest["group"]:
      if member.kind != JString: return cocInvalid
    var untracked = false
    var changed = false
    for event in manifest["observations"]:
      if event.kind != JObject: return cocInvalid
      for field in ["kind", "context", "source", "line", "key", "value"]:
        if not event.hasKey(field) or event[field].kind != JString: return cocInvalid
      let kind = event["kind"].getStr
      let name = event["key"].getStr
      let value = event["value"].getStr
      if name.len == 0: return cocInvalid
      case kind
      of "untracked": untracked = true
      of "defined":
        if value notin ["0", "1"]: return cocInvalid
        if (value == "1") != isDefined(conf, name): changed = true
      of "value":
        let parts = value.split('\t')
        if parts.len != 3 or parts[0] notin ["mIntDefine", "mStrDefine",
                                            "mBoolDefine", "mGenericDefine"] or
            parts[1] notin ["true", "false"]: return cocInvalid
        let present = isDefined(conf, name)
        if present != (parts[1] == "true"): changed = true
        if parts[1] == "true" and present:
          # A target alias may be defined without a symbol-table value. Do not
          # manufacture one or claim that this observation is validated.
          if not conf.symbols.hasKey(name): return cocInvalid
          if conf.symbols[name].escape != parts[2]: changed = true
        elif parts[1] == "false" and parts[2].len != 0:
          return cocInvalid
      else: return cocInvalid
    if manifest["ineligibleReasons"] !=
        configIneligibilityReasons(manifest["coverage"], manifest["observations"]):
      return cocInvalid
    if incomplete: return cocIncomplete
    if untracked: return cocUntracked
    if changed: return cocChanged
    result = cocMatch
  except CatchableError:
    result = cocInvalid

proc checkConfigObservationsFile*(conf: ConfigRef; path: string): ConfigObservationCheck =
  try:
    result = checkConfigObservations(conf, parseFile(path))
  except CatchableError:
    result = cocInvalid
