## Included by sem.nim. A job checks one whole routine against private copies
## of its reachable declarations. Every reference in a worker's context is
## private; the source graph and identity maps stay on the module thread.
{.push warning[Uninit]: off, warning[ProveInit]: off.}

type
  BodyNotIsolated = object of CatchableError
  BodyCloner = object
    cache: IdentCache
    syms: Table[pointer, PSym]
    types: Table[pointer, PType]
    nodes: Table[pointer, PNode]
    originals: Table[pointer, PSym]
    originalTypes: Table[pointer, PType]
    source: PContext
    task: int
    templates: Table[pointer, PNode]
    instanceCaches: HashSet[ItemId]
  IsolatedBody = object
    context: PContext
    owner: PSym
    definition: PNode
    resultType: PType
    syms: seq[PSym]
    types: seq[PType]
    failed: bool
    failure: string
    output: string
    thread: int
    started, finished: int64
    templateCounter: int
    prepareNs: int64

const scalarKinds = {tyBool, tyChar, tyInt..tyInt64, tyUInt..tyUInt64,
                     tyFloat..tyFloat64}
const scalarMagics = {
  mAddI, mSubI, mMulI, mDivI, mModI, mAddU, mSubU, mMulU, mDivU, mModU,
  mAddF64, mSubF64, mMulF64, mDivF64, mShrI, mShlI, mBitandI, mBitorI,
  mBitxorI, mEqI, mLeI, mLtI, mEqF64, mLeF64, mLtF64, mLeU, mLtU,
  mEqCh, mLeCh, mLtCh, mEqB, mLeB, mLtB, mXor, mUnaryMinusI,
  mUnaryMinusI64, mAbsI, mNot, mUnaryPlusI, mBitnotI, mUnaryPlusF64,
  mUnaryMinusF64, mAnd, mOr}

proc bodyUnsupported(reason: string) {.noreturn.} =
  raise newException(BodyNotIsolated, reason)

proc checkIsolatedCall(s: PSym) {.nimcall.} =
  # Check the selected overload, not every overload sharing its name. This
  # admits ordinary runtime calls without accidentally executing a macro/VM.
  if s.kind == skTemplate:
    if s.ast[bodyPos].kind == nkEmpty: bodyUnsupported("template: " & s.name.s)
    return
  if s.kind notin {skProc, skFunc, skConverter} or sfCompileTime in s.flags:
    bodyUnsupported("compile-time call: " & s.name.s)
  if s.annex != nil and s.annex.kind == libDynamic:
    bodyUnsupported("dynamic library call: " & s.name.s)
  if s.magic notin scalarMagics + {mNone, mArrGet, mArrPut, mAsgn,
      mLengthOpenArray, mLengthStr, mLengthArray, mLengthSeq, mOrd, mChr,
      mHigh, mLow, mSizeOf, mAlignOf, mEqRef, mLePtr, mLtPtr, mEqEnum,
      mLeEnum, mLtEnum, mEqStr, mLeStr, mLtStr, mEqCString, mConStrStr,
      mIsNil, mAddr, mMinI, mMaxI, mInc, mDec, mSucc, mPred,
      mEqSet, mLeSet, mLtSet, mMulSet, mPlusSet, mMinusSet, mXorSet,
      mInSet, mCard, mRunnableExamples}:
    bodyUnsupported("builtin: " & s.name.s)

proc concreteBodyType(t: PType): bool =
  if t == nil: return true
  let root = t.skipTypes({tyAlias, tyGenericInst, tyVar, tyLent, tySink})
  root.kind notin GenericTypes + {tyFromExpr, tyAnything, tyUntyped, tyTyped,
    tyStatic, tyTypeDesc, tyForward, tyError} and tfHasMeta notin t.flags

proc cloneBodyNode(b: var BodyCloner; n: PNode): PNode
proc cloneBodySym(b: var BodyCloner; s: PSym): PSym
proc cloneBodyType(b: var BodyCloner; t: PType): PType =
  if t == nil: return nil
  let key = cast[pointer](t)
  if key in b.types: return b.types[key]
  if b.types.len >= 4096: bodyUnsupported("large type environment")
  discard t.flags # materialize on the owning module thread
  if t.kind in {tyForward, tyError}: bodyUnsupported("type " & $t.kind)
  result = PType()
  result[] = t[]
  # Preserve Sealed: semantic checking uses it to decide when a view or
  # converter result needs a fresh type. Unsealing changed that allocation.
  b.types[key] = result
  b.originalTypes[cast[pointer](result)] = t
  result.ownerFieldImpl = nil
  result.symImpl = nil
  result.nImpl = nil
  result.typeInstImpl = nil
  result.locImpl = default(TLoc)
  result.sonsImpl = @[]
  for child in t.sons: result.sonsImpl.add b.cloneBodyType(child)
  result.ownerFieldImpl = b.cloneBodySym(t.owner)
  result.symImpl = b.cloneBodySym(t.sym)
  result.nImpl = b.cloneBodyNode(t.n)
  result.typeInstImpl = b.cloneBodyType(t.typeInst)

