# Nim Shared Library ABI Plan

## Progress Checklist

### Milestone 1: Mangled Export Prototype

- [x] Add a dedicated Nim ABI export mode for C backend procs.
- [x] Export overloaded procs with distinct signature-mangled symbols.
- [x] Export concrete generic instantiations with distinct signature-mangled symbols.
- [x] Add codegen coverage that checks generated exported symbols.

### Milestone 2: Generated Nim ABI Module and C Layout Header

- [x] Emit a generated Nim ABI module for ABI-visible types, imported procs, and init.
- [x] Emit a compiler-generated C header for ABI-visible types and procs.
- [x] Have the generated Nim ABI module import or reference the generated C header for backend layout.
- [x] Emit transparent `object` and `ref object` payload declarations in the header.
- [x] Emit ABI-visible runtime representation declarations needed by those types.
- [x] Rely on the C compiler and platform C ABI for `sizeof`, alignment, and field offsets from that header.
- [x] Emit layout constants and compile-time C assertions for diagnostics.
- [x] Record the header hash and layout fingerprints in ABI metadata.
- [x] Emit hook wrappers in the generated Nim ABI module.

### Milestone 3: ARC Hook Wrappers

- [x] Let ordinary Nim ARC lowering perform managed field reads, writes, copies, sinks, and destruction.
- [x] Generate producer-side exported hook thunks that wrap user-defined custom hooks.
- [x] Generate importer-side attached hooks that forward to imported producer hook thunks.
- [x] Generate unavailable `{.error.}` hooks for no-copy operations.
- [x] Use local compiler-generated hooks when they are valid under the ABI check.
- [x] Reject signatures that require unavailable or unsupported hooks.

### Milestone 4: Transparent Ref Object Prototype

- [ ] Support transparent `ref object` layout access after ABI validation.
- [ ] Check ref payload size, alignment, field offsets, inheritance, discriminants, and managed-field layout.
- [ ] Allow Nim-compiled public field reads and writes after the generated header and ABI metadata match.
- [ ] Reject unsupported direct field access from C for Nim-managed fields.
- [ ] Add tests for transparent refs with POD fields, `string` fields, nested refs, and custom hooks.

### Milestone 5: Explicit Init and Metadata Validation

- [ ] Generate ABI metadata for compiler, target, backend, memory manager, allocator, flags, Nim ABI module hash, C header hash, proc signatures, `sizeof`, alignment, offsets, and layout hashes.
- [ ] Generate explicit `nimAbiInit` entry point.
- [ ] Suppress automatic shared-library constructors for explicit-init builds.
- [ ] Bind mangled proc and hook symbols only after ABI validation.
- [ ] Add ABI mismatch diagnostics and tests.

### Milestone 6: Importer Integration

- [ ] Generate or support importer-side ABI expectations from generated Nim ABI modules plus generated C headers.
- [ ] Ensure generated hook wrappers attach before importer-side ARC lowering.
- [ ] Add end-to-end shared-library tests with direct field access.
- [ ] Add forced mismatch tests for layout, generated hook wrappers, compiler, allocator, and memory-manager differences.

### Milestone 7: Later Compatibility Modes

- [ ] Revisit `atomicArc` after ARC-only support is stable.
- [ ] Revisit ORC after trace metadata and cycle handling are designed.
- [ ] Revisit opaque handles and generated accessors as a separate opt-in isolation mode.
- [ ] Revisit broader cross-version compatibility after strict same-build metadata works.

## Goal

Add a compiler-supported Nim-to-Nim shared library ABI for the C backend that can export overloaded procs, concrete generic instantiations, high-level Nim types, transparent `ref object` layouts, ownership hooks, and module initialization in a checked way.

The initial implementation uses transparent refs instead of opaque handles. The producer library emits:

- Itanium-style mangled exported symbols.
- A generated Nim ABI module for Nim consumers.
- A generated C ABI header for exported types and procs.
- Structured ABI metadata for generated artifact hashes, proc signatures, type sizes, field offsets, and layout fingerprints.
- Explicit initialization and validation entry points.

