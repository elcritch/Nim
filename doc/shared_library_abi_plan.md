# Nim Shared Library ABI Plan

## Progress Checklist

### Milestone 1: Mangled Export Prototype

- [x] Add a dedicated Nim ABI export mode for C backend procs.
- [x] Export overloaded procs with distinct signature-mangled symbols.
- [x] Export concrete generic instantiations with distinct signature-mangled symbols.
- [x] Add codegen coverage that checks generated exported symbols.

### Milestone 2: Opaque Ref Object Handles and Accessors

- [ ] Classify exported `ref object` types as opaque ABI handles.
- [ ] Generate producer-side accessor exports for public fields on opaque refs.
- [ ] Generate importer-side wrapper accessors so public fields remain source-level ergonomic.
- [ ] Define accessor return policy for POD values, managed copies, borrowed views, and nested handles.
- [ ] Keep allocation, destruction, ARC retain/release, managed fields, and invariants inside the producer library.
- [ ] Require exported constructor, accessor, and destructor or retain/release procs for handle-backed APIs.
- [ ] Reject direct cross-library layout access and unsupported accessor shapes with clear diagnostics.
- [ ] Add tests for opaque handle signatures and rejection paths.

### Milestone 3: Explicit Init and Metadata

- [ ] Generate ABI metadata for compiler, target, backend, memory manager, allocator, flags, proc signatures, opaque handle identities, and accessor return modes.
- [ ] Generate explicit `nimAbiInit` entry point.
- [ ] Suppress automatic shared-library constructors for explicit-init builds.
- [ ] Add ABI mismatch diagnostics and tests.

### Milestone 4: ABI-POD and Plain Object Layout

- [ ] Emit layout metadata for exported ABI-POD and supported plain object value types.
- [ ] Check size, alignment, field offsets, and layout hashes.
- [ ] Support ABI-POD structs by value.
- [ ] Reject unsupported object layouts with clear diagnostics.

### Milestone 5: Importer Integration

- [ ] Generate or support importer-side ABI expectations.
- [ ] Bind mangled proc symbols only after ABI validation.
- [ ] Support high-level wrapper types over opaque handles.
- [ ] Add end-to-end shared-library tests.

### Milestone 6: Transparent Managed Types

- [ ] Allow managed plain object fields under strict ABI match.
- [ ] Validate type hook hashes and managed runtime assumptions.
- [ ] Add ARC and atomicArc coverage.
- [ ] Revisit transparent `ref object` access as an advanced opt-in mode.

### Milestone 7: Exported Hooks Follow-Up

- [ ] Re-evaluate exported lifecycle hooks after opaque handles and strict same-runtime ABI work.
- [ ] Export lifecycle hooks where cross-build compatibility or plugin isolation requires it.

## Goal

Add a compiler-supported Nim-to-Nim shared library ABI for the C backend that can export overloaded procs, concrete generic instantiations, high-level Nim types, and module initialization in a checked way.

The initial implementation assumes both the producer library and the consumer are compiled with matching Nim compiler/runtime settings. It starts with opaque `ref object` handles so the producer library owns internal object layout, lifetime, hooks, managed fields, and invariants. Generated accessors provide field-like Nim ergonomics without exposing object layout. Transparent `ref object` layout access is deferred to a later advanced mode.

## Non-Goals for the Initial Version

- Do not define a stable ABI across arbitrary Nim compiler versions.
- Do not support mismatched memory managers, allocators, backends, or target ABIs.
- Do not make the ABI safe for direct C mutation of Nim-managed fields.
- Do not expose layout-transparent `ref object` field access in the first implementation.
- Do not make the importer responsible for internal `ref object` allocation, destruction, or custom hooks.
- Do not support every field type through generated accessors initially; reject unsupported shapes instead.
- Do not export open-ended generics. Only concrete generic instantiations are exported.
- Do not support exceptions crossing the shared library boundary until there is an explicit exception ABI contract.
- Do not support ORC in the first implementation. Start with ARC and atomicArc.

## ABI Model Options

There are two viable ownership/runtime models.

### Option 1: Same Type Definitions and Runtime

Both sides compile the same public type definitions and use the same runtime, allocator, backend, target ABI, and relevant compiler flags.

For transparent value types, this allows the importer to compile normal Nim field access, constructors, destructors, copies, sinks, and managed-field assignments using the same compiler logic as the library.

The library still exports ABI metadata so the importer can reject a mismatch before using any exported symbol.