proc cloneBodySym(b: var BodyCloner; s: PSym): PSym =
  if s == nil: return nil
  let key = cast[pointer](s)
  if key in b.syms: return b.syms[key]
  if b.syms.len >= 4096: bodyUnsupported("large symbol environment")
  let kind = s.kind
  if kind in {skUnknown, skStub}: bodyUnsupported("symbol " & $kind & " " & s.name.s)
  if kind in routineKinds and b.source != nil:
    let dependency = b.source.bodyTaskIndex.getOrDefault(s.itemId, -1)
    if dependency >= 0 and dependency != b.task and
        b.source.bodyTasks[dependency].state != btDone:
      bodyUnsupported("pending effects: " & s.name.s)
  result = PSym(kindImpl: kind)
  result[] = s[]
  b.syms[key] = result
  b.originals[cast[pointer](result)] = s
  result.name = b.cache.getIdent(s.name.s)
  result.ownerFieldImpl = nil
  result.typImpl = nil
  result.astImpl = nil
  result.constraintImpl = nil
  result.instantiatedFromImpl = nil
  result.annexImpl = nil
  result.locImpl = default(TLoc)
  if kind in routineKinds:
    result.gcUnsafetyReasonImpl = nil
    result.transformedBodyImpl = nil
  elif kind in {skLet, skVar, skField, skForVar}:
    result.guardImpl = nil
  result.ownerFieldImpl = b.cloneBodySym(s.owner)
  if s.annex != nil:
    result.annexImpl = PLib()
    result.annexImpl[] = s.annex[]
    result.annexImpl.path = b.cloneBodyNode(s.annex.path)
  if kind notin {skModule, skPackage}:
    result.typImpl = b.cloneBodyType(s.typ)
    result.constraintImpl = b.cloneBodyNode(s.constraint)
    result.instantiatedFromImpl = b.cloneBodySym(s.instantiatedFrom)
    if kind in {skParam, skEnumField, skConst, skField, skGenericParam}:
      result.astImpl = b.cloneBodyNode(s.ast)
    elif kind in routineKinds and s.ast != nil:
      let prototype = s.ast
      result.astImpl = newNodeI(prototype.kind, prototype.info)
      result.astImpl.flags = prototype.flags - {nfLazyBody, nfHasComment}
      for i, child in prototype:
        result.astImpl.sons.add(if i == bodyPos: newNode(nkEmpty)
                               else: b.cloneBodyNode(child))
      if key in b.templates:
        result.astImpl[bodyPos] = b.cloneBodyNode(b.templates[key])
    if kind in routineKinds:
      result.gcUnsafetyReasonImpl = b.cloneBodySym(s.gcUnsafetyReason)
    elif kind in {skLet, skVar, skField, skForVar}:
      result.guardImpl = b.cloneBodySym(s.guard)

proc cloneBodyNode(b: var BodyCloner; n: PNode): PNode =
  if n == nil: return nil
  let key = cast[pointer](n)
  if key in b.nodes: return b.nodes[key]
  result = newNodeI(n.kind, n.info)
  b.nodes[key] = result
  result.flags = n.flags - {nfHasComment, nfLazyBody, nfLazyType}
  result.typ = b.cloneBodyType(n.typ)
  case n.kind
  of nkSym: result.sym = b.cloneBodySym(n.sym)
  of nkIdent: result.ident = b.cache.getIdent(n.ident.s)
  of nkCharLit..nkUInt64Lit: result.intVal = n.intVal
  of nkFloatLit..nkFloat128Lit: result.floatVal = n.floatVal
  of nkStrLit..nkTripleStrLit: result.strVal = n.strVal
  else:
    for child in n: result.sons.add b.cloneBodyNode(child)

proc bodySyntax(n: PNode; count: var int; reason: var string): bool =
  if n == nil: return true
  inc count
  case n.kind
  of nkEmpty, nkCommentStmt, nkCharLit..nkNilLit: return true
  of nkIdent: return true
  of nkStmtList, nkStmtListExpr, nkAsgn, nkFastAsgn, nkLetSection, nkVarSection, nkIdentDefs,
     nkReturnStmt, nkDiscardStmt, nkIfStmt, nkIfExpr, nkElifBranch, nkElse,
     nkElifExpr, nkElseExpr, nkWhileStmt, nkBreakStmt, nkContinueStmt,
     nkBlockStmt, nkBlockExpr, nkPar, nkInfix, nkPrefix, nkAccQuoted,
     nkCall, nkCommand, nkDotExpr, nkExprColonExpr, nkExprEqExpr,
     nkObjConstr, nkTupleConstr, nkCast, nkBracketExpr, nkBracket,
     nkCaseStmt, nkOfBranch, nkCurly:
    discard
  else:
    reason = "syntax:" & $n.kind
    return false
  for child in n:
    if not bodySyntax(child, count, reason): return false
  true

