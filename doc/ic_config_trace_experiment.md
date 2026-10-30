# Experimental module config trace

The separate [local FigDraw dependency analysis](ic_config_figdraw_local_analysis.md)
covers the `../figdraw` checkout and includes an import-graph-changing define.

Build the compiler with `-d:nimIcConfigTrace` to write diagnostic records to
stderr. `IC_CONFIG_DEFINED_V2` has process ID, context module path, query source
path, source line, escaped define name and boolean result. For value queries,
the context field is the source path of the symbol passed to constant folding,
which is not guaranteed to be the consuming module. `IC_CONFIG_VALUE_V2` adds
the define magic, presence and escaped raw value.
`IC_CONFIG_UNTRACKED_V1` has process ID, context path, operation source path,
line, a reason, and an optional macro call-site path and line. It does not log
the input or result of an external operation. Reasons report selected source
define mutations, `compileOption`, compilation date/time, VM config and
project-path queries, environment and filesystem operations, `staticRead`,
and `staticExec`; they are diagnostic warnings, not a complete
eligibility calculation. `nim check` suppresses `staticExec`, so that skipped
operation is not logged.
Strings use Nim `escape` syntax; an absent value has an empty final field.
The paths are compiler file-info paths, not artifact or cross-process identities.
The value-query location is the expression being folded, not necessarily the
definition. Records can repeat; concurrent writes and other output can interleave.
Values and paths can contain sensitive data. Run the diagnostic probe with
`python3 tests/ic/config_trace_test.py bin/nim_ic_config_trace` after building a
trace-enabled compiler at that path.

Successful `nim m` children invoked by the IC driver also write a versioned
`<module-suffix>.configtrace.json` file in their semantic directory. Version 2
includes a `coverage` map and sorted `ineligibleReasons`. The six coverage
areas (semantic reads, compiler reads, discovery reads, define mutation,
compile-time inputs, and attribution) are all explicitly `unknown`; selected
untracked operations add further reasons. Its sorted,
deduplicated observations cover the whole child process, including any cycle
group, and its `complete` field is always `false`. It also includes process-wide
`options.isDefined` observations with `<compiler>` as their context; these do
not have source attribution. The file is diagnostic and is not an artifact
bundle or a cache-reuse authorization. Failed children do not publish a new
file; older files can still exist if a rule fails before the child starts.

With the same opt-in compiler flag, each successful driver-launched `nim m`
process also writes `<module-suffix>.deptrace.json`. It identifies the project
and compilation group, and contains the process's recorded resolved imports
and union of `NeedsImpl` observations. At each semantic BIF load it samples
the companion interface and implementation cookies; separately, it records
the exact interface-cookie bytes actually read while chaining interface
cookies during serialization. Cookie bytes are base64-encoded, with explicit
presence flags, and observations are sorted and deduplicated. The snapshot is
removed when the child starts and published after successful compilation using
a per-process temporary file. As with the config trace, a stale file can remain
if a build fails before the child starts.

The cookie samples are separate filesystem reads, not atomic with the BIF
load: concurrent writers can change an artifact between reads. The interface
reads reflect serialization, rather than asserting which BIF version produced
those cookies. The process-level `NeedsImpl` set may include group members;
the existing sidecar writer filters those when producing each member's edges.
Imports and body observations are recorded by existing compiler machinery and
have not been proven complete for every macro, generated import, or cyclic
group. The snapshots are always marked `complete: false`, are not a published
artifact bundle, and must not be used for cache selection or recursive
dependency validation. Preserving exact input identity under concurrent builds
will require an immutable bundle or another synchronization mechanism.

`compiler/icconfigmanifest.nim` contains an isolated observation checker for
the recorded define results. It rejects incomplete, malformed, and explicitly
untracked inputs. A match checks only those observations: it does not validate
the base configuration, source, dependencies, or artifact integrity and is not
connected to cache selection. Production trace files are currently incomplete
and cannot return a match. The v2 checker requires all coverage areas and a
consistent list of ineligibility reasons; changing `complete` alone cannot
make an unknown-coverage trace match. Incomplete v1 traces remain recognizable,
but a v1 trace marked complete is invalid because v1 has no coverage contract.
Even a synthetic v2 match is not proof that its coverage assertions are true.

