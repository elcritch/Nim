discard """
  output: "IC scan/parse reuse OK"
  cmd: "nim c --skipParentCfg -r $options $file"
  matrix: "--mm:arc; --mm:atomicArc"
"""

import std/[os, times, tempfiles]
import ../../compiler/ic/scanjobs

let nifler = currentSourcePath().parentDir.parentDir.parentDir / "bin" / "nifler"
let dir = createTempDir("nim ic scan ", "")
try:
  let source = dir / "source with spaces.nim"
  let parsed = dir / "source.p.nif"
  let deps = dir / "source.deps.nif"
  let parsedDeps = parsed.changeFileExt(".deps.nif")
  let args = @[nifler, source, parsed, deps]
  writeFile(source, "const value = 1\n")
  doAssert not scanCurrent(source, parsed, deps)
  doAssert runScanJob(args).exitCode == 0
  doAssert scanCurrent(source, parsed, deps)
  doAssert readFile(deps) == readFile(parsedDeps)
  let original = readFile(parsed)

  # A content-stable parse stays stable, but freshness still advances so neither
  # dependency discovery nor the later parse rule has to repeat the work.
  let old = fromUnix(getTime().toUnix - 86_400)
  for path in [source, parsed, deps, parsedDeps]: setLastModificationTime(path, old)
  writeFile(source, "const value = 1\n# comment only\n")
  setLastModificationTime(source, old + initDuration(seconds = 1))
  doAssert not scanCurrent(source, parsed, deps)
  doAssert runScanJob(args).exitCode == 0
  doAssert readFile(parsed) == original
  doAssert getLastModificationTime(parsed) == old
  doAssert scanCurrent(source, parsed, deps)
  doAssert getLastModificationTime(parsedDeps) >= getLastModificationTime(source)

  # Unchanged imports must not hide an edited body, including an SCC member or
  # include whose parsed file is its only input to the semantic rule.
  for path in [parsed, deps, parsedDeps]: setLastModificationTime(path, old)
  writeFile(source, "const value = 2\n")
  doAssert runScanJob(args).exitCode == 0
  doAssert readFile(parsed) != original

  # A failed parse cannot publish a fresh dependency marker for old output.
  let good = readFile(parsed)
  setLastModificationTime(deps, old)
  writeFile(source, "const =\n")
  doAssert runScanJob(args).exitCode != 0
  doAssert not scanCurrent(source, parsed, deps)
  doAssert getLastModificationTime(deps) == old
  doAssert readFile(parsed) == good

  writeFile(source, "const value = 3\n")
  doAssert runScanJob(args).exitCode == 0
  removeFile(parsed)
  doAssert not scanCurrent(source, parsed, deps), "fresh deps cannot mask a missing parse"
  doAssert runScanJob(args).exitCode == 0
  doAssert scanCurrent(source, parsed, deps)
finally:
  removeDir(dir)

echo "IC scan/parse reuse OK"