proc bodyConfig(source: ConfigRef): ConfigRef =
  result = ConfigRef()
  for name, dst, src in fieldPairs(result[], source[]):
    when dst is StringTableRef:
      if src != nil:
        new(dst)
        dst[] = src[]
    elif dst is ProfileData:
      discard
    elif dst is (proc):
      discard # diagnostic callbacks must never capture the module's state
    else:
      dst = src
  result.errorCounter = 0
  result.warnCounter = 0
  result.hintCounter = 0

proc collectBodyNames(c: PContext; task: BodyTask): Table[int, PIdent] =
  ## Locals and real fields are not global lookups. Treating every identifier
  ## as a lookup pulled unrelated getters and their complete type graphs into
  ## otherwise small jobs (for example, a Point.x field pulled in View.x).
  let visible = PContext(module: c.module, cache: c.cache, graph: c.graph,
    currentScope: task.scope, topLevelScope: task.topLevelScope,
    moduleScope: task.moduleScope, imports: task.imports)
  proc fieldType(typ: PType; name: PIdent): PType =
    if typ == nil: return nil
    var t = typ.skipTypes({tyAlias, tyGenericInst, tyVar, tyLent, tySink, tyRef, tyPtr})
    if t.kind notin {tyObject, tyTuple}: return nil
    while t != nil:
      if t.n != nil:
        let field = lookupInRecord(t.n, name)
        if field != nil: return field.typ
      if t.kind != tyObject: break
      t = t.baseClass
  proc hint(n: PNode; locals: Table[int, PType]): PType =
    if n == nil: return nil
    case n.kind
    of nkIdent:
      if n.ident.id in locals: return locals[n.ident.id]
      let s = qualifiedLookUp(visible, n, {})
      if s != nil and s.kind in {skType, skParam, skVar, skLet, skConst}:
        return s.typ
    of nkDotExpr:
      if n[1].kind == nkIdent: return fieldType(hint(n[0], locals), n[1].ident)
    else: discard
  proc collect(n: PNode; locals: var Table[int, PType]; names: var Table[int, PIdent];
               callHead = false) =
    if n == nil: return
    case n.kind
    of nkIdent:
      if n.ident.id notin locals: names[n.ident.id] = n.ident
      return
    of nkDotExpr:
      collect(n[0], locals, names)
      if callHead or n[1].kind != nkIdent or fieldType(hint(n[0], locals), n[1].ident) == nil:
        # A selector can be a UFCS call, getter, or module-qualified name even
        # if another local has that name.
        var empty: Table[int, PType]
        collect(n[1], empty, names)
      return
    of nkIdentDefs:
      collect(n[^2], locals, names)
      collect(n[^1], locals, names)
      let typ = if n[^2].kind != nkEmpty: hint(n[^2], locals)
                else: hint(n[^1], locals)
      for i in 0 ..< n.len - 2:
        if n[i].kind == nkIdent: locals[n[i].ident.id] = typ
      return
    of nkExprColonExpr, nkExprEqExpr:
      collect(n[1], locals, names)
      return
    of nkIfStmt, nkIfExpr, nkCaseStmt, nkWhileStmt, nkBlockStmt, nkBlockExpr:
      for child in n:
        var inner = locals
        collect(child, inner, names)
      return
    of nkCall, nkCommand, nkInfix, nkPrefix:
      collect(n[0], locals, names, callHead = true)
      for i in 1 ..< n.len: collect(n[i], locals, names)
      return
    else:
      for i in 0 ..< n.safeLen: collect(n[i], locals, names)
  var locals: Table[int, PType]
  for sym in task.scope.symbols:
    if sym.kind == skParam: locals[sym.name.id] = sym.typ
  locals[c.cache.getIdent("result").id] = task.resultType
  collect(task.def[bodyPos], locals, result)