This remains the initial runtime assumption for exported procs, ABI-POD values, and wrapper code. It is not used to justify transparent `ref object` internals in the first version.

### Option 2: Exported Lifecycle Hooks

The library exports lifecycle hooks for every exported managed type, and the importer uses those imported hooks instead of locally compiled hooks.

Required hooks include destroy, copy, sink, duplicate, default initialization, and possibly field-level assignment helpers for managed fields.

This model is more robust across compiler/runtime differences, but it is substantially more work. It is a later-stage design unless Option 1 proves too fragile.

## `ref object` Options

There are also two viable `ref object` exposure models.

### Option A: Opaque Handle

The caller receives an opaque handle and only retains, releases, or calls methods through exported hooks.

This is the easiest and safest model. It is close to what C-style bindings and tools like Genny generate today. The ABI representation can be modeled as:

```nim
type RendererHandle = distinct pointer
```

or effectively:

```nim
type RendererHandle = ptr OpaqueRenderer
```

The library owns:

- Allocation.
- Destruction.
- ARC retain/release behavior.
- Field layout.
- Custom hooks.
- Managed fields such as `string`, `seq`, and `ref`.
- Object invariants.
- Thread-affinity checks.

It keeps object layout private and avoids direct caller mutation of managed fields.

The importer only calls exported procs:

```nim
let r = newRenderer()
draw(r)
rendererUnref(r)
```

This is the initial plan for `ref object` values.

### Option A Plus Generated Accessors

Opaque handles do not have to mean a low-level public API. For exported `ref object` fields, the producer can synthesize ABI exports:

```nim
type
  Renderer* = ref object
    name*: string
    size*: Vec2
    scale*: float32

proc `name`*(r: Renderer): string {.exportnimabi.}
proc `name=`*(r: Renderer; value: string) {.exportnimabi.}

proc `size`*(r: Renderer): Vec2 {.exportnimabi.}
proc `size=`*(r: Renderer; value: Vec2) {.exportnimabi.}
```

The importer represents the producer object as a handle-backed wrapper and forwards field-like calls:

```nim
type
  Renderer* = ref object
    handle: RendererHandle

proc name*(r: Renderer): string =
  imported_renderer_name(r.handle)

proc `name=`*(r: Renderer; value: string) =
  imported_renderer_set_name(r.handle, value)
```

This gives most of the ergonomics of transparent field access while keeping object layout, managed assignment, custom hooks, and invariants inside the producer library. ABI metadata needs accessor signatures and return policy, not field offsets for opaque refs.

### Option B: Transparent Ref Object

The caller can dereference fields directly.

This is possible only when both sides use the same compiler, flags, target ABI, layout hash, memory manager, allocator contract, and runtime configuration.

Every managed field access must be compiled by Nim so ARC or atomicArc inserts the correct copies, sinks, assignments, and destroys.

Custom hooks make this especially sharp: the importer either needs to compile identical hooks or call hooks exported by the producer library. Once hooks are imported, the design has moved toward the exported-lifecycle-hook model.

This is a later advanced mode, not the first implementation.

## Initial Scope

The first version targets this combination:

- Option 1: same compiler/runtime/allocator contract for exported procs and supported value types.
- Option A: opaque `ref object` handles.
- Generated accessors for supported public fields on opaque `ref object` types.
- Transparent access only for supported plain object values, starting with ABI-POD structs.
- No transparent cross-library `ref object` layout access.
- C backend only.
- ARC or atomicArc only.
- Explicit shared-library initialization.
- Itanium-style exported names for overloads and concrete generic instantiations.
- ABI metadata checked before any exported API use.
- Clear diagnostics for missing lifetime/accessor procs or unsupported direct layout access.

The compiler should reject unsupported signatures instead of silently exporting an unsafe ABI.

## ABI Compatibility Requirements

The producer and consumer must match on:

- Nim compiler version and compiler build hash.
- C backend.
- Target OS, CPU, ABI family, pointer size, and integer sizes.
- C compiler ABI family where observable.
- Memory manager: ARC or atomicArc.
- Threading mode and TLS configuration.
- Allocator/runtime configuration.
- Relevant compile-time defines that affect exported type layout or behavior.
- Exported ABI-POD and supported plain object layout hashes.
- Opaque handle type identities and ownership protocol.
- Generated accessor signatures and return modes.
- Exported proc signature hashes.
- Calling convention.

