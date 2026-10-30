# Plan: configuration-aware semantic BIF reuse

## Goal

Allow `nim ic` and `nim track` to reuse a module's semantic BIF when two builds differ in defines that cannot affect that module's compilation. For example, a define used only by Merenda should not by itself force recompilation of every FigDraw module. Reuse depends on configuration queries, imports, compile-time execution, and other inputs; it is not determined merely by which define names appear in a module's source.

The first milestone should be an opt-in, conservative experiment for define differences, with an easy fallback to the existing per-configuration cache. Measure the benefit and validate correctness before broadening it or making it the default.

## Current behavior

`compiler/deps.nim` computes a global `configSignature` from forwarded arguments, resolved search paths, and the effective configuration snapshot. Its hash selects `configs/<hash>/sem`; backend outputs are also partitioned by configuration and main module. Parsed source artifacts are already placed in a shared `parsed` directory. Therefore even an unused command-line define can select a different semantic cache directory.

Semantic compilation writes additional artifacts: dependency sidecars describe resolved imports, interface cookies gate ordinary dependent rebuilds, and implementation cookies and `NeedsImpl` edges track dependencies whose bodies were consumed at compile time. The driver also handles generated imports and cyclic groups. Cross-configuration reuse must preserve these mechanisms as a coherent set, not just copy an `.s.bif` file.

## Proposed design

### 1. Keep a conservative base configuration key

Split the current signature conceptually into:

- A **base key** for every effective setting not explicitly proven safe to track more narrowly. Initially this includes compiler and BIF format identity, target, backend, memory management and language options, ordered search paths, project/main-module context where relevant, and all non-define switches. Preserve existing config snapshot semantics. Backend artifacts remain under the full configuration key.
- A **define state** representing effective defines after configuration loading and command-line processing, including their values and built-in or target-derived symbols.

Only remove a define from the base key after auditing every way it can affect semantics, including compiler-internal uses. Compiler feature defines, switches that imply other options, and defines with untracked compiler behavior stay in the base key. A raw `-d:` argument cannot simply be dropped: equivalent or opposing switches, order, config-file effects, and implicit defines must be resolved first. If we cannot classify a setting confidently, retain the whole-config key for that build.

This is more restrictive than saying all user-defined symbols are safe to ignore. `options.isDefined` is also used by compiler code; some flags alter compiler behavior without appearing in user source. An inventory of those reads is a prerequisite, not a follow-up optimization.

### 2. Record module configuration observations during semantic compilation

Add a versioned configuration-observation manifest for each semantic compilation unit. Record the actual effective results of each relevant configuration query, including:

- `defined(name)`: the boolean result, including false for absent names, using the compiler's name matching and target-symbol rules.
- `booldefine`, `intdefine`, `strdefine`, and other supported define-value reads: presence and effective value, including default behavior. Values may matter even when the boolean presence does not change.
- Configuration reads made while expanding templates or executing macros for the module, with correct attribution to the compilation that consumed the result. Include files belong to the consuming module. Record reads from evaluated paths, including those that choose which later branches or imports are examined.

Useful starting points are `semDefined` in `compiler/semexprs.nim`, `foldDefine` in `compiler/semfold.nim`, and configuration lookups in `compiler/options.nim`. Audit all other read paths, including compiler-internal uses and VM callbacks, before enabling reuse. Central instrumentation may help coverage, but it must distinguish driver/diagnostic reads from semantic reads and associate observations with the correct module or cycle. Avoid changing the behavior of config lookup merely to collect observations.

Compile-time code can query `compilesettings`, read files or environment variables, run commands, generate imports, and perform external actions. For the first experiment, use the full configuration key or mark the affected unit non-reusable across configurations whenever an input cannot be tracked and validated safely. This safeguard must cover indirect inputs inside imported macros and templates, not just explicit calls in the current source. Unknown or missing manifests are cache misses. Existing limitations around arbitrary compile-time inputs should be documented separately; cross-config reuse must not silently make them worse.

### 3. Validate candidate BIFs and their dependency graph

Index candidate artifact bundles by module identity and base key, with multiple variants permitted. To reuse one, validate its manifest against the effective define state and validate its source, includes, resolved imports, and dependency artifacts against the current build. Dependencies must themselves be valid for the new configuration. A changed dependency can invalidate a consumer even if the consumer never reads the define; use the existing interface and implementation dependency semantics where they are sufficient, conservatively requiring stronger identity otherwise.