`compiler/icconfigdeps.nim` adds an isolated combined check for config
observations and dependency observations. It compares the complete set of
resolved dependency identities, edge kinds, interface-cookie bytes, and, for
`NeedsImpl` edges, implementation-cookie bytes. Every current dependency must
also have been independently validated, including its transitive dependencies.
Missing, duplicate, incomplete or changed records reject the check. The caller
must independently establish the current dependency set: a candidate's old
import sidecar is not proof of the graph under a new configuration.

This is a validation component, not an enabled reuse path. No production code
yet records a complete, coherent set of cookies consumed by a compilation or
constructs independently validated dependency snapshots, and a match would
still require validation of the base configuration, compiler identity, source
and includes, SCC membership,
external inputs, and the complete artifact bundle. The tests use synthetic
complete observations to exercise both the changed-cookie and changed-define
cases; real trace manifests continue to be rejected as incomplete.

`compiler/icconfigbundle.nim` adds an isolated bundle checker. Given supplied
complete records, it checks configuration observations and dependency records,
compiler and base-configuration identities, project and group membership, the
independently supplied source/include set and file hashes, and the semantic BIF,
interface cookie, implementation cookie, implementation-edge sidecar and
semantic-import sidecar for every group member. It uses streaming SHA-256 for
file bytes, requires unique module suffixes and correctly named artifacts, and
rejects missing, changed, duplicate or malformed evidence. Its tests use
synthetic completeness claims and a two-member group.

This checker does not discover inputs or produce trusted bundle manifests. A caller
must establish what the compiler and base keys cover, independently discover
current sources and imports, prove configuration and dependency coverage, and
ensure the recorded hashes describe the files actually consumed. Hashing and
then later reading a mutable file is not atomic. There is no trusted immutable
variant store or integration with nifmake; therefore even a `bcMatch` is not
an authorization to reuse a bundle. No production trace currently supplies the
required complete evidence.

### Diagnostic bundle publication

With a compiler built using `-d:nimIcConfigTrace`, passing
`-d:icConfigBundleAudit` to `nim ic` or `nim track` publishes diagnostic group
copies after a successful frontend discovery fixpoint. Under the selected
nimcache, `ic-config-audit-v1/bundle-*` contains copies of each group's five
artifacts per member, a JSON manifest and a `READY` marker. The manifest records
the existing full configuration signature's SHA-256, the compiler executable's
SHA-256, the IC format version, project and members, scanner-reported sources
and includes with hashes, and the children's config and dependency traces.
Artifact copies are checked against the bytes read from the originals. A
unique directory is populated before the marker is atomically moved into place;
readers ignore directories without it and can check the marker and file hashes.
The publisher does not hard-link active cache artifacts, so later compiler
writes do not mutate the copies. Each audit run creates new copies, including
on a no-op build; this option has substantial storage and hashing costs.
The flag is an ordinary Nim define and is visible to compiled code, so compare
configurations with the same audit flag when measuring semantic differences.

Every published manifest is deliberately `complete: false`. The scanner's
input set, trace attribution, compiler and configuration identities, and
dependency samples have not been proven sufficient or captured atomically with
semantic compilation. The files are ordinary mutable filesystem files; the
publication convention and integrity check do not make later reads atomic or
enforce immutability against writers. These bundles are for inspection only:
the driver never selects, materializes, or uses them for cache decisions.
Incomplete or interrupted publications are not cache entries.

A small `nim ic` A → B → A probe with a `strdefine` produced the expected
executable output on each switch. It exercises the existing separate caches;
it is not a cross-configuration reuse test.

