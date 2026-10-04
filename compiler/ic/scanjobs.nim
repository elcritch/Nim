## Parse a source once for dependency discovery and the nifler parse artifact.
## Semantic analysis still parses the original source into its own native AST.
## Jobs own their files; only argv and diagnostics cross the worker boundary.

import std/[os, osproc, streams, times]
import jobtypes

# Workers relay caught I/O failures to the coordinator. Keep the scan's source
# locations in that diagnostic even in a release compiler.
{.push stackTrace: on, lineTrace: on.}

proc scanCurrent*(source, parsed, deps: string): bool =
  ## `deps` is the scan's freshness marker. The parser's content-stable outputs
  ## can legitimately be older than a source whose only edit was a comment.
  fileExists(source) and fileExists(parsed) and
    fileExists(parsed.changeFileExt(".deps.nif")) and fileExists(deps) and
    getLastModificationTime(deps) >= getLastModificationTime(source)

proc runScanJob*(arguments: seq[string]): IcJobResult {.gcsafe.} =
  ## Arguments: nifler executable, source, parsed output, dependency marker.
  result = default(IcJobResult)
  let source = arguments[1]
  let parsed = arguments[2]
  let deps = arguments[3]
  createDir(parentDir(parsed))
  let process = startProcess(arguments[0],
    args = ["parse", "--deps", source, parsed],
    options = {poUsePath, poStdErrToStdOut})
  defer: process.close()
  process.inputStream.close()
  result.output = process.outputStream.readAll()
  result.exitCode = process.waitForExit()
  if result.exitCode == 0:
    let parsedDeps = parsed.changeFileExt(".deps.nif")
    # Keep the pre-scan path for graph readers and existing caches. The two
    # dependency formats are identical. Publish freshness only after parsing
    # succeeded; a failed edit must never bless old parsed output.
    copyFile(parsedDeps, deps)
    let sourceTime = getLastModificationTime(source)
    if getLastModificationTime(parsedDeps) < sourceTime:
      # The parse rule uses its freshest output as its timestamp. Refresh only
      # the deps sidecar, so a content-stable include need not re-sem its owners.
      setLastModificationTime(parsedDeps, max(getTime(), sourceTime))
    if getLastModificationTime(deps) < sourceTime:
      setLastModificationTime(deps, max(getTime(), sourceTime))

{.pop.}