Do not assume the previous import graph is valid without first validating the configuration observations and inputs that selected it. Handle macro-generated imports, missing or changed includes, import resolution and search-path changes, and transitive implementation consumption. Treat a strongly connected compilation group as a unit until its observations and dependency validation can safely be split. Keep main-module-specific artifacts and any project-dependent semantics correctly scoped.

Reuse the complete compatible artifact bundle: semantic BIF plus required interface, implementation, edge, dependency, and configuration-observation metadata. The selected artifacts must remain discoverable by `nim m`, the driver's discovery fixpoint, IDE queries, and the backend. Decide whether to materialize bundles into the active configuration directory or teach the driver and children to resolve variant paths; copying, hard-linking, or references must not allow later writes to mutate a shared artifact. Integrate the choice with nifmake's timestamp-based rules so a cache hit does not immediately rebuild or falsely look current. Treat published bundles as immutable and publish their metadata and data atomically; concurrent processes need safe publication and consistent reads.

If validation fails, a manifest is incomplete, or any artifact is missing or corrupted, compile normally and publish a fresh candidate only after successful compilation. Include a format/version change or an independent versioned cache namespace so old artifacts are never mistaken for tracked ones. Avoid deleting existing caches as part of an opt-in trial.

## Implementation stages

1. **Audit and instrumentation.** Inventory define lookup, define mutation, compiler-controlled flags, configuration-query APIs, compile-time inputs, and compilation-unit attribution. Add opt-in logging that records observations and reasons a unit is ineligible, without changing cache selection. Inspect FigDraw and Merenda results to estimate opportunities and common fallback causes.
2. **Manifest and validation.** Persist deterministic, versioned manifests and verify their observations against the resolved configuration. Test presence, values, normalization, target-derived symbols, and changes to config files and switch order. Keep all existing cache behavior at this stage.
3. **Cross-configuration candidate reuse.** Implement a conservative shared variant store and bundle validation, first for units with completely tracked configuration observations and unchanged source and dependencies. Integrate group handling, discovery, and nifmake rules. Keep backend outputs separated by full configuration.
4. **Expand coverage deliberately.** Track additional compiler and VM observations only when their attribution and validation are sound. Retain fallback for everything else. Consider cross-project sharing separately after establishing how main-module context, paths, symbol identity, and dependency resolution affect artifact compatibility.

## Correctness tests

Compare incremental results against fresh builds under each configuration, including program output or other meaningful semantic assertions for small test projects. Check which modules actually recompile as well as whether the final result is correct. Cover:

- An unused define added, changed, and removed; a queried define toggled in both directions; an initially absent define becoming present; changed define values and defaults; style-equivalent names; built-in target defines.
- Nested and short-circuited `when` branches where a changed earlier observation exposes a previously unseen define or import.
- Defines read through includes, templates, macros, generic instantiation, and imported compile-time procedures; a dependency whose exported interface changes and one whose compile-time-consumed implementation changes.
- Macro-generated imports, re-exports and transitive dependencies, changed source or includes, search-path resolution, missing or stale metadata, cyclic groups, different main modules, and configuration snapshot changes.
- Unsupported compile-time inputs triggering the conservative fallback, including indirect use; compiler/format version mismatch, interrupted writes, and concurrent builds.
- Repeated A → B → A configuration switches, clean-cache and populated-cache runs, and `nim track` as well as `nim ic`. Verify backend outputs still match a clean build for each configuration.

Use fixtures that assert invalidation for actual changes and reuse for unrelated defines. Include negative tests designed to expose stale semantic results, not merely checks that cache files exist.

## Measurement

Use the same FigDraw entry point and environment for baseline and experiment. Measure cold builds for configuration A and B, A → B → A switching with a shared cache, and no-op builds; vary one unused define and one define that actually affects a dependency. Record wall and CPU time, peak memory, total cache size, semantic compilations and cache hits/misses, bytes read or copied where practical, and fallback reasons. Repeat runs and report variability. Compare generated results with clean builds, and do not run FigDraw's drawing test unless separately requested.

The main tradeoff is the cost of manifest validation and variant management versus saved semantic compilations and storage. A high hit rate alone is not sufficient: correctness and no-op overhead are release criteria.

## Open questions

- Which defines are safe to move out of the base key after auditing compiler-internal reads and implied options?
- How should reads during imported macro/template execution and cyclic group compilation be attributed?
- Are existing interface and implementation cookies sufficient across independently produced configuration variants, or is a stronger artifact identity needed?
- Can the current child-process and nifmake layout consume immutable shared bundles without expensive copying or timestamp errors?
- Which compile-time inputs can be validated, and which must force a conservative miss?