proc simpleBodyTemplate(n: PNode; names: var Table[int, PIdent]; count: var int): bool =
  ## Expression templates have no generated names, declarations or VM state.
  ## Open choices still need the caller's original lookup environment.
  if n == nil: return true
  inc count
  if count > 128: return false
  case n.kind
  of nkEmpty, nkCommentStmt, nkCharLit..nkNilLit: return true
  of nkIdent:
    names[n.ident.id] = n.ident
    return true
  of nkSym:
    if sfGenSym in n.sym.flags: return false
    return true
  of nkOpenSymChoice, nkOpenSym:
    if n.len > 0 and n[0].kind == nkSym:
      let name = n[0].sym.name
      names[name.id] = name
  of nkCall, nkCommand, nkInfix, nkPrefix, nkPar, nkDotExpr, nkBracketExpr,
      nkExprColonExpr, nkClosedSymChoice, nkStmtListExpr, nkStmtList:
    discard
  else: return false
  for child in n:
    if not simpleBodyTemplate(child, names, count): return false
  true

proc prepareBodyLookups(c: PContext; task: BodyTask; b: var BodyCloner;
                        names: var Table[int, PIdent]) =
  let visible = PContext(module: c.module, cache: c.cache, graph: c.graph,
    currentScope: task.scope, topLevelScope: task.topLevelScope,
    moduleScope: task.moduleScope, imports: task.imports)
  var examined: HashSet[int]
  while true:
    var pending: seq[PIdent]
    for id, name in names:
      if not examined.containsOrIncl(id): pending.add name
    if pending.len == 0: break
    if examined.len > 256: bodyUnsupported("large lookup environment")
    for name in pending:
      var it: TOverloadIter
      let node = newIdentNode(name, task.owner.info)
      var sym = initOverloadIter(it, visible, node)
      while sym != nil:
        if sym.kind in {skProc, skFunc, skConverter}:
          b.instanceCaches.incl sym.itemId
        if sym.kind == skTemplate:
          let body = getBody(c.graph, sym)
          var extra: Table[int, PIdent]
          var count = 0
          if simpleBodyTemplate(body, extra, count):
            b.templates[cast[pointer](sym)] = body
            for id, name in extra: names[id] = name
        sym = nextOverloadIter(it, visible, node)
  proc checkHeads(n: PNode; b: BodyCloner) =
    if n == nil: return
    if n.kind in {nkCall, nkCommand, nkInfix, nkPrefix} and n[0].kind == nkIdent:
      var it: TOverloadIter
      var sym = initOverloadIter(it, visible, n[0])
      let found = sym != nil
      var possible = false
      while sym != nil:
        if sym.kind == skTemplate:
          possible = possible or cast[pointer](sym) in b.templates
        elif sym.kind in {skProc, skFunc, skConverter}:
          let generic = sym.ast != nil and sym.ast[genericParamsPos].kind != nkEmpty
          possible = possible or (sfCompileTime notin sym.flags and
            (not generic or c.graph.procInstCache.getOrDefault(sym.itemId).len > 0))
        elif sym.kind != skMacro:
          possible = true # conversions, locals, or a call operator
        sym = nextOverloadIter(it, visible, n[0])
      if found and not possible: bodyUnsupported("call dependency: " & n[0].ident.s)
    for i in 0 ..< n.safeLen: checkHeads(n[i], b)
  checkHeads(task.def[bodyPos], b)

proc bodyCandidate(c: PContext; index: int): bool =
  let task = c.bodyTasks[index]
  template decision(reason: string) = bodyDecision(c.module.name.s, task.key, reason)
  if task.state != btPending: return false
  if task.patterns.len > 0:
    decision("patterns")
    return false
  if typeBoundOps in task.features:
    decision("type-bound lookup")
    return false
  if not concreteBodyType(task.resultType):
    decision("return:" & $task.resultType.kind)
    return false
  for i in 1 ..< task.owner.typ.len:
    if not concreteBodyType(task.owner.typ[i]):
      decision("parameter:" & $task.owner.typ[i].kind)
      return false
  var count = 0
  var reason = "syntax:declaration"
  if not bodySyntax(task.def[bodyPos], count, reason):
    decision(reason)
    return false
  if count < 64:
    decision("small")
    return false
  true

