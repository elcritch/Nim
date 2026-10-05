## Immutable semantic interface handoff between module actors. No compiler
## objects cross this boundary: notifications and dependencies are file names.

import std/[os, strutils]

type
  IcBodyPending* = object of Defect
    ## This is scheduler control flow, including inside `compiles()` and the
    ## VM. A speculative semantic check must not catch it as a source error.
    artifact*: string
    reason*: string
  IcHeaderUse* = object
    artifact*, snapshot*: string
  IcHeaderHook* = proc(artifact: string) {.closure, gcsafe.}

var
  onIcHeaderReady* {.threadvar.}: IcHeaderHook
  readIcHeaders* {.threadvar.}: bool
  usedIcHeaders* {.threadvar.}: seq[IcHeaderUse]
  validatedIcHeaders {.threadvar.}: int
  changedIcHeader* {.threadvar.}: bool
  publishedIcHeader* {.threadvar.}: string

proc headerArtifact*(semantic: string): string =
  doAssert semantic.endsWith(".s.bif")
  semantic[0 ..< semantic.len - ".s.bif".len] & ".h.bif"

proc pendingMarker*(semantic: string): string = semantic & ".pending"
proc headerValidation*(semantic: string): string = semantic & ".header-valid"

proc awaitIcBody*(artifact: string; reason = "body") {.noreturn.} =
  let e = newException(IcBodyPending, "semantic implementation is pending: " & artifact)
  e.artifact = artifact
  e.reason = reason
  raise e

proc semanticInput*(semantic: string): string =
  result = semantic
  if readIcHeaders and fileExists(pendingMarker(semantic)):
    try:
      result = readFile(pendingMarker(semantic))
    except IOError, OSError:
      if not fileExists(pendingMarker(semantic)): return semantic
      raise
    if result.len == 0 or not fileExists(result): awaitIcBody(semantic, "interface")
    let use = IcHeaderUse(artifact: semantic, snapshot: result)
    if use notin usedIcHeaders: usedIcHeaders.add use

proc resetIcHandoff*() =
  readIcHeaders = false
  usedIcHeaders.setLen 0
  validatedIcHeaders = 0
  changedIcHeader = false
  publishedIcHeader.setLen 0

proc requireCompleteHeaders*(reason = "vm") =
  ## VM execution and final artifact publication consume the final dependency
  ## state. Reject an earlier snapshot that changed, even if its producer has
  ## already finished; a retry loads the completed image into a fresh context.
  # A completed producer cannot restart within this scheduler round. Remember
  # accepted snapshots so repeated macro calls do not re-read their markers.
  while validatedIcHeaders < usedIcHeaders.len:
    let header = usedIcHeaders[validatedIcHeaders]
    if fileExists(pendingMarker(header.artifact)) or not fileExists(header.artifact):
      awaitIcBody(header.artifact, reason)
    let accepted = try: readFile(headerValidation(header.artifact))
                   except IOError, OSError: ""
    if accepted != header.snapshot: awaitIcBody(header.artifact, "changed")
    inc validatedIcHeaders
