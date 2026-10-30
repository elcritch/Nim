# Validation of diagnostic config observations. This does not validate source,
# dependencies, compiler identity, or artifact bundles, and must not by itself
# be used to choose a cached artifact.
import std/[json, strtabs, strutils]
import options

type ConfigObservationCheck* = enum
  cocInvalid, cocIncomplete, cocUntracked, cocChanged, cocMatch

proc checkConfigObservations*(conf: ConfigRef; manifest: JsonNode): ConfigObservationCheck =
  ## Compare supported observations with the current resolved configuration.
  ## All manifests currently emitted by the trace are incomplete and are
  ## rejected. This routine is intentionally not wired into cache selection.
  try:
    if manifest.kind != JObject or manifest["version"].kind != JInt or
        manifest["version"].getInt != 1 or manifest["complete"].kind != JBool or
        manifest["scope"].kind != JString or manifest["scope"].getStr != "process" or
        manifest["project"].kind != JString or manifest["group"].kind != JArray or
        manifest["observations"].kind != JArray:
      return cocInvalid
    if not manifest["complete"].getBool: return cocIncomplete
    for member in manifest["group"]:
      if member.kind != JString: return cocInvalid
    for event in manifest["observations"]:
      if event.kind != JObject: return cocInvalid
      for field in ["kind", "context", "source", "line", "key", "value"]:
        if not event.hasKey(field) or event[field].kind != JString: return cocInvalid
      let kind = event["kind"].getStr
      let name = event["key"].getStr
      let value = event["value"].getStr
      if name.len == 0: return cocInvalid
      case kind
      of "untracked": return cocUntracked
      of "defined":
        if value notin ["0", "1"]: return cocInvalid
        if (value == "1") != isDefined(conf, name): return cocChanged
      of "value":
        let parts = value.split('\t')
        if parts.len != 3 or parts[0] notin ["mIntDefine", "mStrDefine",
                                            "mBoolDefine", "mGenericDefine"] or
            parts[1] notin ["true", "false"]: return cocInvalid
        let present = isDefined(conf, name)
        if present != (parts[1] == "true"): return cocChanged
        if present:
          # A target alias may be defined without a symbol-table value. Do not
          # manufacture one or claim that this observation is validated.
          if not conf.symbols.hasKey(name): return cocInvalid
          if conf.symbols[name].escape != parts[2]: return cocChanged
        elif parts[2].len != 0:
          return cocInvalid
      else: return cocInvalid
    result = cocMatch
  except CatchableError:
    result = cocInvalid

proc checkConfigObservationsFile*(conf: ConfigRef; path: string): ConfigObservationCheck =
  try:
    result = checkConfigObservations(conf, parseFile(path))
  except CatchableError:
    result = cocInvalid