proc prepareIsolatedBody(c: PContext; index: int; b: var BodyCloner): ptr IsolatedBody =
  let started = getMonoTime().ticks
  let task = c.bodyTasks[index]
  template decision(reason: string) = bodyDecision(c.module.name.s, task.key, reason)
  if not bodyCandidate(c, index): return nil
  var names = collectBodyNames(c, task)
  prepareBodyLookups(c, task, b, names)
  # Bracket syntax can invoke user overloads as well as builtins.
  for name in [".", ".=", ".()", "()", "Exception", "RootEffect"]:
    let ident = c.cache.getIdent(name)
    names[ident.id] = ident
  var indexed = containsNode(task.def[bodyPos], {nkBracketExpr})
  for key, body in b.templates:
    indexed = indexed or containsNode(body, {nkBracketExpr})
  if indexed:
    for name in ["[]", "[]="]:
      let ident = c.cache.getIdent(name)
      names[ident.id] = ident
      let visible = PContext(module: c.module, cache: c.cache, graph: c.graph,
        currentScope: task.scope, topLevelScope: task.topLevelScope,
        moduleScope: task.moduleScope, imports: task.imports)
      var it: TOverloadIter
      let node = newIdentNode(ident, task.owner.info)
      var sym = initOverloadIter(it, visible, node)
      while sym != nil:
        b.instanceCaches.incl sym.itemId
        sym = nextOverloadIter(it, visible, node)
  # Property assignment can look up a setter whose name is absent in the AST.
  var setters: seq[PIdent]
  for id, ident in names: setters.add c.cache.getIdent(ident.s & "=")
  for ident in setters: names[ident.id] = ident
  b.source = c
  b.task = index
  b.cache = newIdentCache()
  # Materializing declarations can register additional source files. Snapshot
  # configuration only after that work, while still on the module thread.
  let graph = ModuleGraph(config: c.config, cache: b.cache,
    emptyNode: newNode(nkEmpty), isolatedBody: true, checkBodyCall: checkIsolatedCall)
  let ctx = newContext(graph, b.cloneBodySym(c.module))
  for name, dst, src in fieldPairs(ctx[], c[]):
    when dst is (proc):
      when name notin ["onHeadersReady", "prevDemandRoutineBody"]:
        dst = src
  ctx.idgen = IdGenerator(module: c.idgen.module, symId: c.idgen.symId,
    typeId: c.idgen.typeId)
  graph.idgen = IdGenerator(module: c.graph.idgen.module,
    symId: c.graph.idgen.symId, typeId: c.graph.idgen.typeId)
  for name, dst, src in fieldPairs(graph.operators, c.graph.operators):
    dst = b.cloneBodySym(src)
  graph.systemModule = b.cloneBodySym(c.graph.systemModule)
  graph.ifaces.setLen(c.graph.ifaces.len)
  graph.ifaces[ctx.module.position].module = ctx.module
  graph.ifaces[graph.systemModule.position].module = graph.systemModule
  ctx.enforceVoidContext = b.cloneBodyType(c.enforceVoidContext)
  ctx.voidType = b.cloneBodyType(c.voidType)
  ctx.nilTypeCache = b.cloneBodyType(c.nilTypeCache)
  new(ctx.templInstCounter)
  ctx.templInstCounter[] = c.templInstCounter[]
  for value in low(ctx.intTypeCache) .. high(ctx.intTypeCache):
    ctx.intTypeCache[value] = b.cloneBodyType(c.intTypeCache[value])
  for kind, typ in c.graph.sysTypes:
    graph.sysTypes[kind] = b.cloneBodyType(typ)
  for kind in scalarKinds + {tyString, tyCstring, tyPointer}:
    graph.sysTypes[kind] = b.cloneBodyType(getSysType(c.graph, task.owner.info, kind))
  graph.sysTypes[tyVoid] = b.cloneBodyType(getSysType(c.graph, task.owner.info, tyVoid))
  proc cloneScope(source: PScope; b: var BodyCloner): PScope =
    if source == nil: return nil
    result = PScope(depthLevel: source.depthLevel,
      optionStackLen: source.optionStackLen)
    result.parent = cloneScope(source.parent, b)
    if source == task.moduleScope: ctx.moduleScope = result
    if source == task.topLevelScope: ctx.topLevelScope = result
    for sym in source.symbols:
      if source == task.scope or sym.name.id in names:
        result.addSym(b.cloneBodySym(sym))
    for sym in source.allowPrivateAccess:
      result.allowPrivateAccess.add b.cloneBodySym(sym)
  ctx.currentScope = cloneScope(task.scope, b)
  # Preserve scope depths, import order, aliases, and selective imports. Moving
  # every declaration into one scope would change overload resolution.
  var copiedModules: HashSet[int]
  for im in task.imports:
    if optImportHidden in im.m.options: bodyUnsupported("hidden import")
    let module = b.cloneBodySym(im.m)
    ctx.importModuleLookup[module.name.id] = c.importModuleLookup.getOrDefault(im.m.name.id)
    var imported = ImportedModule(m: module, mode: importSet)
    let first = not copiedModules.containsOrIncl(module.position)
    graph.ifaces[module.position].module = module
    for id, name in names:
      var it: ModuleIter
      var sym = initModuleIter(it, c.graph, im.m, name)
      while sym != nil:
        if first: graph.strTableAdds(module, b.cloneBodySym(sym))
        let visible = case im.mode
          of importAll: true
          of importSet: sym.id in im.imported
          of importExcept: sym.name.id notin im.exceptSet
        if visible: imported.imported.incl sym.id
        sym = nextModuleIter(it, c.graph)
    ctx.imports.add imported
  for sym in c.pureEnumFields:
    if sym.name.id in names: strTableAdd(ctx.pureEnumFields, b.cloneBodySym(sym))
  for sym in c.converters: ctx.converters.add b.cloneBodySym(sym)
  for sym in c.friendModules: ctx.friendModules.add b.cloneBodySym(sym)
  ctx.optionStack.setLen 0
  for entry in task.optionStack:
    if entry.dynlib != nil: bodyUnsupported("dynamic library pragma")
    var copy = POptionEntry()
    copy[] = entry[]
    copy.otherPragmas = b.cloneBodyNode(entry.otherPragmas)
    ctx.optionStack.add copy
  let owner = b.cloneBodySym(task.owner)
  owner.ast = b.cloneBodyNode(task.def)
  ctx.p = PProcCon(owner: owner, resultSym: b.cloneBodySym(task.procCon.resultSym))
  graph.owners = @[ctx.module, owner]
  ctx.features = task.features
  # Copy already-published hooks for every reachable type. New hooks require
  # the module thread; a later procedure can then reuse the published hooks.
  var copiedTypes: HashSet[pointer]
  var copiedSyms: HashSet[pointer]
  while true:
    var pending: seq[PType]
    for key, typ in b.types:
      if not copiedTypes.containsOrIncl(key): pending.add b.originalTypes[cast[pointer](typ)]
    var routines: seq[PSym]
    for key, sym in b.syms:
      if not copiedSyms.containsOrIncl(key) and sym.kind in routineKinds:
        routines.add b.originals[cast[pointer](sym)]
    if pending.len == 0 and routines.len == 0: break
    for sym in routines:
      if sym.itemId notin b.instanceCaches: continue
      for inst in c.graph.procInstCache.getOrDefault(sym.itemId):
        var copy = PInstantiation(sym: b.cloneBodySym(inst.sym),
          genericParamsCount: inst.genericParamsCount, compilesId: inst.compilesId)
        for typ in inst.concreteTypes: copy.concreteTypes.add b.cloneBodyType(typ)
        for binding in inst.bindings:
          copy.bindings.add (binding.key, b.cloneBodyType(binding.value))
        graph.procInstCache.mgetOrPut(sym.itemId, @[]).add copy
    for typ in pending:
      if tfCheckedForDestructor in typ.flags:
        for op in TTypeAttachedOp:
          let hook = c.graph.getAttachedOp(typ, op)
          if hook != nil:
            graph.attachedOps[op][typ.bindingId] = b.cloneBodySym(hook)
  graph.config = bodyConfig(c.config)
  graph.config.options = task.options
  graph.config.notes = task.notes
  graph.config.warningAsErrors = task.warningAsErrors
  result = createShared(IsolatedBody)
  result.context = ctx
  result.owner = owner
  result.definition = owner.ast
  result.resultType = b.cloneBodyType(task.resultType)
  result.templateCounter = c.templInstCounter[]
  result.prepareNs = getMonoTime().ticks - started
  decision("eligible")

