# Nim Shared Library ABI Plan

## Progress Checklist

### Milestone 1: Mangled Export Prototype

- [x] Add a dedicated Nim ABI export mode for C backend procs.
- [x] Export overloaded procs with distinct signature-mangled symbols.
- [x] Export concrete generic instantiations with distinct signature-mangled symbols.
- [x] Add codegen coverage that checks generated exported symbols.

### Milestone 2: Explicit Init and Metadata

- [ ] Generate ABI metadata for compiler, target, backend, memory manager, allocator, and flags.
- [ ] Generate explicit `nimAbiInit` entry point.
- [ ] Suppress automatic shared-library constructors for explicit-init builds.
- [ ] Add ABI mismatch diagnostics and tests.

### Milestone 3: Type Layout Checks

- [ ] Emit layout metadata for exported object and `ref object` types.
- [ ] Check size, alignment, field offsets, and layout hashes.
- [ ] Support ABI-POD structs by value.
- [ ] Reject unsupported object layouts with clear diagnostics.

### Milestone 4: Transparent Managed Types

- [ ] Allow managed fields under strict ABI match.
- [ ] Validate type hook hashes and managed runtime assumptions.
- [ ] Add ARC and atomicArc coverage.

### Milestone 5: Importer Integration

- [ ] Generate or support importer-side ABI expectations.
- [ ] Bind mangled proc symbols only after ABI validation.
- [ ] Add end-to-end shared-library tests.

### Milestone 6: Exported Hooks Follow-Up

- [ ] Re-evaluate exported lifecycle hooks after strict same-runtime ABI works.
- [ ] Consider opaque-handle lowering for safer C-facing APIs.

## Goal

Add a compiler-supported Nim-to-Nim shared library ABI for the C backend that can export overloaded procs, concrete generic instantiations, high-level Nim types, and module initialization in a checked way.

The initial implementation assumes both the producer library and the consumer are compiled with matching Nim compiler/runtime settings, and it starts with transparent `ref object` access rather than opaque handles.

## Non-Goals for the Initial Version

- Do not define a stable ABI across arbitrary Nim compiler versions.
- Do not support mismatched memory managers, allocators, backends, or target ABIs.
- Do not make the ABI safe for direct C mutation of Nim-managed fields.
- Do not export open-ended generics. Only concrete generic instantiations are exported.
- Do not support exceptions crossing the shared library boundary until there is an explicit exception ABI contract.
- Do not support ORC in the first implementation. Start with ARC and atomicArc.

## ABI Model Options

There are two viable ownership/runtime models.

### Option 1: Same Type Definitions and Runtime

Both sides compile the same type definitions and use the same runtime, allocator, backend, target ABI, and relevant compiler flags.

This allows the importer to compile normal Nim field access, constructors, destructors, copies, sinks, and managed-field assignments using the same compiler logic as the library.

The library still exports ABI metadata so the importer can reject a mismatch before using any exported symbol.

This is the initial plan.

### Option 2: Exported Lifecycle Hooks

The library exports lifecycle hooks for every exported managed type, and the importer uses those imported hooks instead of locally compiled hooks.

Required hooks include destroy, copy, sink, duplicate, default initialization, and possibly field-level assignment helpers for managed fields.

This model is more robust across compiler/runtime differences, but it is substantially more work. It is a later-stage design unless Option 1 proves too fragile.

## `ref object` Options

There are also two viable `ref object` exposure models.

### Option A: Opaque Handle

The caller receives an opaque handle and only retains, releases, or calls methods through exported hooks.

This is the easiest and safest model. It is close to what C-style bindings and tools like Genny generate today.

It keeps object layout private and avoids direct caller mutation of managed fields.

### Option B: Transparent Ref Object

The caller can dereference fields directly.

This is possible only when both sides use the same compiler, flags, target ABI, layout hash, memory manager, allocator contract, and runtime configuration.

Every managed field access must be compiled by Nim so ARC or atomicArc inserts the correct copies, sinks, assignments, and destroys.

This is the initial plan.

## Initial Scope

The first version targets this combination:

- Option 1: same type definitions and same runtime/allocator contract.
- Option B: transparent `ref object` access.
- C backend only.
- ARC or atomicArc only.
- Explicit shared-library initialization.
- Itanium-style exported names for overloads and concrete generic instantiations.
- ABI metadata checked before any exported API use.

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
- Exported type layout hashes.
- Exported proc signature hashes.
- Calling convention.