The hooks cover `semDefined`, `foldDefine`, process-wide `options.isDefined`
queries during `nim m`, source define/undef pragmas, and selected VM operations.
They do not cover every compiler-internal config
lookup, VM callback, compile-time external input, define mutation, or dependency
attribution. A missing warning is not evidence that a unit is safe. Includes
are observed in the consuming module in the probe, but generic instantiations,
imported macros, cyclic groups and cross-module consumers have not been proven
attributable. These records must not be used to decide whether a cached
artifact is safe to reuse. The compiler behaves as before when built without
the flag.

## Configuration-read audit (initial inventory)

* `options.isDefined` checks the style-insensitive symbol table and target CPU,
  OS and aliases; the effective answer is not simply command-line membership.
  `condsyms` initializes compiler symbols. `commands` mutates symbols for
  switches including GC and backend settings; `pragmas` handles source
  `{.define.}` and `{.undef.}`, so results can change during compilation.
  Config files and NimScript can also read or modify configuration.
* Compiler reads also occur outside `semDefined`: `parser` uses `nimPreviewDotLikeOps`;
  `semtypes`, `semstmts`, `sigmatch`, `lookups`, and `liftdestructors` use
  preview and semantic flags; `modulegraphs`, `ast2nif`, and `deps` use IC
  flags affecting graph construction and serialization. Backend and diagnostic
  reads exist too. The process-wide `isDefined` hook records these calls when
  they occur in `nim m`, but not their source or whether all reads took that
  path. These names and unclassified switches must remain in the full
  configuration key until their reach is established.
* `deps` independently evaluates conditions while discovering imports; its
  observations and the semantic pass must agree, including generated imports.
  Source changes, includes, dependency interfaces and compile-time-consumed
  implementations require validation even when a unit's observations match.
* `vmops` exposes `compilesettings`, environment queries and command execution;
  VM and semantic constant folding also expose external inputs and build time.
  Imported macros or templates can consume these indirectly. Some operations
  now emit diagnostic reasons, but no unit has been proved eligible. A future
  scheme needs conservative transitive fallback, including cyclic groups and
  unknowns.
* `semfold` evaluates `compileOption` and `compileOption` with an argument
  directly against compiler settings; `deps` separately interprets a subset
  of those conditions for discovery. Target, host, application type and
  `isMainModule` are other semantic inputs. `CompileDate` and `CompileTime`
  come from the compiler clock. Selected fold reads now emit untracked records;
  the trace does not yet validate the complete settings or discovery state.
* VM callbacks can expose the project path, compiler executable path, current
  directory, CPU or wall clock, filesystem writes and commands. The optional
  `vmopsDanger` callbacks and selected other operations now emit diagnostic
  records when executed. Other VM operations, host services, compile-time state
  and mutations still need auditing; the default unknown coverage does not
  depend on observing a particular callback.

### Attribution probe

The regression probe exercises an imported template, an imported macro and an
imported define-backed constant. A config query with constant arguments can be
evaluated while checking the macro's definition, even when no caller exists;
its record has the defining context and an empty macro call site. Queries
whose arguments depend on the macro's input run at invocation and, in this
fixture, report the caller's path as the macro call site. The VM context and
call site are useful diagnostics, not a proven attribution scheme: nested
evaluations and transitive dependencies still need an audit. The probe also
checks that source `{.define.}` followed by `{.undef.}` yields both observations
and both mutation warnings.

## FigDraw observation

On the FigDraw `src/figdraw.nim` frontend, two completed `nim track` runs in
an isolated cache differed by the otherwise unused `icConfigTraceUnusedProbe`
define. Both generated 325 semantic BIFs with the same names; all 325 were
byte-identical (82,635,570 bytes in each configuration). The baseline trace
contained 4,286 parseable records, 229 distinct module names and 307 distinct
define names. Module names can collide and record counts are not unique reads.
This confirms duplication for this particular pair, not that every matching
file can safely be reused: interfaces, dependencies, and compile-time inputs
must also be validated.

The original diagnostic binary logged only presence for value queries; the
current hook additionally logs values. A small compiler probe verified a true
`defined(probeFlag)` and a `strdefine` set to `hello`. Further work needs
stable module identities, complete input coverage, structured per-process
records, and tests for missing and changed values before adding manifests or
cache reuse.

