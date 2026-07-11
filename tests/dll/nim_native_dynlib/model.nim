type
  NativeTypeKind* = enum
    ntObject
    ntRefObject

  NativeField* = object
    name*: string
    typeSymbol*: string
    exported*: bool

  NativeType* = object
    name*: string
    nifSymbol*: string
    typeId*: string
    kind*: NativeTypeKind
    fields*: seq[NativeField]

  NativeParam* = object
    name*: string
    typeSymbol*: string

  NativeProc* = object
    name*: string
    nifSymbol*: string
    cSymbol*: string
    returnTypeSymbol*: string
    params*: seq[NativeParam]

  NativeModule* = object
    identity*: string
    name*: string

  NativeApi* = object
    libraryName*: string
    compilerVersion*: string
    targetOS*: string
    targetCPU*: string
    memoryManager*: string
    allocator*: string
    modules*: seq[NativeModule]
    types*: seq[NativeType]
    procs*: seq[NativeProc]