The ABI check should prefer a single computed ABI fingerprint, but the metadata should also expose enough structured fields for diagnostics.

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

For managed fields, layout compatibility is not enough. The importing side must compile all reads, writes, copies, moves, and destruction with matching Nim semantics.

## Constructors and Destructors

High-level Nim constructors are allowed in the initial design if both sides match the ABI fingerprint.

Examples:

```nim
proc initFont*(name: string; size: float32): Font {.exportnimabi.}
proc newRenderer*(target: ref Window): ref Renderer {.exportnimabi.}
```

Returned managed values must be destroyed by Nim code compiled under the same ABI contract. Direct C callers are not part of the initial high-level ABI.

Generated ABI metadata should include type hook identities or hashes for:

- `=destroy`
- `=copy`
- `=sink`
- `=dup`, if relevant
- assignment behavior for managed fields

The initial implementation may validate hook hashes without exporting hooks. Exported hooks belong to Option 2.

## Field Access Rules

Transparent field access is allowed only for Nim consumers that passed the ABI check.

Direct C field access is only safe for ABI-POD fields and must not mutate Nim-managed fields.

For example, this must be compiled by Nim:

```nim
obj.name = "Inter"
```

because it may need to release the old `string`, copy or sink the new `string`, and update ARC state.

The compiler should classify exported types:

- `AbiPod`: C-compatible by-value layout and no Nim-managed fields.
- `AbiManaged`: layout can be checked, but Nim-managed operations are required.
- `AbiRefTransparent`: transparent `ref object` allowed under strict ABI match.
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
6. Compile high-level calls and field access normally under the matching type definitions.

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
- Generate structured ABI metadata.
- Compute type layout and signature hashes.
- Generate explicit init and optional shutdown symbols.
- Suppress automatic shared-library constructors for explicit-init builds.
- Generate or support importer-side ABI expectations.
- Add diagnostics for unsupported exported signatures.

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

### Milestone 2: Explicit Init and Metadata

- Generate ABI metadata for compiler version, target, backend, memory manager, allocator, and flags.
- Generate `nimAbiInit`.
- Suppress automatic shared-library constructor when explicit init is enabled.
- Call `NimMain` exactly once from `nimAbiInit`.
- Add mismatch tests.

### Milestone 3: Type Layout Checks

- Emit layout metadata for exported object and ref object types.
- Check size, alignment, field offsets, and layout hashes.
- Support ABI-POD structs by value.
- Reject unsupported object layouts with clear diagnostics.

### Milestone 4: Transparent Managed Types

- Allow managed fields under strict ABI match.
- Validate type hook hashes.
- Validate `string`, `seq`, and `ref` layout/runtime assumptions.
- Add ARC and atomicArc test matrices.

### Milestone 5: Importer Integration

- Generate or support importer-side metadata expectations.
- Provide explicit initialization API for linked or dynamically loaded libraries.
- Ensure high-level calls use mangled symbols after ABI validation.
- Add end-to-end shared-library tests.

### Milestone 6: Revisit Exported Hooks

- Evaluate Option 2 after the strict same-runtime model works.
- Export lifecycle hooks where cross-build compatibility or plugin isolation requires it.
- Consider opaque-handle lowering for safer C-facing APIs.

## Risks

- Nim runtime initialization order may be fragile if callers use exported symbols before `nimAbiInit`.
- Transparent `ref object` access makes layout and hook mismatches dangerous.
- Compile-time defines can affect type layout or proc bodies in ways that are hard to fingerprint completely.
- AtomicArc may be required for cross-thread sharing even when ARC passes ABI checks.
- Shutdown semantics are difficult if exported refs outlive the library or if globals depend on external resources.
- The C backend may emit ABI-relevant details that vary by C compiler and platform.

## Recommended First Target

Use a small shared library test case with:

- Two overloaded exported procs.
- One concrete generic proc instantiated for two types.
- One ABI-POD object passed by value.
- One transparent `ref object` with a managed `string` field.
- One constructor returning the ref object.
- One destructor path exercised by ARC.
- Explicit `nimAbiInit`.
- A forced ABI mismatch test.

This exercises the core feature without starting from a large real-world binding generator.