A third completed frontend run added `harfbuzzRuntime`, a name observed in
baseline queries. Its 325 corresponding semantic BIFs were also identical to
the baseline. The baseline trace contained both true and false observations for
that name, so the existence of a query alone does not demonstrate that changing
the command-line define changes its effective result at that point. This run
does not establish an invalidation case. An attempt with `useNativeDynlib`
failed during dependency discovery because `figdraw_native_abi` was unavailable.

## Updated FigDraw config-tracking probe

The updated upstream FigDraw main revision (`3f31bc3`) was used in a detached
worktree. Its checked-out HarfBuzz bindings were too old for that revision, so
the probe used Harfbuzzy 0.7.0 and its pinned `harfbuzz-nim` revision in the
worktree's config. The original FigDraw checkout and dependency tree were left
unchanged. The frontend was `src/figdraw.nim`; `nim track` completed without
running any drawing tests.

With the same effective FigDraw and compiler settings, the baseline and
`-d:icConfigTraceUnusedProbe` runs each generated 279 semantic BIFs (97,307,196
bytes total). All 279 corresponding BIFs were byte-identical. This is an
unrelated-define reuse opportunity at the artifact-comparison level; it does
not establish that reuse is safe because the trace and dependency validation
are incomplete.

The source contains a more meaningful invalidation candidate:
`src/figdraw/fignodes.nim` reads `{.intdefine.}` `ShadowCount` to size the
exported `RenderShadows` array type. The trace recorded `ShadowCount` as absent
in the baseline and as the value `5` when supplied through the FigDraw config.
An independent `nim check` probe asserted that `default(RenderShadows).len`
was 4 under the default and 5 with the changed define. The `ShadowCount=5`
frontend generated 279 semantic BIFs (97,306,710 bytes); four corresponding
BIFs differed byte-for-byte from baseline: `fignodes`, `figrender`,
`utils/drawutils`, and `renderfragments`.
This confirms a semantic-output change and a concrete invalidation case. It
does not show that other consumers are unaffected, nor does it validate
cross-configuration artifact reuse.

The first command-line `-d:ShadowCount=5` run stopped before compiling
`fignodes`; the earlier claim that the define was not propagated was incorrect.
The generated child command included the define. After resuming that run, the
`fignodes` trace reported the value `5`, and its 279 BIFs had the same four
differences from baseline as the config-file run.

A fresh baseline `nim track` run with the selected VM and mutation warnings
completed with the same 279 pairwise byte-identical semantic BIFs as the
previous baseline. It produced 65 parseable warning records: 44 source define
mutations at two Harfbuzzy source locations, 20 `staticRead` records at six
source locations, and one `staticExec` record in `harfbuzz-nim`. The define
mutation records came from 22 processes, so they are not 44 distinct source
mutations. The `staticRead` records included a shader template whose source and
VM context paths differ. `opSlurp` also adds a synthetic include for its input,
but that alone does not validate cross-configuration reuse or the transitive
consumer. The records demonstrate reasons a conservative scheme must consider;
their absence elsewhere is not proof of eligibility.

A subsequent baseline run with process-wide `options.isDefined` recording
produced 252 manifest files, all explicitly incomplete, and the same 279
byte-identical semantic BIFs as the earlier baseline. The files contained
observations of 310 distinct compiler lookup names, including `icNoIfaceGate`.
Manifest count is not module count: cycles are compiled as groups and repeated
compilations can replace a process's file. These observations are process-wide
and may include lookups made during setup or diagnostics.

The revised trace probe passes against a trace-enabled compiler and checks
present and absent `defined` results, style-equivalent names, target-derived
symbols, includes, imported macro/template cases, define mutation, value reads,
selected VM warnings, and escaping of values containing spaces. It also checks
that `nim track` forwards a command-line define to a child compilation. It
verifies the diagnostic records only. Compiler-internal flag reads, other
mutation paths, complete macro attribution, other compile-time inputs, and
dependency validation remain outside the hooks. No unit is yet eligible for
cache reuse based on this trace.