The ABI check should prefer a single computed ABI fingerprint, but the metadata should also expose enough structured fields for diagnostics. Opaque `ref object` internals do not require importer-visible field layout or hook hashes in the first implementation because the producer library owns those operations. Public field compatibility is represented by generated accessor signatures and their return policies.

## Explicit Initialization

Shared libraries must export a generated initialization proc, for example:

```nim
proc nimAbiInit(expected: ptr NimAbiExpected): NimAbiInitResult {.cdecl, exportc, dynlib.}
```

This proc must:

1. Check the consumer-provided ABI expectations against the library metadata.
2. Return a structured mismatch error before any runtime-dependent use.
3. Call `NimMain` exactly once on success.
4. Run any user-declared library initialization code.
5. Mark the library initialized.

The compiler should support suppressing automatic shared-library constructors so initialization is explicit. Existing `--noMain:on` behavior is a useful starting point because it still emits `NimMain` while omitting the shared-library constructor.

An optional generated shutdown proc can call `NimDestroyGlobals`, but only after the design accounts for outstanding exported refs and global object lifetime.

## Exported Symbol Naming

The compiler already has Itanium-style name mangling for debug-oriented names. The shared ABI should reuse or extend that machinery for exported Nim ABI symbols.

Requirements:

- Exported overloads must get distinct symbols.
- Concrete generic instantiations must get distinct symbols.
- Module and type identity must be encoded in the name or ABI metadata.
- The ABI should not require manually written `{.exportc: "...".}` names.

Current compiler behavior routes `{.exportc.}` through an explicit backend name, which bypasses the mangled-name path. A new pragma or export mode is needed instead of reusing plain `exportc` unchanged.

Possible spelling:

```nim
proc draw*(fig: Fig; box: ScreenBox) {.exportnimabi.}
```

or a module-level pragma that exports selected public symbols.

## Type Layout

For layout portions, use the platform C ABI where possible.

Plain object fields that lower to C-compatible fields can use C struct layout, including size, alignment, and field offsets.

The compiler must still record and check:

- Type size.
- Type alignment.
- Field order.
- Field offsets.
- Variant object layout.
- Packing/alignment pragmas.
- Object inheritance layout.
- Managed-field presence.

For opaque `ref object` types, the compiler must not expose the object layout to the importer. Metadata should record the handle representation, type identity, ownership protocol, and proc signatures that operate on the handle. Internal fields, custom hooks, managed fields, and invariants remain producer-owned.

For transparent managed values, layout compatibility is not enough. The importing side must compile all reads, writes, copies, moves, and destruction with matching Nim semantics. This is deferred until after opaque handles and ABI-POD values work.

## Generated Ref Accessors

For opaque `ref object` types, public fields can be projected through generated accessor exports instead of exposing field offsets. This is the middle ground for the first implementation: object layout stays private, but Nim callers keep property-style source ergonomics.

Accessor metadata should classify each generated accessor:

```nim
type
  AccessorMode = enum
    abiPodValue       # plain value
    abiManagedCopy    # Nim-managed copy, same-runtime only
    abiBorrowed       # lent/read-only view, short lifetime
    abiHandle         # opaque ref handle
```

Initial accessor support should allow:

- `abiPodValue` get/set for plain fields.
- `abiHandle` get/set for `ref object` fields through retain/release rules.
- `abiManagedCopy` get/set for `string` under the strict same-runtime ABI check.

Initial accessor support should reject or require an explicit future annotation for:

- `seq[T]`.
- `lent T`.
- `var T`.
- `openArray[T]`.
- Closure fields.
- Any field whose copy, borrow, or lifetime cannot be described by the current metadata.

For `abiHandle` getters, the initial policy should return a retained handle so the importer wrapper can own and release it predictably. Setters should run inside the producer library so managed assignment, old-value release, custom hooks, and invariants remain producer-owned.

## Constructors and Destructors

High-level Nim constructors are allowed in the initial design, but `ref object` results cross the ABI as opaque handles.

Examples:

```nim
proc initFont*(name: string; size: float32): Font {.exportnimabi.}
proc newRenderer*(target: ref Window): ref Renderer {.exportnimabi.}
```

The producer library must also expose an ownership path for handles, such as:

```nim
proc rendererRef*(r: ref Renderer): ref Renderer {.exportnimabi.}
proc rendererUnref*(r: ref Renderer) {.exportnimabi.}
```

or a single destroy/free proc when the handle is uniquely owned.

The importer can still expose a high-level Nim wrapper:

