discard """
  output: "bundle audit publication passed"
  joinable: false
"""

import std/[json, os, osproc, strutils, tempfiles]
import compiler/[icbundleaudit, icconfigbundle]

proc memberAt(dir: string): AuditMember =
  result.source = dir / "source.nim"
  result.suffix = "module1"
  for kind in BundleArtifactKind:
    result.artifacts[kind] = dir / (result.suffix & artifactExtension(kind))

proc publish(dir: string): string =
  let member = memberAt(dir)
  publishAuditBundle(dir / "store", member.source, repeat('a', 64), repeat('b', 64),
    "format", [member], [member.source], dir / "missing-config", dir / "missing-deps")

if paramCount() > 0 and paramStr(1) == "worker":
  discard publish(paramStr(2))
  quit(0)

let dir = createTempDir("nim_ic_audit_", "")
try:
  let member = memberAt(dir)
  writeFile(member.source, "const value = 1\n")
  for kind in BundleArtifactKind:
    writeFile(member.artifacts[kind], "bytes " & $kind)
  let first = publish(dir)
  let doc = readAuditBundle(first)
  doAssert doc != nil and not doc["complete"].getBool
  doAssert doc["configTrace"].kind == JNull and doc["dependencyTrace"].kind == JNull
  doAssert doc["artifacts"].len == 5
  # Copies are private, so a subsequent write to the source cannot mutate the
  # published bytes. Tampering with the published copy is detected by readers.
  let semantic = first / (member.suffix & artifactExtension(bakSemantic))
  let original = readFile(semantic)
  writeFile(member.artifacts[bakSemantic], "source changed")
  doAssert readFile(semantic) == original and readAuditBundle(first) != nil
  writeFile(semantic, "corrupt")
  doAssert readAuditBundle(first) == nil
  writeFile(semantic, original)
  doAssert readAuditBundle(first) != nil
  let manifestPath = first / "manifest.json"
  let manifestBytes = readFile(manifestPath)
  var malformed = parseJson(manifestBytes)
  malformed["sources"] = newJArray()
  writeFile(manifestPath, $malformed & "\n")
  writeFile(first / "READY", fingerprintFile(manifestPath) & "\n")
  doAssert readAuditBundle(first) == nil
  writeFile(manifestPath, manifestBytes)
  writeFile(first / "READY", fingerprintFile(manifestPath) & "\n")
  doAssert readAuditBundle(first) != nil
  for field in ["members", "sources", "artifacts"]:
    var invalid = parseJson(manifestBytes)
    invalid[field] = %*[42]
    writeFile(manifestPath, $invalid & "\n")
    writeFile(first / "READY", fingerprintFile(manifestPath) & "\n")
    doAssert readAuditBundle(first) == nil
  writeFile(manifestPath, manifestBytes)
  writeFile(first / "READY", fingerprintFile(manifestPath) & "\n")
  removeFile(first / "READY")
  doAssert readAuditBundle(first) == nil
  # A failed publication and an interrupted directory must not become readable.
  removeFile(member.artifacts[bakEdges])
  var failed = false
  try: discard publish(dir)
  except IOError, OSError: failed = true
  doAssert failed
  writeFile(member.artifacts[bakEdges], "bytes " & $bakEdges)
  let staging = createTempDir("bundle-", "", dir / "store")
  writeFile(staging / "manifest.json", "{}")
  doAssert readAuditBundle(staging) == nil
  var workers: seq[Process] = @[]
  for i in 0..<4:
    workers.add startProcess(getAppFilename(), args = ["worker", dir], options = {poParentStreams})
  for worker in workers:
    doAssert waitForExit(worker) == 0
    worker.close()
  var found = 0
  for kind, path in walkDir(dir / "store"):
    if kind == pcDir and readAuditBundle(path) != nil: inc found
  doAssert found == 4
  echo "bundle audit publication passed"
finally:
  removeDir(dir)