proc executeIsolatedBody(data: pointer) {.nimcall, gcsafe.} =
  {.cast(gcsafe).}:
    let job = cast[ptr IsolatedBody](data)
    job.thread = getThreadId()
    job.started = getMonoTime().ticks
    beginIcWorker()
    try:
      let c = job.context
      c.config.writelnHook = proc(message: string) {.gcsafe.} =
        job.output.add message & "\n"
      semRoutineBodyUnit(c, job.owner, job.definition, job.resultType, false)
      closeScope(c)
      if c.graph.typeInstCache.len != 0 or c.generics.len != 0 or
          c.graph.opsLog.len != 0:
        bodyUnsupported("unpublished semantic state")
      job.failed = c.config.errorCounter != 0
    except CatchableError, Defect:
      # Retry on the original module thread, including its normal diagnostics.
      job.failed = true
      job.failure = getCurrentExceptionMsg()
    finally:
      let arena = takeIcAst()
      job.syms = arena.syms
      job.types = arena.types
      resetCompilerAst()
      endIcWorker()
      job.finished = getMonoTime().ticks

proc mergeIsolatedBody(c: PContext; index: int; job: ptr IsolatedBody; b: var BodyCloner) =
  var seenNodes: HashSet[pointer]
  # Sequential bodies share the small integer-literal cache. Coalesce private
  # entries before allocating IDs, preserving both identities and the watermark.
  for value in low(c.intTypeCache) .. high(c.intTypeCache):
    let typ = job.context.intTypeCache[value]
    if typ == nil: continue
    let key = cast[pointer](typ)
    if c.intTypeCache[value] != nil:
      if key notin b.originalTypes: b.types[key] = typ # discarded after remapping
      b.originalTypes[key] = c.intTypeCache[value]
    else:
      c.intTypeCache[value] = b.originalTypes.getOrDefault(key, typ)
  let nilType = job.context.nilTypeCache
  if nilType != nil:
    let key = cast[pointer](nilType)
    if c.nilTypeCache != nil:
      if key notin b.originalTypes: b.types[key] = nilType
      b.originalTypes[key] = c.nilTypeCache
    else:
      c.nilTypeCache = b.originalTypes.getOrDefault(key, nilType)
  let originalSyms = b.originals
  let originalTypes = b.originalTypes
  proc remapSym(s: PSym): PSym =
    if s == nil: return nil
    originalSyms.getOrDefault(cast[pointer](s), s)
  proc remapType(t: PType): PType =
    if t == nil: return nil
    originalTypes.getOrDefault(cast[pointer](t), t)
  proc remapNode(n: PNode) =
    if n == nil or seenNodes.containsOrIncl(cast[pointer](n)): return
    n.typ = remapType(n.typ)
    case n.kind
    of nkSym: n.sym = remapSym(n.sym)
    of nkIdent: n.ident = c.cache.getIdent(n.ident.s)
    of nkCharLit..nkTripleStrLit: discard
    else:
      for child in n: remapNode(child)
  var typeIds: Table[ItemId, ItemId]
  var symIds: Table[int, int]
  for typ in job.types:
    let old = typ.itemId
    # commonTypeBegin's temporary sentinel has no allocated identity.
    if old.item == 0: continue
    let replacement = originalTypes.getOrDefault(cast[pointer](typ))
    if replacement != nil:
      typeIds[old] = replacement.itemId
    else:
      typ.itemId = if old.module == c.idgen.module: c.idgen.nextTypeId()
                   else: c.graph.idgen.nextTypeId()
      typeIds[old] = typ.itemId
  for sym in job.syms:
    let old = sym.id
    inc c.idgen.symId
    sym.itemId = itemId(c.idgen.module, c.idgen.symId)
    symIds[old] = sym.id
    sym.name = c.cache.getIdent(sym.name.s)
    sym.disamb = c.idgen.disambTable.getOrDefault(sym.name).int32
    c.idgen.disambTable.inc sym.name
  for typ in job.types:
    if cast[pointer](typ) in originalTypes: continue
    typ.bindingId = typeIds.getOrDefault(typ.bindingId, typ.bindingId)
    typ.ownerFieldImpl = remapSym(typ.ownerFieldImpl)
    typ.symImpl = remapSym(typ.symImpl)
    typ.typeInstImpl = remapType(typ.typeInstImpl)
    for child in typ.sonsImpl.mitems: child = remapType(child)
    remapNode(typ.nImpl)
    discard ownIc(typ)
  for sym in job.syms:
    sym.ownerFieldImpl = remapSym(sym.ownerFieldImpl)
    sym.typImpl = remapType(sym.typImpl)
    sym.instantiatedFromImpl = remapSym(sym.instantiatedFromImpl)
    if sym.kindImpl in routineKinds:
      sym.gcUnsafetyReasonImpl = remapSym(sym.gcUnsafetyReasonImpl)
      remapNode(sym.transformedBodyImpl)
    elif sym.kindImpl in {skLet, skVar, skField, skForVar}:
      sym.guardImpl = remapSym(sym.guardImpl)
    remapNode(sym.constraintImpl)
    remapNode(sym.astImpl)
    discard ownIc(sym)
  let owner = c.bodyTasks[index].owner
  for key, copy in b.types:
    let original = b.originalTypes.getOrDefault(cast[pointer](copy))
    if original != nil:
      original.flagsImpl = original.flagsImpl + copy.flagsImpl
  for old, copy in b.syms:
    let original = b.originals[cast[pointer](copy)]
    original.flagsImpl = original.flagsImpl + copy.flagsImpl
    if original.kind in {skParam, skResult} and original.owner == owner:
      original.typImpl = remapType(copy.typImpl)
  let body = job.owner.ast[bodyPos]
  remapNode(body)
  owner.ast[bodyPos] = body
  if owner.ast.len > resultPos and owner.ast[resultPos].kind == nkSym:
    owner.ast[resultPos].typ = owner.ast[resultPos].sym.typ
  let effects = job.owner.typ.n
  remapNode(effects)
  owner.typ.n = effects
  owner.typ.flagsImpl = job.owner.typ.flagsImpl
  owner.gcUnsafetyReason = remapSym(job.owner.gcUnsafetyReason)
  c.templInstCounter[] += job.context.templInstCounter[] - job.templateCounter
  for dependency in job.context.graph.icImplDeps: c.graph.icImplDeps.incl dependency
  for module, expansions in job.context.graph.nifExpansions:
    for (sym, info) in expansions:
      c.graph.nifExpansions.mgetOrPut(module, @[]).add (remapSym(sym), info)
  for id, effects in job.context.sideEffects:
    for (info, sym) in effects:
      c.sideEffects.mgetOrPut(symIds.getOrDefault(id, id), @[]).add (info, remapSym(sym))
  c.config.hintCounter += job.context.config.hintCounter
  c.config.warnCounter += job.context.config.warnCounter
  if job.output.len > 0: msgs.msgWriteln(c.config, job.output.strip(leading = false))
  let key = c.bodyTasks[index].key
  c.bodyTasks[index] = BodyTask(key: key, state: btDone, owner: owner, def: owner.ast)