```nim
type Renderer* = ref object
  handle: RendererHandle

proc draw*(r: Renderer)
proc name*(r: Renderer): string
proc `name=`*(r: Renderer; value: string)
proc size*(r: Renderer): Vec2
proc `size=`*(r: Renderer; value: Vec2)
```

The wrapper forwards constructors, operations, getters, and setters to exported library procs. It does not dereference the producer's `Renderer` object layout.

Returned managed value types must be destroyed by Nim code compiled under the same ABI contract. Direct C callers are not part of the initial high-level ABI.

Generated ABI metadata should include type hook identities or hashes for:

- `=destroy`
- `=copy`
- `=sink`
- `=dup`, if relevant
- assignment behavior for managed fields

The initial implementation may validate hook hashes for transparent value types without exporting hooks. Opaque `ref object` internals do not need importer-visible hook hashes. Exported hooks belong to Option 2.

## Field Access Rules

Layout-transparent field access is allowed only for supported value types in Nim consumers that passed the ABI check.

Opaque `ref object` layout access is not allowed across the ABI boundary. Public field syntax can still be supported by generated getter and setter wrappers:

```nim
r.name = "main"
let s = r.size
```

which lowers to calls such as:

```nim
rendererSetName(r.handle, "main")
rendererSize(r.handle)
```

Direct C field access is only safe for ABI-POD fields and must not mutate Nim-managed fields.

For a transparent managed value type in a later milestone, this must be compiled by Nim:

```nim
obj.name = "Inter"
```

because it may need to release the old `string`, copy or sink the new `string`, and update ARC state.

The compiler should classify exported types:

- `AbiPod`: C-compatible by-value layout and no Nim-managed fields.
- `AbiOpaqueRef`: handle identity only; producer owns allocation, layout, hooks, and managed fields.
- `AbiAccessor`: generated getter/setter surface over an opaque ref field, with an explicit `AccessorMode`.
- `AbiManagedValue`: layout can be checked, but Nim-managed operations are required.
- `AbiRefTransparent`: transparent `ref object` allowed under strict ABI match in a later opt-in mode.
- `AbiUnsupported`: rejected with a diagnostic.

## Generic Support

Only concrete instantiated symbols are exported.

For example:

```nim
proc get*[T](box: Box[T]): T {.exportnimabi.}

discard get(Box[int]())
discard get(Box[string]())
```

may export concrete `get(Box[int])` and `get(Box[string])` symbols.

The compiler should not promise that an importer can instantiate new generic combinations against an already-built shared library unless the library explicitly exports those instantiations.

Generic type layout metadata must be per-instantiation.

## Importer Behavior

A Nim importer module should:

1. Load or link the shared library.
2. Read exported ABI metadata.
3. Construct expected ABI metadata from the importing compilation.
4. Call `nimAbiInit`.
5. Bind mangled proc symbols only after successful initialization.
6. Compile high-level calls normally after validation.
7. Represent producer `ref object` values as opaque handles.
8. Generate or import wrapper accessors that route field-like APIs through exported getters, setters, and operations.

The first implementation can require an explicit user call such as:

```nim
initFigdrawAbi()
```

Automatic module-init loading can come later after failure reporting and load order are designed.

## Compiler Implementation Areas

Likely compiler areas:

- Add a new exported-Nim-ABI pragma or module-level mode.
- Track ABI-exported symbols separately from `exportc`.
- Reuse or extend the Itanium-style mangling path for exported symbols.
- Collect concrete exported generic instantiations.
- Classify ABI-visible types into opaque handles, ABI-POD values, managed values, and unsupported forms.
- Generate and consume opaque handle identity metadata.
- Generate producer-side accessor exports for supported public fields on opaque refs.
- Generate or support importer-side wrapper accessors over opaque handles.
- Classify accessor return policy as POD value, managed copy, borrowed view, or handle.
- Generate structured ABI metadata.
- Compute type layout and signature hashes.
- Generate explicit init and optional shutdown symbols.
- Suppress automatic shared-library constructors for explicit-init builds.
- Generate or support importer-side ABI expectations.
- Add diagnostics for unsupported exported signatures, unsupported accessor shapes, and direct layout access into opaque refs.

Relevant existing compiler machinery:

- Name mangling and backend names in `compiler/ccgtypes.nim`.
- Type encoding for mangled names in `compiler/ccgutils.nim`.
- Dynamic library pragmas in `compiler/pragmas.nim`.
- Shared-library `NimMain` generation in `compiler/cgen.nim`.
- GC mode/options in `compiler/options.nim`.
- Type/proc hashes in `compiler/sighashes.nim`.
- Size, alignment, and layout computation in `compiler/types.nim` and `compiler/sizealignoffsetimpl.nim`.

