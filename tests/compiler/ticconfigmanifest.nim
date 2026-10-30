discard """
  output: "config observation validation passed"
"""

import std/[json, strtabs, strutils]
import compiler/[icconfigdeps, icconfigmanifest, options, platform]

proc event(kind, key, value: string): JsonNode =
  %*{"kind": kind, "context": "/m.nim", "source": "/m.nim",
     "line": "1", "key": key, "value": value}

proc manifest(events: seq[JsonNode]; complete = true): JsonNode =
  var coverage = newJObject()
  for area in ConfigCoverageAreas: coverage[area] = %"complete"
  let observations = %events
  %*{"version": 2, "complete": complete, "scope": "process",
     "project": "/m.nim", "group": newJArray(), "observations": observations,
     "coverage": coverage, "ineligibleReasons": configIneligibilityReasons(coverage, observations)}

let conf = newConfigRef()
doAssert checkConfigObservations(conf, nil) == cocInvalid
setTarget(conf.target, osLinux, cpuAmd64)
conf.symbols["probeFlag"] = "true"
conf.symbols["probeValue"] = "hello world"
conf.symbols["probeInt"] = "17"
conf.symbols["probeBool"] = "false"
let observations = @[
  event("defined", "probe_flag", "1"),
  event("defined", "missingProbe", "0"),
  event("defined", "linux", "1"),
  event("value", "probe_value", "mStrDefine\ttrue\t" & "hello world".escape),
  event("value", "probeInt", "mIntDefine\ttrue\t" & "17".escape),
  event("value", "probeBool", "mBoolDefine\ttrue\t" & "false".escape),
  event("value", "missingValue", "mIntDefine\tfalse\t")]
let document = manifest(observations)
doAssert checkConfigObservations(conf, document) == cocMatch
conf.symbols["unrelated"] = "true"
doAssert checkConfigObservations(conf, document) == cocMatch
conf.symbols["probeValue"] = "changed"
doAssert checkConfigObservations(conf, document) == cocChanged
conf.symbols["probeValue"] = "hello world"
conf.symbols["probeBool"] = "true"
doAssert checkConfigObservations(conf, document) == cocChanged
conf.symbols["probeBool"] = "false"
conf.symbols["missingProbe"] = "true"
doAssert checkConfigObservations(conf, document) == cocChanged
conf.symbols.del("missingProbe")
conf.symbols["missingValue"] = "42"
doAssert checkConfigObservations(conf, document) == cocChanged
conf.symbols.del("missingValue")
doAssert checkConfigObservations(conf, manifest(observations, false)) == cocIncomplete
doAssert checkConfigObservations(conf, manifest(@[event("untracked", "staticExec", "")])) == cocUntracked
doAssert checkConfigObservations(conf, manifest(@[event("defined", "probeFlag", "maybe")])) == cocInvalid
doAssert checkConfigObservations(conf, manifest(@[event("value", "linux", "mIntDefine\ttrue\t\"1\"")])) == cocInvalid
doAssert checkConfigObservations(conf, manifest(@[event("value", "missingValue", "mIntDefine\tfalse\tunexpected")])) == cocInvalid
doAssert checkConfigObservations(conf, %*{"version": 99}) == cocInvalid
doAssert checkConfigObservationsFile(conf, "/does-not-exist/ic-config-manifest") == cocInvalid
for area in ConfigCoverageAreas:
  var unknown = manifest(observations)
  unknown["coverage"][area] = %"unknown"
  unknown["ineligibleReasons"] = configIneligibilityReasons(unknown["coverage"], unknown["observations"])
  doAssert checkConfigObservations(conf, unknown) == cocIncomplete
  unknown["ineligibleReasons"] = newJArray()
  doAssert checkConfigObservations(conf, unknown) == cocInvalid
var missingCoverage = manifest(observations)
missingCoverage["coverage"].delete("compilerReads")
doAssert checkConfigObservations(conf, missingCoverage) == cocInvalid
var legacy = manifest(observations)
legacy["version"] = %1
doAssert checkConfigObservations(conf, legacy) == cocInvalid
legacy["complete"] = %false
doAssert checkConfigObservations(conf, legacy) == cocIncomplete

# A consumer's unchanged semantic BIF is insufficient: its imported module's
# interface cookie may change, or it may have consumed a dependency body.
let ifaceDep = DependencyObservation(identity: "/figdraw/fignodes.nim",
                                     ifaceCookie: "interface-4")
let implDep = DependencyObservation(identity: "/figdraw/macro-helper.nim",
                                    ifaceCookie: "interface", needsImpl: true,
                                    implCookie: "implementation-1")
let recorded = @[ifaceDep, implDep]
var current = @[CurrentDependency(observation: ifaceDep, validated: true),
                CurrentDependency(observation: implDep, validated: true)]
let complete = manifest(observations)
let match = checkConfigAndDependencies(conf, complete, recorded, current, true, true)
doAssert match.config == cocMatch and match.dependencies == dcMatch
current[0].observation.ifaceCookie = "interface-5"
doAssert checkDependencies(recorded, current, true, true) == dcChanged
current[0].observation = ifaceDep
current[1].observation.implCookie = "implementation-2"
doAssert checkDependencies(recorded, current, true, true) == dcChanged
current[1].observation = implDep
current[1].validated = false
doAssert checkDependencies(recorded, current, true, true) == dcUnvalidated
current[1].validated = true
doAssert checkDependencies(recorded, current, false, true) == dcIncomplete
doAssert checkDependencies(recorded, current, true, false) == dcIncomplete
doAssert checkDependencies(recorded, current[0..0], true, true) == dcChanged
var changedGraph = current
changedGraph[0].observation.identity = "/figdraw/other-backend.nim"
doAssert checkDependencies(recorded, changedGraph, true, true) == dcChanged
var changedEdge = current
changedEdge[1].observation.needsImpl = false
changedEdge[1].observation.implCookie = ""
doAssert checkDependencies(recorded, changedEdge, true, true) == dcChanged
doAssert checkDependencies(recorded, current & current[0..0], true, true) == dcInvalid
doAssert checkDependencies(recorded & recorded[0..0], current, true, true) == dcInvalid
var missingCookie = current
missingCookie[1].observation.implCookie = ""
doAssert checkDependencies(recorded, missingCookie, true, true) == dcInvalid

# A dependency can retain identical BIFs and sidecars while a consumer's own
# define observation changes its imports (the FigDraw text-backend case).
let backend = manifest(@[event("value", "figdrawTextBackend", "mStrDefine\tfalse\t")])
doAssert checkConfigAndDependencies(conf, backend, recorded, current, true, true).config == cocMatch
conf.symbols["figdrawTextBackend"] = "harfbuzzy"
let changedBackend = checkConfigAndDependencies(conf, backend, recorded, current, true, true)
doAssert changedBackend.config == cocChanged and changedBackend.dependencies == dcMatch
conf.symbols.del("figdrawTextBackend")
let incomplete = checkConfigAndDependencies(conf, manifest(observations, false), recorded, current, true, true)
doAssert incomplete.config == cocIncomplete
echo "config observation validation passed"