The importer treats the generated Nim ABI module, generated C header, and metadata as the dynlib contract. The Nim ABI module gives the compiler real Nim declarations for type checking, field access, and hook attachment. The C header lets the C backend compile against the same physical type declarations, so the C compiler computes `sizeof`, alignment, and field offsets in the usual C ABI way. Metadata verifies that the loaded library matches those generated artifacts. After validation, the importer compiles ordinary Nim field access and ARC operations for exported transparent types.

## Non-Goals for the Initial Version

- Do not define a stable ABI across arbitrary Nim compiler versions.
- Do not support mismatched memory managers, allocators, C backends, target ABIs, or relevant compiler flags.
- Do not support ORC in the first implementation.
- Do not support `atomicArc` in the first implementation unless it is treated as a separate ABI mode.
- Do not make hand-written C headers part of the contract.
- Do not make direct C mutation of Nim-managed fields safe.
- Do not hide the layout of transparent exported refs; this mode deliberately exposes layout.
- Do not support exceptions crossing the shared library boundary until there is an explicit exception ABI contract.
- Do not export open-ended generics. Only concrete generic instantiations are exported.

## Initial Scope

The first version targets this combination:

- C backend only.
- ARC only.
- Explicit `nimAbiInit` before any exported Nim ABI use.
- Itanium-style exported names for overloads and concrete generic instantiations.
- Generated Nim ABI module for Nim consumers.
- Generated C ABI header for exported types and procs.
- Transparent `object` and `ref object` layout for supported types.
- `sizeof`, alignment, field offset, and layout-hash validation.
- Exported hook thunks for producer-owned custom hooks.
- Importer-side generated hook wrappers that attach those thunks to ABI-visible types.
- Generated `{.error.}` hooks for unavailable operations.
- Strict ABI metadata checks before binding proc or hook symbols.
- Clear diagnostics for unsupported layouts, unsupported hooks, stale headers, missing metadata, or unsafe direct C access.

This intentionally starts with the strict same-build model. The producer and importer must agree on the compiler build, C backend, target ABI, allocator/runtime configuration, ARC mode, type layouts, and hook behavior.

## ABI Model

### Transparent Same-Build ABI

Both sides use the same Nim compiler/runtime model and the same generated ABI contract. The generated Nim ABI module gives the importer Nim declarations for exported types, procs, and attached hooks. The generated C header gives the C backend declarations for exported layouts. The C compiler then handles layout exactly as it does for any C translation unit using that header. Metadata only checks that the Nim ABI module, C header, importer, and loaded producer library are the same ABI instance.

This allows the Nim importer to compile normal source-level operations:

```nim
let r = newRenderer()
r.name = "main"
draw(r)
```

The field assignment remains a Nim operation. ARC inserts the required copies, sinks, destroys, refcount operations, and hook calls. The ABI layer does not hand-roll managed access; it only proves that Nim's normal lowering is valid for the loaded library.

### Generated Hook Wrappers

For every ABI-visible managed type, the generated Nim ABI module encodes the hook behavior that ARC requires:

- Plain or auto-managed: emit no custom hook and let Nim generate the normal one.
- Custom producer-owned hook: emit an imported thunk plus an attached wrapper hook.
- No-copy operation: emit an unavailable `{.error.}` hook.
- Unsupported hook shape: reject while generating the ABI module.

Nim still performs ARC lowering normally. The ABI layer only makes sure the hooks that ARC calls are the right hooks.

For compiler-generated hooks over supported managed fields, the importer can usually use local generated hooks under the strict ABI check. For user-defined custom hooks, the producer should emit exported ABI thunks that wrap the actual hook implementation:

```nim
proc abiDestroyRendererObj(x: ptr RendererObj) {.exportnimabi.} =
  `=destroy`(x[])
```

The generated Nim ABI module then imports the thunk and defines the attached hook for the ABI type:

```nim
proc abiDestroyRendererObj(x: ptr RendererObj) {.importnimabi.}

proc `=destroy`(x: var RendererObj) =
  abiDestroyRendererObj(addr x)
```