proc disposeBody(job: ptr IsolatedBody; b: var BodyCloner; keepResult: bool) =
  # Clones never enter the module arena. Break their cycles only after every
  # retained result reference has been rebound to the original declaration.
  if job != nil:
    if not keepResult:
      for typ in job.types: reset(typ[])
      for sym in job.syms: reset(sym[])
    reset(job[])
    deallocShared(job)
  for key, typ in b.types: reset(typ[])
  for key, sym in b.syms: reset(sym[])
  reset(b)

proc parallelBodyBatch(c: PContext; first: int): int =
  if c.config.errorCounter != 0: return 0
  bodyDecision(c.module.name.s, c.bodyTasks[first].key, "fewer than two spare workers")
  # The module waits for its children. Offloading just one body would add
  # copying and scheduling without overlapping any work from this module.
  if not currentBodyPool.tryOccupy(2): return 0
  var reserved = 2
  var jobs: seq[ptr IsolatedBody]
  var clones: seq[BodyCloner]
  var tickets: seq[BodyTicket]
  var keep: seq[bool]
  var joined = 0
  # Construct all inputs before executing any. Their identity maps contain
  # original references and remain exclusively on this waiting module thread.
  try:
    # Check for a second syntactically eligible body before paying for the
    # first one's declaration graph. Small wrappers commonly separate the
    # larger procedures in real modules.
    if not bodyCandidate(c, first): return 0
    if first + 1 >= c.bodyTasks.len or not bodyCandidate(c, first + 1):
      bodyDecision(c.module.name.s, c.bodyTasks[first].key, "no ready sibling")
      return 0
    while first + jobs.len < c.bodyTasks.len:
      if reserved == 0:
        if not currentBodyPool.tryOccupy(): break
        reserved = 1
      dec reserved
      var clone: BodyCloner
      var job: ptr IsolatedBody
      try:
        try:
          job = prepareIsolatedBody(c, first + jobs.len, clone)
        except BodyNotIsolated:
          bodyDecision(c.module.name.s, c.bodyTasks[first + jobs.len].key,
            "clone:" & getCurrentExceptionMsg())
      finally:
        if job == nil:
          disposeBody(nil, clone, false)
          currentBodyPool.release()
      if job == nil: break
      jobs.add job
      clones.add move(clone)
      keep.add false
    while reserved > 0:
      currentBodyPool.release()
      dec reserved
    if jobs.len < 2:
      if jobs.len == 1:
        bodyDecision(c.module.name.s, c.bodyTasks[first].key, "no ready sibling")
      return 0
    for job in jobs: tickets.add currentBodyPool.submitBody(job, executeIsolatedBody)
    while joined < tickets.len:
      tickets[joined].joinBody()
      inc joined
    # Source-order merge makes symbol IDs, diagnostics and inferred effects
    # independent of worker completion order.
    for i, job in jobs:
      if job.failed:
        bodyDecision(c.module.name.s, c.bodyTasks[first + i].key, "worker fallback")
        runBodyTask(c, first + i)
      else:
        mergeIsolatedBody(c, first + i, job, clones[i])
        keep[i] = true
      if c.config.isDefined("icProfile"):
        msgs.msgWriteln(c.config, "ICBODY " & $(%*{"module": c.module.name.s,
          "routine": c.bodyTasks[first + i].owner.name.s, "thread": job.thread,
          "prepareNs": job.prepareNs, "symbols": clones[i].syms.len,
          "types": clones[i].types.len,
          "startNs": job.started, "endNs": job.finished, "fallback": job.failed,
          "failure": job.failure}))
  finally:
    while reserved > 0:
      currentBodyPool.release()
      dec reserved
    while joined < tickets.len:
      tickets[joined].joinBody()
      inc joined
    for i in tickets.len ..< jobs.len: currentBodyPool.release()
    for i, job in jobs:
      disposeBody(job, clones[i], keep[i])
  while c.nextBodyTask < c.bodyTasks.len and c.bodyTasks[c.nextBodyTask].state == btDone:
    inc c.nextBodyTask
  result = jobs.len

{.pop.}