## Milestones

### Milestone 1: Mangled Export Prototype

- Add an export mode that marks procs as shared Nim ABI exports without forcing a manual C name.
- Export overloaded procs with distinct mangled symbols.
- Export concrete generic instantiations with distinct mangled symbols.
- Add compile tests that inspect generated symbols.

### Milestone 2: Opaque Ref Object Handles and Accessors

- Classify exported `ref object` types as opaque handles.
- Define the ABI representation for handles, such as `distinct pointer` or `ptr OpaqueType`.
- Generate producer-side getter/setter exports for supported public fields.
- Generate importer-side wrapper accessors so callers can keep property-style source code.
- Define accessor return modes: POD value, managed copy, borrowed view, and handle.
- Require a producer-owned lifetime path: constructor plus destroy, or retain plus release.
- Reject direct imported layout access into opaque refs.
- Reject unsupported accessor shapes with clear diagnostics.
- Add focused diagnostics and tests.

### Milestone 3: Explicit Init and Metadata

- Generate ABI metadata for compiler version, target, backend, memory manager, allocator, flags, proc signatures, opaque handle identities, and accessor return modes.
- Generate `nimAbiInit`.
- Suppress automatic shared-library constructor when explicit init is enabled.
- Call `NimMain` exactly once from `nimAbiInit`.
- Add mismatch tests.

### Milestone 4: ABI-POD and Plain Object Layout

- Emit layout metadata for ABI-POD and supported plain object value types.
- Check size, alignment, field offsets, and layout hashes.
- Support ABI-POD structs by value.
- Reject unsupported object layouts with clear diagnostics.

### Milestone 5: Importer Integration

- Generate or support importer-side metadata expectations.
- Provide explicit initialization API for linked or dynamically loaded libraries.
- Ensure high-level calls use mangled symbols after ABI validation.
- Generate or support wrapper types and accessor procs over opaque handles.
- Add end-to-end shared-library tests.

### Milestone 6: Transparent Managed Types

- Allow managed plain object fields under strict ABI match.
- Validate type hook hashes.
- Validate `string`, `seq`, and `ref` layout/runtime assumptions.
- Add ARC and atomicArc test matrices.
- Revisit transparent `ref object` access as a strict opt-in mode.

### Milestone 7: Revisit Exported Hooks

- Evaluate Option 2 after opaque handles and the strict same-runtime model work.
- Export lifecycle hooks where cross-build compatibility or plugin isolation requires it.

## Risks

- Nim runtime initialization order may be fragile if callers use exported symbols before `nimAbiInit`.
- Opaque handles need a clear ownership protocol or wrappers can leak handles or release them too early.
- Wrapper hooks for handle-backed types must be designed carefully so importer-side ARC does not imply ownership of producer internals.
- Accessor return policy must be explicit; managed copies, borrowed views, and nested handles have different lifetime rules.
- `string` accessors are feasible under the strict same-runtime ABI, but `seq`, `lent`, `var`, `openArray`, and closure-shaped fields should stay rejected until their ownership rules are specified.
- Transparent `ref object` access remains dangerous because layout and hook mismatches can corrupt memory.
- Compile-time defines can affect type layout or proc bodies in ways that are hard to fingerprint completely.
- AtomicArc may be required for cross-thread sharing even when ARC passes ABI checks.
- Shutdown semantics are difficult if exported refs outlive the library or if globals depend on external resources.
- The C backend may emit ABI-relevant details that vary by C compiler and platform.

## Recommended First Target

Use a small shared library test case with:

- Two overloaded exported procs.
- One concrete generic proc instantiated for two types.
- One ABI-POD object passed by value.
- One opaque `ref object` with public `string`, POD, and nested opaque-ref fields.
- One constructor returning the opaque handle.
- Generated getters, setters, and operations for that handle.
- A string accessor using managed-copy same-runtime semantics.
- A nested handle accessor using retain/release semantics.
- One explicit destroy or retain/release path exercised by ARC-backed wrapper code.
- A rejected direct layout-access case for the opaque ref.
- Rejected `seq`, `lent`, `var`, `openArray`, or closure field accessors.
- Explicit `nimAbiInit`.
- A forced ABI mismatch test.

This exercises the core feature without starting from a large real-world binding generator.