The exact wrapper ABI is compiler-defined so it can avoid accidental copies. The generated Nim hook has a valid Nim hook signature and forwards to a pointer or otherwise ABI-safe thunk. The same pattern applies to `=copy`, `=sink`, `=dup`, and `=wasMoved` when those hooks are custom or producer-owned. A no-copy hook is represented as an importer-side `{.error.}` hook, not as a thunk.

Generated hook wrappers must preserve Nim hook semantics. In particular, they must use the correct Nim hook signatures, keep `=destroy` non-raising, and avoid raw whole-object moves or `copyMem` for `=sink` and `=dup`.

The generated Nim ABI module hash covers the hook wrappers, imported thunk symbols, and unavailable hook declarations. Metadata may mirror hook decisions for diagnostics, but it is not the source of truth.

## Current Milestone 2 Artifact Emission

Producer-side artifact emission now exists for `{.exportnimabi.}` with the C backend.

For a project named `figdraw.nim`, the compiler emits these files in the nimcache:

- `figdraw_abi.nim`: generated Nim ABI module.
- `figdraw.abi.h`: generated C layout header.
- `figdraw.abi.json`: generated ABI metadata.

The generated Nim ABI module currently contains:

- ABI-visible transparent object declarations.
- Transparent `ref object` aliases through generated payload object declarations.
- Imported exported procs using the final Itanium-style backend symbols.
- An imported `NimMain` init declaration.
- `importc`/`header` annotations that make generated C include the generated ABI C header for layout.
- Attached hook wrappers named with the normal Nim hook names, such as `=destroy` and `=copy`, for custom producer hooks and unavailable hooks.

The generated C header currently contains:

- Nim C prelude defines needed by `nimbase.h`.
- ABI-visible runtime representation declarations emitted from the backend type sections.
- Transparent object and ref payload declarations using module-qualified Itanium-style C identifiers.
- Proc prototypes using final module-qualified Itanium-style backend names.
- A `NimMain` prototype.
- `sizeof`, alignment, field-offset constants, and `sizeof`/`offsetof` compile-time assertions.
- A generated marker define so importer diagnostics can distinguish compiler-generated headers from ordinary hand-written headers.

The generated metadata currently contains:

- Generated Nim ABI module path.
- Generated C header path.
- Generated C header hash.
- Init symbol.
- Type `sizeof`, alignment, and layout fingerprints.
- Proc symbols and signature fingerprints.

This is still producer-side artifact emission only. Importer-side validation, stale-header rejection, broader hook coverage, and explicit `nimAbiInit` metadata negotiation remain to be implemented.

## Generated Nim ABI Module

The generated Nim ABI module is the primary header for Nim consumers. User code imports this module instead of redeclaring lookalike types:

```nim
import figdraw_abi

let r = newRenderer("main")
r.name = "overlay"
draw(r)
```

The module should contain:

- ABI-visible Nim type declarations.
- Field visibility and privacy information through normal Nim declarations.
- Imports or annotations that make the C backend use the generated C layout header.
- Imported proc declarations using final mangled ABI symbols.
- Imported hook thunk declarations.
- Generated attached hook wrappers for producer-owned custom hooks.
- Unavailable `{.error.}` hooks for no-copy or otherwise rejected ownership operations.
- ABI init and metadata declarations.
- A module/header fingerprint used by `nimAbiInit`.

For layout, the generated Nim ABI module can use `importc`, `header`, or an equivalent ABI-specific pragma so emitted C refers to the generated C struct declarations:

```nim
type
  RendererObj* {.importc: "NimAbi_RendererObj", header: "figdraw_abi.h".} = object
    name*: string
    size*: Vec2

  Renderer* = ref RendererObj
```

This is a layout bridge, not a replacement for Nim semantics. The Nim ABI module still provides the canonical Nim type identity, attached hooks, visibility, overload surface, and ABI metadata. The C header supplies the physical layout used by the backend.

The compiler should reject or warn when an ABI-imported proc uses a local type that merely looks like an ABI type. ABI imports should use the canonical type declarations from the generated Nim ABI module so hook attachment and metadata validation apply to the same type identity.

Current status: the producer emits the generated Nim ABI module as `<project>_abi.nim`. Custom attached hooks are mirrored as normal Nim hook-name wrappers that forward to private generated imports of producer-side ABI hook thunks. Unavailable hooks are mirrored as `{.error.}` hooks. Importer-side validation helpers and stale-header diagnostics are not implemented yet.

