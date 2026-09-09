#
#           The Nim Compiler
#        (c) Copyright 2026 Nim contributors
#
#    See the file "copying.txt", included in this distribution.
#

# Included from cgen.nim via ccgstmts.nim.

# Native regions share C storage with their caller. Bindings are recorded at
# declaration time, so arrays and ABI-indirect parameters retain their actual
# storage types. Rewriting C identifiers here also handles compiler temporaries
# and emitted C without changing the shared symbol locations.
proc nativeCaptureCode(code: string; bindings: Table[string, Rope];
                       used: var HashSet[string]): string =
  result = ""
  var i = 0
  var member = false
  while i < code.len:
    let start = i
    if code[i] in {'"', '\''}:
      let quote = code[i]
      inc i
      while i < code.len:
        if code[i] == '\\': i = min(i + 2, code.len)
        elif code[i] == quote:
          inc i
          break
        else: inc i
    elif i + 1 < code.len and code[i] == '/' and code[i+1] in {'/', '*'}:
      let line = code[i+1] == '/'
      i += 2
      while i < code.len:
        if line and code[i] == '\n': break
        if not line and i + 1 < code.len and code[i..i+1] == "*/":
          i += 2
          break
        inc i
    elif code[i] in IdentStartChars:
      inc i
      while i < code.len and code[i] in IdentChars: inc i
      let name = code[start..<i]
      if not member and bindings.hasKey(name):
        used.incl name
        result.add "(*nativeEnv_->" & name & ")"
      else:
        result.add name
      member = false
      continue
    else:
      if code[i] notin Whitespace:
        member = code[i] == '.' or (code[i] == '>' and i > 0 and code[i-1] == '-')
      inc i
    result.add code[start..<i]

proc genNativeBody(p: BProc; body: PNode; d: var TLoc):
    tuple[callback, context: Rope, exits: seq[PNode]] =
  result = default(typeof(result))
  let name = getTempName(p.module) & "Native"
  let contextType = name & "Context"
  result.callback = name
  result.context = name & "Env"
  var bindings = initTable[string, Rope]()
  for b in p.blocks:
    for binding in b.nativeLocals:
      bindings[$binding.name] = binding.typ
  let depth = p.blocks.len
  let savedTrys = p.nestedTryStmts
  let savedFinally = p.finallySafePoints
  p.nestedTryStmts = @[]
  p.finallySafePoints = @[]
  p.nativeRegions.add((depth, newSeq[PNode]()))
  p.blocks.add initBlock()
  expr(p, body, d)
  result.exits = p.nativeRegions.pop.exits
  p.nestedTryStmts = savedTrys
  p.finallySafePoints = savedFinally
  var blockCode = newBuilder("")
  p.blocks[^1].blockBody(blockCode)
  p.blocks.setLen(depth)
  var used = initHashSet[string]()
  let code = nativeCaptureCode($extract(blockCode), bindings, used)
  # Deterministic field order keeps generated code and compiler caches stable.
  var names = newSeq[string]()
  for name in used: names.add name
  names.sort()
  var fields = "typedef struct {\n"
  if names.len == 0: fields.add "char unused;\n"
  for name in names:
    fields.add $bindings[name] & " *" & name & ";\n"
  fields.add "} " & $contextType & ";\n"
  p.module.s[cfsTypes].add fields
  p.s(cpsLocals).addVar(name = result.context, typ = contextType)
  p.nativeLocal(result.context, contextType)
  for name in names:
    p.s(cpsStmts).addFieldAssignment(result.context, name, cAddr(name))
  var definition = "static int " & $result.callback & "(void *context) {\n" &
    $contextType & " *nativeEnv_ = (" & $contextType & " *)context;\n" &
    "int nativeResult_ = 0;\n"
  if emulatedThreadVars(p.config) and threadVarAccessed in p.flags:
    definition.add "NimThreadVars *NimTV_ = (NimThreadVars *)" &
      $cgsymValue(p.module, "GetThreadLocalVars") & "();\n"
  if optStackTrace in p.options:
    definition.add $initFrame(p, makeCString("protected region"), quotedFilename(p.config, body.info))
  definition.add code
  definition.add "NativeRet_:;\n"
  if optStackTrace in p.options: definition.add $deinitFrame(p)
  definition.add "return nativeResult_;\n}\n"
  p.module.s[cfsProcs].add definition

