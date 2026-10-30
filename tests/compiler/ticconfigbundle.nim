discard """
  output: "bundle validation passed"
"""

import std/[json, os, strutils, tempfiles]
import ../../dist/checksums/src/checksums/sha2
import compiler/[icconfigbundle, icconfigdeps, icconfigmanifest, options]

proc completeManifest(project: string; group: seq[string]): JsonNode =
  var coverage = newJObject()
  for area in ConfigCoverageAreas: coverage[area] = %"complete"
  let observations = newJArray()
  %*{"version": 2, "complete": true, "scope": "process", "project": project,
     "group": group, "coverage": coverage, "observations": observations,
     "ineligibleReasons": configIneligibilityReasons(coverage, observations)}

let dir = createTempDir("nim_ic_bundle_", "")
try:
  let memberA = dir / "a.nim"
  let memberB = dir / "b.nim"
  let included = dir / "shared.nim"
  writeFile(memberA, "import b\n")
  writeFile(memberB, "import a\n")
  writeFile(included, "const value = 1\n")
  let largeFile = dir / "large.bin"
  let largeData = repeat("x\0a", 5000)
  writeFile(largeFile, largeData)
  doAssert fingerprintFile(largeFile) == $Sha_256.secureHash(largeData)
  let identity = BundleIdentity(compilerHash: repeat('a', 64),
    baseConfigHash: repeat('b', 64), project: memberA, members: @[memberA, memberB])
  let dep = DependencyObservation(identity: "/dependency.nim", ifaceCookie: "iface",
                                  needsImpl: true, implCookie: "impl")
  var candidate = BundleSnapshot(version: 1, complete: true, identity: identity,
    observations: completeManifest(memberA, identity.members), dependencies: @[dep], dependenciesComplete: true)
  for path in [memberA, memberB, included]:
    candidate.sources.add BundleFile(path: path, hash: fingerprintFile(path))
  for member in identity.members:
    let suffix = extractFilename(member).changeFileExt("")
    for kind in BundleArtifactKind:
      let path = dir / (suffix & artifactExtension(kind))
      writeFile(path, "artifact " & member & " " & $kind)
      candidate.artifacts.add BundleArtifact(member: member, suffix: suffix, kind: kind,
        file: BundleFile(path: path, hash: fingerprintFile(path)))
  var current = BundleCurrent(identity: identity, sources: @[memberA, memberB, included],
    sourcesComplete: true, dependencies: @[CurrentDependency(observation: dep, validated: true)],
    dependenciesComplete: true)
  let conf = newConfigRef()
  doAssert checkBundle(conf, candidate, current) == bcMatch
  current.identity.members = @[memberB, memberA]
  doAssert checkBundle(conf, candidate, current) == bcMatch
  current.identity = identity
  candidate.complete = false
  doAssert checkBundle(conf, candidate, current) == bcIncomplete
  candidate.complete = true
  candidate.dependenciesComplete = false
  doAssert checkBundle(conf, candidate, current) == bcIncomplete
  candidate.dependenciesComplete = true
  current.sourcesComplete = false
  doAssert checkBundle(conf, candidate, current) == bcIncomplete
  current.sourcesComplete = true
  current.dependencies[0].validated = false
  doAssert checkBundle(conf, candidate, current) == bcDependencies
  current.dependencies[0].validated = true
  current.dependencies[0].observation.implCookie = "changed"
  doAssert checkBundle(conf, candidate, current) == bcDependencies
  current.dependencies[0].observation = dep
  candidate.observations["coverage"]["attribution"] = %"unknown"
  candidate.observations["ineligibleReasons"] = configIneligibilityReasons(
    candidate.observations["coverage"], candidate.observations["observations"])
  doAssert checkBundle(conf, candidate, current) == bcConfig
  candidate.observations = completeManifest(memberA, identity.members)
  candidate.observations["observations"].add %*{"kind": "defined", "context": memberA,
    "source": memberA, "line": "1", "key": "changedFlag", "value": "1"}
  doAssert checkBundle(conf, candidate, current) == bcConfig
  candidate.observations = completeManifest(memberA, identity.members)
  candidate.observations["group"] = %(@[memberA])
  doAssert checkBundle(conf, candidate, current) == bcInvalid
  candidate.observations = completeManifest(memberA, identity.members)
  candidate.observations["project"] = %(dir / "other.nim")
  doAssert checkBundle(conf, candidate, current) == bcInvalid
  candidate.observations = completeManifest(memberA, identity.members)
  current.identity.compilerHash = repeat('c', 64)
  doAssert checkBundle(conf, candidate, current) == bcIdentityChanged
  current.identity = identity
  current.identity.baseConfigHash = repeat('c', 64)
  doAssert checkBundle(conf, candidate, current) == bcIdentityChanged
  current.identity = identity
  current.identity.project = dir / "other-project.nim"
  doAssert checkBundle(conf, candidate, current) == bcIdentityChanged
  current.identity = identity
  current.identity.members = @[memberA]
  doAssert checkBundle(conf, candidate, current) == bcIdentityChanged
  current.identity = identity
  current.sources = @[memberA, memberB]
  doAssert checkBundle(conf, candidate, current) == bcSourceChanged
  current.sources = @[memberA, memberB, included]
  current.sources.add included
  doAssert checkBundle(conf, candidate, current) == bcInvalid
  discard current.sources.pop()
  writeFile(included, "const value = 2\n")
  doAssert checkBundle(conf, candidate, current) == bcSourceChanged
  removeFile(included)
  doAssert checkBundle(conf, candidate, current) == bcSourceChanged
  writeFile(included, "const value = 1\n")
  let artifact = candidate.artifacts[0].file.path
  let contents = readFile(artifact)
  writeFile(artifact, "corrupted")
  doAssert checkBundle(conf, candidate, current) == bcArtifactChanged
  removeFile(artifact)
  doAssert checkBundle(conf, candidate, current) == bcArtifactChanged
  writeFile(artifact, contents)
  let saved = candidate.artifacts.pop()
  doAssert checkBundle(conf, candidate, current) == bcInvalid
  candidate.artifacts.add saved
  candidate.artifacts.add saved
  doAssert checkBundle(conf, candidate, current) == bcInvalid
  discard candidate.artifacts.pop()
  candidate.artifacts[0].suffix = "wrong"
  doAssert checkBundle(conf, candidate, current) == bcInvalid
  candidate.artifacts[0].suffix = "a"
  candidate.sources[0].hash = "invalid"
  doAssert checkBundle(conf, candidate, current) == bcInvalid
  echo "bundle validation passed"
finally:
  removeDir(dir)