## Generated C ABI Header

The generated header is a compiler artifact, not a stable human-maintained C API. It should be emitted next to the shared library and referenced by importer-side generated code or by an explicit import pragma.

The header should contain:

- Version and ABI fingerprint comments or constants.
- Runtime representation declarations needed by exported types.
- C declarations for transparent ABI-visible `object` payloads.
- C declarations for transparent ABI-visible `ref object` payloads.
- Optional layout constants for diagnostics: `sizeof`, alignment, field offsets, and layout hash.
- Optional static assertions such as `sizeof(T)`, `alignof(T)`, and `offsetof(T, field)` checks where the C compiler supports them.
- Proc prototypes using the final exported backend names.
- Hook thunk prototypes only for hooks that the importer may need to call.
- Type and proc identifiers that connect header declarations to structured metadata.

The header can expose private layout details because transparent mode is a same-build Nim ABI, not an encapsulation boundary. Nim source visibility rules still control which fields are accessible from Nim code through the generated Nim ABI module. The C header is the physical layout source the importing C compiler uses for local layout. For example, `sizeof(T)` and `offsetof(T, field)` come directly from compiling against this header.

The header alone is not the runtime trust boundary. C linkers resolve symbol names; they do not check that two shared objects used the same struct definitions. The producer should publish a compact layout fingerprint, and optionally structured `sizeof`, alignment, and offset values for diagnostics. The importer rejects a library if the loaded producer's metadata does not match the generated header it compiled against.

Current status: the producer emits the generated C ABI header as `<project>.abi.h`, including backend runtime declarations, module-qualified Itanium-style object payload declarations, proc prototypes, hook thunk prototypes, layout constants, and C compile-time assertions. Importer-side rejection of hand-written or stale headers is still pending.

## Transparent `ref object` Rules

An exported `ref object` is represented as a real Nim ref whose payload layout is visible through the generated C header and checked through metadata. It is not lowered to `distinct pointer` in the initial mode.

The producer and importer must agree on:

- Ref payload `sizeof` and alignment.
- Object header/runtime fields required by ARC.
- Field order, offsets, sizes, and alignment.
- Inheritance layout.
- Variant object discriminants and branch layouts.
- Packing and alignment pragmas.
- Managed-field representation.
- Type descriptor identity needed for ARC destruction.
- Generated Nim ABI module hook declarations for the payload type and any managed fields with custom hooks.

After validation, a Nim importer may read and write exported fields directly in source code. The resulting C code uses the generated layout, and Nim ARC uses the hook declarations from the generated Nim ABI module.

Direct C callers are more restricted. They may inspect or pass ABI-POD fields, but they must not mutate Nim-managed fields such as `string`, `seq`, `ref`, closures, or fields whose assignment depends on custom hooks.

## Plain Object and Value Rules

Plain `object` values can cross the boundary by value only when their layout and hook model are fully described.

Initial support should allow:

- ABI-POD structs by value.
- Plain objects with ARC-managed fields when the importer can validate or import all required hooks.
- `string` fields under the strict ARC same-build contract.
- Nested supported object values with recursive layout and generated hook wrappers where needed.

Initial support should reject:

- `seq[T]` unless its element type and sequence operations have explicit metadata.
- Closures.
- `lent T` and `var T` across the dynlib boundary.
- Types whose custom hook bodies cannot be matched or imported.
- Types whose copy behavior is marked unavailable but whose exported signatures require copying.

## Constructors, Destructors, and Allocation

Constructors can be exported normally and return transparent refs:

```nim
type
  Vec2* = object
    x*, y*: float32

  RendererObj* = object
    name*: string
    size*: Vec2

  Renderer* = ref RendererObj

proc newRenderer*(name: string): Renderer {.exportnimabi.}
proc draw*(r: Renderer) {.exportnimabi.}
```

The importer sees `Renderer` as a real ref type with a validated payload layout. It does not need a manual retain/release API for ordinary ARC ownership. ARC-generated code increments, decrements, copies, sinks, and destroys through the generated or local hook declarations in the Nim ABI module.

The producer must export hook thunks for custom behavior that cannot be safely regenerated in the importer. For example, a custom `=destroy` for `RendererObj` must be available if imported ARC code can drop the last reference.

Library shutdown is optional in the initial design. A generated shutdown proc must not run while exported refs or values owned by the library can still be live.

## ABI Compatibility Requirements

The producer and consumer must match on:

- Nim compiler version and compiler build hash.
- C backend.
- Target OS, CPU, ABI family, pointer size, and integer sizes.
- C compiler ABI family where observable.
- ARC memory manager mode.
- Threading mode and TLS configuration.
- Allocator/runtime configuration.
- Relevant compile-time defines that affect exported type layout or behavior.
- Generated Nim ABI module hash.
- Generated C header hash.
- Exported proc signature hashes.
- Type `sizeof`, alignment, field offsets, field sizes, discriminants, inheritance, and layout hashes.
- Managed runtime representation hashes for `string`, `ref`, and any supported managed aggregate.
- Calling convention.

The ABI check should prefer a single computed ABI fingerprint for fast rejection, but metadata should expose structured fields for diagnostics.

## Explicit Initialization

Shared libraries must export a generated initialization proc, for example:

```nim
proc nimAbiInit(expected: ptr NimAbiExpected): NimAbiInitResult {.cdecl, exportc, dynlib.}
```

This proc must:

1. Check the consumer-provided ABI expectations against the library metadata.
2. Check the generated Nim ABI module hash.
3. Check the generated C header hash.
4. Check `sizeof`, alignment, field offsets, and layout hashes before any imported ARC operation can run.
5. Return a structured mismatch error before any runtime-dependent use.
6. Call `NimMain` exactly once on success.
7. Run any user-declared library initialization code.
8. Mark the library initialized.

The compiler should support suppressing automatic shared-library constructors so initialization is explicit. Existing `--noMain:on` behavior is a useful starting point because it still emits `NimMain` while omitting the shared-library constructor.

## Exported Symbol Naming

The compiler already has Itanium-style name mangling for debug-oriented names. The shared ABI should reuse or extend that machinery for exported Nim ABI symbols.

Requirements:

- Exported overloads must get distinct symbols.
- Concrete generic instantiations must get distinct symbols.
- Hook thunks must get distinct symbols.
- Module and type identity must be encoded in the name or ABI metadata.
- The ABI should not require manually written `{.exportc: "...".}` names.

Current compiler behavior routes `{.exportc.}` through an explicit backend name, which bypasses the mangled-name path. A new pragma or export mode is needed instead of reusing plain `exportc` unchanged.

Possible spelling:

```nim
proc draw*(fig: Fig; box: ScreenBox) {.exportnimabi.}
```

or a module-level pragma that exports selected public symbols.

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

Generic type layout metadata and generated hook declarations must be per instantiation.

## Importer Behavior

A Nim importer module should:

1. Load or link the shared library.
2. Import the generated Nim ABI module.
3. Have generated backend code include or reference the generated C ABI header.
4. Construct expected ABI metadata from the generated Nim module, importing compilation, and header-derived C layout constants.
5. Call `nimAbiInit`.
6. Reject the library if metadata, `sizeof`, alignment, offsets, Nim module hash, or C header hash mismatch.
7. Bind mangled proc and hook symbols only after successful validation.
8. Compile high-level Nim calls, field access, and ARC lowering against the validated transparent layout.
9. Use generated attached hooks for producer-owned custom hooks and normal local ARC hooks for compatible compiler-generated hooks.

The first implementation can require an explicit user call such as:

```nim
initFigdrawAbi()
```

Automatic module-init loading can come later after failure reporting and load order are designed.

## Compiler Implementation Areas

Likely compiler areas:

- Add a new exported-Nim-ABI pragma or module-level mode. Current status: proc-level `{.exportnimabi.}` exists.
- Track ABI-exported symbols separately from `exportc`. Current status: the C backend records ABI-exported procs during backend name finalization.
- Reuse or extend the Itanium-style mangling path for exported symbols. Current status: exported Nim ABI procs use signature-mangled symbols.
- Collect concrete exported generic instantiations. Current status: concrete exported instantiations are recorded when their backend names are finalized.
- Emit generated Nim ABI modules for Nim consumers. Current status: producer-side `<project>_abi.nim` is emitted.
- Emit generated C ABI headers for exported types, layout constants, procs, and any required hook thunks. Current status: producer-side `<project>.abi.h` is emitted for types, layout constants, procs, init, and hook thunk prototypes.
- Classify ABI-visible types into transparent refs, transparent values, ABI-POD values, and unsupported forms.
- Compute `sizeof`, alignment, field offsets, field sizes, and layout hashes for transparent `object` and `ref object` payloads. Current status: `sizeof`, alignment, field offsets, and layout fingerprints are emitted for supported generated objects.
- Export producer-side hook thunks for user-defined custom hooks. Current status: custom attached hooks for ABI-visible object payloads remain private and producer-side exported ABI thunks wrap them.
- Generate importer-side attached hook wrappers that forward to imported hook thunks. Current status: the generated Nim ABI module emits normal hook-name wrappers for custom hooks, imports producer-side ABI thunks, and emits `{.error.}` declarations for unavailable hooks.
- Generate structured ABI metadata. Current status: producer-side `<project>.abi.json` is emitted with header hash, init symbol, type layout data, and proc signature fingerprints.
- Generate explicit init and optional shutdown symbols.
- Suppress automatic shared-library constructors for explicit-init builds.
- Generate or support importer-side ABI expectations.
- Add or extend `importabi`/`importnimabi` handling so imported hook declarations attach before ARC lowering.
- Add diagnostics for unsupported exported signatures, unsupported layouts, missing hooks, no-copy violations, stale headers, and unsafe C field access.

Relevant existing compiler machinery:

- Name mangling and backend names in `compiler/ccgtypes.nim`.
- Type encoding for mangled names in `compiler/ccgutils.nim`.
- Dynamic library pragmas in `compiler/pragmas.nim`.
- Shared-library `NimMain` generation in `compiler/cgen.nim`.
- GC mode/options in `compiler/options.nim`.
- Type/proc hashes in `compiler/sighashes.nim`.
- Size, alignment, and layout computation in `compiler/types.nim` and `compiler/sizealignoffsetimpl.nim`.
- ARC hook generation and lowering in the semantic and C backend pipeline.

## Risks

- Transparent refs expose layout, so this mode is not an encapsulation boundary.
- Generated hook wrappers are critical; a layout match is unsafe if copy, sink, or destroy semantics are forwarded incorrectly.
- Imported ARC code may drop the last reference, so finalization must be validated and callable.
- Nim ABI module generation must describe compiler-generated, unavailable, and user-defined hook paths correctly.
- Compile-time defines can affect type layout or proc bodies in ways that are hard to fingerprint completely.
- Direct C callers can corrupt Nim-managed fields if they bypass Nim assignment semantics.
- Runtime initialization order may be fragile if callers use exported symbols before `nimAbiInit`.
- Shutdown semantics are difficult if exported refs outlive the library or if globals depend on external resources.
- The C backend may emit ABI-relevant details that vary by C compiler and platform.

## Recommended First Target

Use a small shared library test case with:

- Two overloaded exported procs.
- One concrete generic proc instantiated for two types.
- One ABI-POD object passed by value.
- One transparent `ref object` with public `string`, POD, and nested `ref object` fields.
- One constructor returning the transparent ref.
- One operation that mutates a managed field from Nim source.
- One type with a custom `=destroy`.
- One type with custom `=copy` and `=dup`.
- One no-copy type rejected from an exported signature that would require copying.
- Generated Nim ABI module and module-hash validation.
- Generated C header and header-hash validation.
- Exported producer hook thunks plus importer-side attached hook wrappers.
- Explicit `nimAbiInit`.
- A forced ABI mismatch test for layout.
- A forced ABI mismatch test for generated hook wrappers or unavailable hook declarations.

This exercises the simplified first dynlib model: a generated Nim ABI module, a generated C layout header, transparent refs, ARC-only ownership reasoning, Itanium-mangled symbols, and explicit ABI validation.
