======================================
  Incremental Compilation (IC)
======================================

``--ic:on`` turns an ordinary compile into an incremental one. It decomposes
compilation into per-module steps whose results are cached as NIF files, and
uses a Sigils worker pool to re-run only the steps whose inputs changed.
The compiler itself is built with ``--mm:arc --threads:on``; the target
program's memory manager is still selected independently.

.. code-block:: cmd

  nim c   --ic:on  myproject.nim
  nim cpp --ic:on  myproject.nim

It is a switch on the normal compile commands, not a command of its own, so
everything else keeps working unchanged: ``cpp`` and ``objc`` backends, ``-r``,
``-d:release``, ``--exceptions:``, and a project-wide opt-in from ``nim.cfg`` /
``config.nims``. The older spelling ``nim ic`` still works and drives the same
code, but it is the C backend only and cannot run the binary it built.

This document describes **how IC works today**, including the edge cases
that shaped the current design. The per-module backend rewrite that earlier
editions of this document listed as a *Plan* has **landed**: the whole-program,
reuse/redirect/def-retention backend is gone and codegen is now a set of
per-module rules (see *The backend*).

Overview
========

The pipeline has two halves driven by one process (the *driver*, `commandIc` in
``compiler/deps.nim``) that constructs a dependency graph, writes a build file,
and schedules its rules on Sigils actors:

1. **Frontend** — per module:
   - ``nifler parse --deps`` turns ``.nim`` source into a parsed NIF
     (``.p.nif``) plus a static dependency list (``.deps.nif``).
   - ``nim m`` (the *semantic* step, `cmdM`) reads the parsed NIF + the
     precompiled NIFs of the module's imports, type-checks, and writes the
     **semmed NIF** (``.nif``) plus invalidation sidecars (see *Cookies*).
2. **Backend** — ``nim nifc`` (`cmdNifC`, ``compiler/nifbackend.nim``) reads the
   semmed NIFs, generates C, compiles and links.

The coordinator orders steps by their input/output files. Among ready jobs it
starts the longest remaining dependency chains first. At the same depth,
larger lowering/codegen inputs take priority so small jobs can fill their tail.
A completion signal releases dependent actors immediately; there is no barrier
between unrelated modules at the same graph depth. Timestamps are checked after dependencies
complete, so an unchanged interface cookie still stops a rebuild cascade.

Sigils module workers
--------------------

``compiler/ic/actors.nim`` reads the generated frontend/backend build files.
Each scheduled module job is an ``AgentActor`` moved into a
``SigilThreadPool``. ``requested`` and ``finished`` signals dispatch work and
return its exit status and buffered compiler diagnostics. The coordinator alone
owns dependency counts. Failed prerequisites block their dependents while
independent jobs finish; the pool is joined before IC returns.

An actor represents one module/stage invocation, not a permanently assigned OS
thread. An idle worker leases the next ready actor exclusively. Each job gets
one request and one reply; inputs, outputs and dependency lists stay with the
coordinator. Completed actors are released immediately. A module's later stages
can run on another worker, so the dependency cache belongs to the OS worker,
not the module actor.

The preliminary ``nifler deps`` scans and graph traversal still run serially
in the driver. These extract imports before the pool's full parsing and semantic
jobs can be scheduled. The scans launch directly through ``startProcess``,
allowing POSIX spawn without an intermediate shell, including between rounds
when the compiler retains large caches. Newly discovered imports enter the next
round; graph expansion does not yet insert jobs into a running round. Semantic
work inside one module also remains sequential.

A successful job that stops to discover an import has no module output yet.
Its dependents wait for the next discovery round while independent branches
finish. Only jobs that actually ran can confirm fresh dependency sidecars.
An unknown ``when`` guard applies to the import edge in that module; once the
edge is confirmed, the imported module's unconditional dependency subtree is
available to the pool. All imports in a selected import statement are recorded
together, including grouped paths and aliases. Inactive branches and
``compiles`` probes are not expanded speculatively.

Semantic analysis and the ``lower``, ``cg``, ``merge``, ``emit`` and ``link``
commands run **inside the compiler's worker threads**, through
``compiler/ic/compilejobs.nim``. Each invocation constructs its own
``ConfigRef``, ``IdentCache``, ``ModuleGraph`` and VM. The NIF intern pools,
canonical-type caches, AST decoder state and macro-counter lock handles are
thread-local and cleared between jobs. ASTs are never sent between actors.
Symbol/type cycles and VM/codegen backreferences are explicitly released at
job completion. Each worker retains a bounded cache of dependency BIF mappings,
name tables, lazy name lookup indexes and declaration indexes. Runtime helper
lookup also retains an index by basename, including overloads and misses,
instead of scanning every declaration for each lookup. Later jobs on
that worker reuse this data while constructing fresh ASTs, symbol/type IDs,
VMs and module graphs. Cached buffers never cross OS threads.

The cache checks file identity, size and timestamps before every reuse, so an
atomic replacement invalidates it even if its size and modification time are
unchanged. Active jobs hold leases on their images: eviction or replacement
cannot unmap data while a cursor still uses it. Job leases are released after
the last AST and cursor; cached images are released when the worker exits.
The default budget is 512 MiB per worker, charged against mapped file bytes and
an estimate of decoded tables and names. Active job data can exceed that budget.
This is a retention limit, not an allocation at startup.
``-d:icDepCacheMiB:N`` sets the budget; ``-d:icNoDepCache`` disables reuse for
comparison. ``-d:icDepCacheStats`` prints per-job hits, misses, evictions and
retained bytes. One worker pool lives across frontend discovery rounds and
backend processing, and is joined at the end of the compiler invocation.

Ordinary ARC suffices because compiler graphs and cached buffers stay on their
own OS worker. Sigils transfers actor/message ownership, gives an actor an
exclusive worker lease, and uses synchronized shared delivery endpoints.
``--mm:atomicArc`` remains supported for compiler builds.

The ownership/liveness decision is an exception to worker-local storage: the
merge actor publishes its finished value tables through an atomic ``ConstPtr``.
Every rendering actor borrows that same immutable snapshot instead of parsing
and rebuilding the tables. A file-version check prevents stale reuse; a missing
snapshot is loaded once under a lock. Readers retain their leases across
replacement, and the pool releases the cached snapshot after joining workers.

More declaration data could use this model, but the current decoded AST mixes
stable facts with mutable state. Lazy loading fills symbol/type objects;
resolved IDs depend on the job's graph; type layout, transformed bodies, VM
slots and codegen locations change during compilation. The BIF's token bytes
and declaration facts are stable, but its lazy name pools and cursor ownership
are also mutable. Sharing those safely requires frozen storage with stable
identities plus job-local decoding and annotation tables. Atomic reference
counting alone would not make the current AST objects safe to share.

Compile-time environment changes are local to a job, including the environment
passed to ``staticExec``. An import cycle remains one semantic job, since its
members must resolve each other in the same graph.

The parser executable ``nifler``, C compiler, linker and initial configuration
producer remain external tools. Their module jobs are still scheduled by the
pool. Discovery of macro-generated imports uses the existing rounds and
``.s.deps.bif`` sidecars. Workers report an early stop to the coordinator instead
of exiting the compiler process.
On POSIX systems that support it, external tools use ``posix_spawn``. A command
with an explicit working directory uses ``fork`` so that only the child changes
directory; this avoids copying the compiler's large address space for ordinary
parser and C compiler commands.

Use ``--parallelBuild:N`` to bound the pool, ``-d:icJobs:N`` to override that
bound, or ``-d:icNoParallel`` for one worker. The default is the available CPU
count. ``-d:icProcesses`` selects the previous ``nifmake`` process runner for
comparison and troubleshooting. Compilers built without ARC/atomic ARC and
threads, or
with the optional native FFI or process-only IC diagnostics, also use the
process runner. Native FFI can mutate process-global library state, and those
profilers use process-wide counters and exit hooks.

``-d:icProfile`` works with actors and prints JSON records through the
coordinator: ``ICJOB`` gives the worker, output, start time, request delivery
time (``queueNs``) and execution time;
``ICCOMPILE`` separates setup, compiler work and cleanup by stage; ``ICBUILD``
reports the actual pool size, executed/skipped/deferred/blocked counts and
aggregate busy time. Times are in nanoseconds, with job starts relative to that
build round. Request delivery starts when the coordinator creates the actor;
it excludes time a ready job waits for an available pool slot. This measures
actor occupancy, not CPU utilization: the ``link``
actor also drives C compiler subprocesses in parallel through
``--parallelBuild:N``. The backend's lowering barrier ensures code generation
sees complete lowered dependencies; main-module codegen, ownership merging and
linking have additional whole-program dependencies.

Backend workers build frontend name lookup tables only for ``system``, whose
builtins are still looked up by name. Other modules' symbols are already
resolved in their NIF artifacts. After merging ownership and liveness, actors
render C in a few batches balanced by module image size, bounded by the pool
size and averaging at least 16 modules per batch. Rendering shares no AST and
preserves the same content-stable C outputs. The process runner retains one
render invocation to avoid repeated process startup.

For detailed compiler phase counters, build the compiler with
``-d:icBNodeProf``. Actor counters are thread-local and reset for each job;
the coordinator writes ``BNODEPROF`` records to ``NIM_IC_BNODE_PROF`` when set,
or to stderr. ``Processms`` measures the job lifetime in actor mode, and
``PeakRssMB`` is the peak for the entire compiler process. Instrumented builds
are for diagnosis; use a normal release compiler for speed comparisons.

For example, use an empty cache directory to profile a clean compiler build:

.. code-block:: cmd

  bin/nim c --ic:on -d:release --parallelBuild:16 --skipUserCfg \
    -d:icProfile -d:icDepCacheStats --hint:Processing:off \
    --nimcache:/tmp/ic-profile-cache --out:/tmp/ic-profile-nim compiler/nim.nim

Measurements on FreeBSD 15.1, a Ryzen 7 8745HS (16 logical CPUs) and 16 GiB
RAM, with release builds and a warm filesystem cache (2026-10-04): a clean
compiler self-build took 82.77 seconds with the previous actor implementation
and 34.41 seconds after these changes, using 16 workers on the same source
tree. Frontend discovery fell from 47 rounds to 4. The updated process runner
took 34.05 seconds; this workload is now approximately tied between runners.

With a 512 MiB cache limit per worker, the actor build took 52.92 / 38.08 /
34.45 seconds at 4 / 8 / 16 workers, with peak compiler RSS of 1.64 / 2.61 /
4.17 GiB. More workers became useful after fixing discovery and avoiding large
``fork`` operations. Raising the cache from 128 to 512 MiB removed evictions,
but the final 16-worker timings (34.80 versus 34.41 seconds) were close.
ARC and atomic ARC compiler-only timings were also effectively tied
(19.54 versus 19.58 seconds at 8 workers); ownership isolation allows ARC,
but removing atomics was not the main speedup.

A 48-module workload's median clean build improved from 4.39 to 2.69 seconds
(three runs). No-op builds remained about 21 ms and single-module body edits
about 200 ms (five runs each). No-op artifact timestamps were unchanged;
the actor and process runners produced identical primary artifacts for both
this workload and the compiler self-build.

A second profiling pass on the same machine, before the dependency-scan launch
fix, reduced the clean actor compiler build from 34.58 to 32.58 seconds
(two-run means on the same source tree for both compilers,
with the run order reversed for the second comparison). The updated process
runner averaged 33.00 seconds. Actor trials ranged from 32.22 to 32.93 seconds,
so the small lead over processes remains within the observed variation.
Indexed runtime-helper lookup, avoiding unused backend interfaces, starting
large backend jobs earlier, and parallel rendering with shared merge decisions
account for this change. The Nim backend excluding C compilation/linking fell
from 6.49 to 4.36 seconds. The pool remains at 16 workers and the cache at
512 MiB per worker. A 32-worker trial took 33.76 seconds and raised peak compiler
RSS from about 4.1 to 5.8 GiB; dependency cache misses rose from about 8,200 to
13,500 as more workers loaded their own images.

Across 1,331 actor jobs, request delivery had a median of about 20 microseconds
and a 95th percentile below 50 microseconds. Median job execution was about
31 milliseconds. This does not suggest a signal-delivery bottleneck; reducing
repeated decoding and shortening dependency chains remain the larger targets.

On the 48-module workload, median clean time fell from 2.71 to 2.64 seconds
(three runs), and a leaf body edit from 199 to 182 ms (five runs). No-op builds
remained about 20–21 ms with unchanged artifact timestamps. The compiler
self-build's 1,016 primary artifacts were identical between the updated actor
and process runners; all 386 generated C files also matched the previous actor
compiler.
The small workload's 267 primary artifacts matched in all three modes.
Explicit lowering/codegen batches of 2, 4 and 8 reduced aggregate CPU work but
only saved about half a second in the backend; these retain their existing
``-d:icBatchSize:N`` opt-in rather than changing incremental rebuild granularity.

Kosmo (``src/merenda/kosmo/kosmo.nim`` in the Merenda checkout) exercises a
larger graph: 1,004 semantic module artifacts and 17 frontend rounds. With its
normal release/ARC/thread configuration, including native debug information,
16 workers and a 512 MiB cache, clean actors averaged 153.32 seconds and
processes 154.61 seconds over two runs each. Increasing the actor cache to
1 GiB reduced a trial to 146.83 seconds and cut evictions from about 120,000
to 26,000. After also launching dependency scans directly, a clean actor trial
took 137.74 seconds versus 153.46 seconds for the updated process runner.
These last figures are single trials, with peak actor compiler RSS of 11.0 GiB.
Use ``-d:icDepCacheMiB:1024`` for this larger retention budget; the default
remains 512 MiB.

The direct-launch comparison reduced actor driver/configuration/graph time
from 10.69 to 3.51 seconds, while scheduled frontend work remained about
58 seconds. The updated frontend totaled 61.33 seconds for actors and
79.29 seconds for processes. More workers alone cannot remove the remaining
module dependency chains or parallelize semantic work inside a module.
All 1,188 generated C files matched in the cold-build comparisons; after the
actor warm rebuild pruned five unused platform files, the remaining 1,183
still matched. Every resulting executable passed ``--help``. After one warm rebuild, the
actor no-op took 0.45 seconds without changing primary artifact timestamps.
The process runner still redid some frontend/backend work on unchanged sources
and took about 9.1 seconds, so that is not a pure no-op comparison.

``koch boot`` fetches pinned Sigils, threading, variant and stack_strings sources
under ``dist/sigils``. Sigils currently requires full system exports and classic
method/destructor handling, so the final compiler build leaves the slim-system,
vtable and non-var-destructor preview options disabled.
The bootstrap applies ``tools/nimony-lifetimes.patch`` to release NIF buffer
owners and pools, and ``tools/variant-typeids.patch`` to derive Variant IDs from
type signatures. Compile-time counters are local to each module's VM and cannot
serve as global type IDs; stable IDs let an IC-built compiler exchange Sigils
messages correctly too. Rebuild the compiler with ``-d:icWorkerStats`` to include
per-job heap measurements in its diagnostics.

Artifacts (the NIF zoo)
=======================

Semantic BIF from regular builds
--------------------------------

``--genBif:on`` makes a regular compiler invocation write each semantically
checked module as ``<suffix>.s.bif`` under the build's nimcache directory. This
reuses the semantic artifact format used by IC without enabling incremental
compilation or changing how the program is generated and linked. Tools such as
language servers, debuggers, and binding generators can request these artifacts
when they need resolved symbols and types from an ordinary build.

Per module ``<suffix>`` (a content hash of the path; see *NIF symbols* below),
under the nimcache directory:

| File | Producer | Purpose |
| ---- | -------- | ------- |
| ``<s>.p.nif`` | nifler | parsed AST (syntactic) |
| ``<s>.deps.nif`` | nifler | **static** import list (syntactic `import`s) |
| ``<s>.s.deps.nif`` | `nim m` | **real** post-sem imports (incl. macro-generated); see *Discovery* |
| ``<s>.nif`` | `nim m` | semmed module (symbols resolved, typed) |
| ``<s>.iface.nif`` | `nim m` | **iface cookie**: hash of the importer-visible surface |
| ``<s>.impl.nif`` | `nim m` | **impl cookie**: hash of the entire content (bodies included) |
| ``<s>.edges.nif`` | `nim m` | **NeedsImpl edges**: modules whose bodies this sem consumed |
| ``<s>.c.nif`` | `nim nifc` | the C text as a NIF, with def/ref markers for DCE & dedup |
| ``ic_config.cfg.nif`` | driver | precompiled config replayed by every child (`icconfig.nim`) |
| ``ic.version`` | driver | format stamp; a mismatch wipes the cache (`icFormatVersion`) |

NIF symbols and ownership
=========================

(See ``../nifspec/doc/nif-spec.md``.) A global symbol is
``<ident>.<disamb>.<moduleSuffix>``. For a **generic instantiation** the
`<disamb>` is not a counter but a *content hash* — `setInstanceDisamb`
(``modulegraphs.nim``) MD5s the generic's identity plus the `typeKey` of every
concrete type argument, masks it to 30 bits and tags it with `InstanceDisambBit`.
So the only part of the name that varies between two modules making the **same**
instantiation (`seq[Foo]`) is the `<moduleSuffix>`. Two consequences drive the
backend:

- **Instance names are content-addressed**: the same instantiation produced in
  different modules yields the *same* `<ident>.<disamb>`, so a deterministic dedup
  is possible by the *module-suffix-stripped* name. The cross-TU C name
  (`ccgtypes.sharedInstanceCName`) and the **merge** stage's live-set/owner
  decision (`nifbackend.computeMergeDecision`) both key on this stripped form.
- **The suffix names a mint-site owner.** The `<moduleSuffix>` is the module
  *that minted the instance* (the instantiation site), so the same instance has a
  different full name in each module that makes it. Because every `cg` process
  emits the instances it demands (*emit-everywhere*), the same definition can be
  produced by several translation units; the **merge** stage then deterministically
  picks the single artifact allowed to embed each body (smallest claimant), which
  is the cross-process replacement for the old in-process single-writer machinery.

Ordered module interfaces
=========================

Each semantic BIF carries two authoritative interface records:

* ``(interface <count> <symbol>...)`` lists public symbols, including re-exports.
* ``(hiddeninterface <count> <symbol>...)`` lists the full interface used by
  ``import module {.all.}``, including both public and private symbols.

Identifier groups are sorted by name; symbols with the same identifier appear in
the frontend's lookup order. Whole-module exports (including ``export except``)
use this same traversal, so re-export chains do not depend on whether a source or
cached hash table supplies the symbols. A module qualifier is represented by
``(reexpmod "alias" "moduleSuffix")`` in the sequence.
The definition index supplies symbol offsets; its hash-table iteration order does
not determine interface membership or overload precedence.

The loader reserves space for the complete record before inserting its symbols,
so table growth cannot scramble the recorded order. It builds the public table
on import and the full table independently on first hidden lookup. Module aliases
are resolved during insertion, with no later appends or slot-reordering pass.
Lowered BIFs carry these records forward without eagerly loading declarations.

The public record contributes to the interface fingerprint, so changing overload
order invalidates importers. The full record contributes to the implementation
fingerprint, and hidden lookups record an implementation dependency so private
edits invalidate their consumers too. These records expose candidate order to
tooling; they are not a trace of call-site overload resolution.

Shared compile-time counters
============================

``CacheCounter`` state cannot live in the memory of a single ``nim m`` job:
sibling modules have separate, possibly parallel VMs and would
allocate from the same initial state (#26201). Instead the counters are stored in
``<nimcache>/ic.counters``, guarded by the OS file lock ``ic.counters.lock``.
A job opens its own lock handle on its first counter operation, loads the file, writes
it through on every ``inc`` and keeps the lock until it is done with its module,
so ``ids.inc; ids.value`` observes its own increment. No job waits on
another one while holding the lock, so this cannot deadlock.

The file survives across builds and records, per counter, the high-water mark
and the numbers each module's process was handed. A re-semmed module is handed
the same numbers again, so a no-op rebuild (e.g. a touched file) reproduces its
artifacts; a module that needs more numbers than before gets fresh ones above
the high-water mark and can never collide with a value that an unchanged, cached
module already embeds. Values are therefore unique but, unlike under ``nim c``,
neither dense nor ordered by import order, and a clean build need not reproduce
the values of an incremental one.

The driver: graph construction (`commandIc`)
============================================

1. Stamp/​wipe the cache by ``icFormatVersion``.
2. Seed the graph with the root module and **`system.nim`**. `system`'s entire
   import closure is folded into one node (one `nim m` invocation) — see
   *single-writer* below.
3. ``traverseDeps`` runs ``nifler`` per module and reads ``.deps.nif`` to add
   import edges.
4. **SCC grouping**: strongly-connected import cycles are collapsed (Tarjan).
   A singleton compiles as ``nim m <mod>``; a cycle compiles as one
   ``nim m <rep> --icGroup:<member>…`` that builds every member *from source* in
   one process (resolving the recursion in memory) and writes each member's NIF.
   Only edges *leaving* the component become build-graph inputs.
5. **Discovery fixpoint**: write the build file, run ``nifmake``; if it fails,
   re-derive the graph from every module's ``.s.deps.nif`` (adding nodes/edges
   for imports the static scanner missed), and retry. See *Discovery*.
6. The backend step (`nim nifc`) depends on every module's semmed NIF, so
   ``nifmake`` runs it last.

Invalidation: the cookie system
================================

A dependent must re-sem only when a dependency's relevant surface changed. Two
hashes per module (``ast2nif.nim``):

- **iface cookie** (``.iface.nif``): hashes only the *importer-visible* surface —
  exported declarations' **signatures** (for *all* routine kinds: plain procs,
  templates, macros, generics, `inline` procs alike), full content for
  consts/types, plus import/export/replay/hook records. Routine **bodies are
  excluded.** It also chains in the iface cookies of its own dependencies, so a
  surface change anywhere in the import closure propagates. A `nim m` rule for a
  module depends on its dependencies' iface cookies, so a body-only edit moves no
  iface cookie and stops the re-sem cascade.
- **impl cookie** (``.impl.nif``): hashes the *entire* serialized content (private
  defs and bodies included), with the module's own iface mixed in.

**NeedsImpl edges** (``.edges.nif``): if a module *consumed another module's body*
during sem — a macro expansion, a generic instantiation, a `getImpl`, or a
compile-time call run in the VM — it records a strong edge. The dependent is then
gated on that dependency's **impl** cookie instead of its iface cookie, so e.g.
`const x = dep.foo()` re-sems when `foo`'s body changes. Recording sites:
`semExprs.semTemplateExpr` (templates), `seminst.generateInstance` (generics),
`vmgen.genProc` (VM/macros/CT procs), `vm.opcGetImpl` (`getImpl`). Inline
iterators and `inline` procs are *not* tracked — they are inlined at codegen,
where the backend's NIF-mtime invalidation re-codegens their users.

Discovery of macro-generated imports
====================================

The static scanner only sees syntactic `import`s. A macro can synthesize one
(chronicles does `parseStmt("import chronicles/textlines")` driven by the
`chronicles_sinks` define). Such an import is invisible until sem runs the macro.
Each `nim m` records the imports it *actually* resolved (via the
``semdata.addImportFileDep`` hook → ``graph.importDeps`` → ``ast2nif.writeSemDeps``)
into ``<s>.s.deps.nif``; a child that fails on a not-yet-built import flushes it
before erroring. The driver re-derives the graph from those sidecars — adding the
missing node + the importer→import edge — and reruns to a fixpoint. (This replaced
an earlier `icmissing.txt` side channel.)

The backend: per-module `nifc` stages
=====================================

Codegen is no longer one whole-program process. ``nim nifc`` (`cmdNifC`,
``compiler/nifbackend.nim``) is invoked once per **stage** via
``--icBackendStage:<stage>``; `commandIc` emits these as ordinary `nifmake` rules
so "which TUs rebuild" is just "which rules `nifmake` re-fires from input mtimes"
— exactly as the frontend already works. There are four stages:

1. **`cg`** (``--icBackendStage:cg --icBackendModule:<suffix>``) — generate C for
   the *single* named module and write only its ``<s>.c.nif`` artifact. A non-main
   target loads only its own import closure (`loadDepClosure`), so the whole
   program is **not** pulled into every parallel `cg` process. Codegen is still
   demand-driven and **emit-everywhere**: a `cg` process emits every entity it
   demands (generic instances, hooks, RTTI), referencing nothing `extern`-only.
   There is no whole-program DCE here — a liveness pass over all ~260 NIFs would
   cost ~900 MB for a result the merge stage recomputes anyway. The **main**
   module's `cg` is special: it loads everything (`loadBackendModules`), emits the
   whole-program method dispatchers and `NimMain`, and registers every other
   module's init/datInit from the `.c.nif` meta heads — so it runs *last*, after
   every other ``.c.nif`` exists. Every `cg` rule always leaves a ``.c.nif`` (empty
   if the module owns no code) so its nifmake output exists and the rule settles.
2. **`merge`** (``--icBackendStage:merge``) — a pure artifact pass, *no module
   graph loaded*. Reads every ``.c.nif``, computes the one program-wide live set
   and, for each unique definition that several `cg` processes emitted, the single
   artifact allowed to embed its body; writes that to a merge-decision file
   (`computeMergeDecision` / `writeMergeDecision`). This is the cross-process
   replacement for the old in-process first-claimant + DCE coordination.
3. **`emit`** (``--icBackendStage:emit --icBackendModule:<suffix>``) — render the
   target module's final ``.c`` from its ``.c.nif`` and the merge decision
   (`renderCFromArtifact`, dropping globally-dead and non-owned bodies). No codegen
   runs; the target is loaded only so `getCFile` yields the path `cg` wrote.
4. **`link`** (``--icBackendStage:link``) — register every module's emitted ``.c``
   and run `extccomp.callCCompiler` once (it parallelizes per-file cc and skips
   up-to-date objects). Per-module C compile/link directives (`{.passL.}` etc.) are
   re-collected here via `replayBackendActions`, since the `cg` processes that
   originally saw them are separate processes (without this, e.g. `math`'s `-lm`
   would be lost → undefined `floor`/`pow` at link).

Because each stage is a `nifmake` rule keyed on file mtimes, a body-only edit to
one module re-fires that module's `cg`+`emit` (and the `merge`/`link`), not the
whole program — and an unchanged module's `cg` does not run at all.

Edge cases (and why the machinery exists)
=========================================

- **Single-writer.** Instance type-ids are minted in process-local order, so if
  two `nim m` processes both write a module's NIF (e.g. a stdlib module pulled
  into `system`'s from-source closure *and* given its own rule), the second
  overwrites with different ids and every module checked against the first carries
  dangling refs ("symbol has no offset"). Fixed by folding `system`'s closure into
  one SCC and by **forwarding the project's defines** to every child so their
  `when` bodies (hence import sets and NIF contents) match the scanner's.
- **`when … else: import`.** nifler emits `else`-branch imports unguarded, so a
  dead `else: import` would be scheduled. The compiler's own sources were rewritten
  to explicit negated `when`s; the vendored nifler later learned to negate prior
  conditions for the `else`.
- **`nil` sons of loaded ASTs.** NIF dot-tokens load as `nil` where from-source
  ASTs have `nkEmpty`; several passes gained `nil` guards.
- **Sealed loaded types.** Loaded types are `Sealed`; sem/transform mutate via
  `unsealForTransform`/`copyType`, or -- where the copy must still answer to the
  original in the generic binding tables -- `exactReplica(idgen)`, which gives the
  copy its own `itemId` (so serialized replicas don't collapse) while inheriting
  the original's `bindingId`.
- **Methods/RTTI ownership.** RTTI and type-bound hooks are emit-everywhere at
  `cg` and deduplicated by the `merge` stage, like generic instances; the main
  module's `cg` owns the whole-program method dispatchers.
- **Config cost.** Each child re-parsing `nim.cfg` + re-running `config.nims` in
  the VM was ~80 ms; replaced by a precompiled `ic_config.cfg.nif` replayed in
  `loadConfigs` (`compiler/icconfig.nim`).
- **`koch bootic`** bootstraps the compiler through `--ic:on` (a 3-iteration
  fixed-point check). It writes its binary to ``bin/nim_ic`` and never clobbers
  ``bin/nim``.

Resolved by the rewrite
-----------------------

The whole-program backend's hand-rolled mini-`nifmake` — `computeModuleReuse`,
`enforceDefRetention`, `redirectToLiveModule`, the cached-defs/claim bookkeeping
and the standalone `dce.nim` — **is gone**. Reuse is now just per-rule `nifmake`
mtime checks, and the single-writer decision is the `merge` stage. The old
**cross-mm / `--force` `var not init`** hazard dissolved with it: every codegen
rule's config (including `--mm`) is a declared `nifmake` input, so a stale-config
TU is simply rebuilt rather than mixed in. `koch bootic` is green under both `orc`
and `--mm:refc`.

Known residual hack
-------------------

- `deps.runNifler` still uses `setLastModificationTime` to mark its scan
  up-to-date and deletes a stale parsed file to coordinate with the nifmake nifler
  rule — the driver duplicating nifmake's freshness logic. It is explicitly
  flagged in the source and folds away with a full frontend/nifler split.

Status and performance
======================

IC self-builds the compiler (`koch bootic`'s byte-identical fixed-point
check) under both `orc` and `--mm:refc`, and passes the external-package CI set.

Cold full bootstrap on a 32-core box (`-d:release`, **no edits** — IC's worst
case, since incremental reuse is not exercised):

| | wall | notes |
| - | ---- | ----- |
| `koch boot` (classic) | ~1m00s | reference |
| `koch bootic` (`--ic:on`) | ~1m39s | **~1.66×** |

This is down from ~7.5× in the whole-program-backend era. IC does modestly more
aggregate work (more processes, NIF re-parsing of imports per process), but on a
many-core box that overhead is absorbed by the parallel `nim m`/`nifc` fan-out,
and the C compile+link floor is shared with the classic backend. On few-core
machines the cold gap is correspondingly wider — IC trades single-build latency
for incremental latency.

The cold number is the *least* favourable comparison: it pays IC's full per-process
overhead while using none of its incremental machinery. **Warm rebuilds — the
actual point of IC — recompile only the modules whose inputs changed** (a body-only
edit re-fires one module's `cg`+`emit`, not the program), so an edit-driven rebuild
is a small fraction of either full build.

The strategic direction (decided 2026-06-13) is to make this NIF backend
(`cmdNifC`) the **default** code generator. The per-module pipeline above is the
realization of that direction; remaining work is *promotion + deletion* of the
classic path, not new machinery.

Design notes and open decisions
===============================

The per-module backend (above) mirrors Nimony's ``src/nimony/deps.nim``: the
backend stopped re-implementing `nifmake`; each stage is a build rule, so reuse is
just mtime checks and the merge stage is the only cross-module coordination.

Settled vs. open:

- **Ownership.** Emittable entities (generic instances, type-bound hooks, RTTI,
  lifted procs) are emit-everywhere at `cg` time and deduplicated at `merge` time
  (smallest claimant owns each unique body). The earlier idea of a *static*
  per-suffix owner computed before codegen was not needed — content-addressed names
  make the merge decision deterministic. The precise owner *rule* (minting module
  vs. root-type's module) can still be tuned where it would force a downstream
  package to own stdlib code.
- **Remaining cleanup.** The `runNifler` `setLastModificationTime` coordination
  (above) folds away with a full frontend/nifler split; dead `when` imports could
  also be pruned during the `.s.deps` re-derivation.

Validation bar (held on every change): `koch bootic` must reach its byte-identical
fixed point, and binary size must not regress (DCE parity), across the
external-package CI set.

Further possible improvements
=============================

A warm-edit profiling pass (2026-07-02, self-compiling the compiler into a
dedicated `--nimcache`, editing one private proc body — `internalErrorImpl` — in
the hub module `compiler/msgs.nim`) surfaced where a **hub-module** warm rebuild
actually spends its time. The result refines the "a body-only edit re-fires one
module" claim above: that holds for the *backend*, but the *frontend* can still
cascade.

Measured: no-op `0.05s`; hub body edit `~15s`, split **~13s frontend / ~1.6s
backend**. Editing a body in a leaf (few importers) is fast; editing a body in a
widely-imported module is not, and the cost is almost entirely frontend re-sem.

- **Frontend over-invalidation (the dominant hub-edit cost).** Editing *any* body
  in a module — even a private routine that is only ever *called* — flips that
  module's whole-module **impl cookie** (`writeImplCookie` hashes the entire
  serialized module). Every module carrying a **NeedsImpl** edge on it then
  re-sems, even though the symbol it actually consumed is unchanged (e.g. a
  dependent that expanded the `internalError` *template* needs the template body,
  which is untouched; it does **not** need `internalErrorImpl`'s body). In the
  msgs edit this re-fires **57** `nim m` processes. A `.s.bif` mtime diff *hides*
  this — `.s.bif` is content-stable, so a re-semmed-but-identical module keeps its
  timestamp; count actual `nim m` PIDs to see the fan-out.

  The precise fix is **per-symbol NeedsImpl gating**: record which *symbols'*
  bodies a dependent consumed (the recording site `modulegraphs.recordIcImplDep`
  already receives the `PSym`; it currently coarsens to `module(s.itemId)`) and
  gate the dependent
  on only those. The obstacle is that `nifmake` gates on file mtimes, so
  per-symbol granularity needs either many cookie files or a bucketing scheme, and
  "which bodies are compile-time-consumable" is entangled with `getImpl` and the
  CT call graph (a macro that runs a private helper at CT *does* consume its body).
  A conservative narrowing — keep template/generic/macro/`sfCompileTime` bodies
  (plus `getImpl` targets) in the impl cookie but drop ordinary runtime routine
  bodies — captures the common "edit a private implementation proc" case, at the
  cost of proving the exclusion is complete.

- **Serial re-sem chains.** The 57 re-sems above run essentially **one at a time**
  despite `--parallel`, because the core modules they belong to form a deep import
  *chain* and `nifmake`'s depth-barriered scheduler runs one depth level at a time
  (≈1 node per level). This is independent of the invalidation problem: even
  perfect per-symbol precision leaves a serial tail whenever the re-sem set is a
  chain. Mitigations live in the scheduler (content-stability already stops the
  cascade at one level, but does not flatten the chain).

- **Emit stage need not load the module graph (done).** `generateEmitStage` used
  to `loadDepClosure`/`loadBackendModules` — materializing a module's whole
  transitive import closure as `BModule`s — solely to reach `getCFile(bmod)` for
  the output path. `renderCFromArtifact` is pure text filtering over the `.c.nif`
  plus the merge decision; it needs none of that. Deriving the `.c` path directly
  from the suffix (the same pure computation `deps.backendCFile` uses to *declare*
  the stage's output) lets an `emit` process load nothing. Under the
  fire-all-every-edit `emit` barrier (see below) this halved backend CPU
  (user-time `51s → 24s` on the msgs edit); wall-clock barely moved because the
  frontend dominates, but the reduced CPU/RAM contention matters when an editor is
  running alongside. `koch ic` stays byte-identical.

- **Do NOT make the merge decision content-stable.** A tempting frontend to the
  above: `emit` re-fires for *every* live module whenever `merge` rewrites the
  decision file's mtime (deliberate — a decision change must re-render every `.c`
  consistently). Writing the decision `OnlyIfChanged` (with a stamp output so the
  `merge` rule is not perpetually stale) makes a warm no-op instant, but a real
  edit then fires `emit` only for the modules whose `.c.nif` changed — and that
  produces **multiple-definition link errors** even when the decision is
  byte-identical. Fire-all `emit` is a correctness invariant, not just insurance
  (see the comment at `generateEmitStage`): partial `emit` leaves inconsistent
  ownership across the `.c` set. This path was tried and reverted; do not retry.

Where a cold build's time is (measured)
---------------------------------------

Numbers from `-d:icBNodeProf` (`compiler/icprof.nim`; each process appends a
line to `$NIM_IC_BNODE_PROF` tagged `stage=<name>`), on Atlas, 204 modules,
cold, 2026-08-31. They are recorded here because two obvious optimisations
were tried against them and did not pay.

Per stage, summed process wall, parallel build of 9.66s elapsed:

| stage | procs | wall |
| ----- | ----- | ---- |
| frontend (`nim m`) | 181 | 10.60s |
| lower | 14 | 4.49s |
| cg | 14 | 4.50s |
| merge | 1 | 0.20s |
| emit | 14 | 0.42s |
| link (the whole C compile + link) | 1 | 1.65s |

A `nim m` process splits as: startup 2%, loading imported `.s.bif` 46%,
writing its own `.s.bif` 18%, sem + parse 34% — two thirds of the frontend is
artifact I/O. The loading is not concentrated anywhere (`BifLoad` 695ms,
`PosIndex` 519ms, `ModuleId` 841ms, `TopLevel` 1459ms = offers 569 + export
branch 312 + log ops 137 + the bare cursor walk ~371); it is 180 processes each
re-parsing ~20 modules' interfaces out of 44.7MB of `.s.bif`, i.e. the
amortisation problem that batching solved for the backend
(`loadDepClosure` 10.2s -> 1.3s) and the frontend has not solved.

- **Hidden interface stubs** were 1.05s of that loading (1.70M stubs against
  0.29M exported ones) and are now built on demand
  (`modulegraphs.ensureHiddenIface`). A module has TWO FileIndexes — the NIF
  suffix's `fikNifModule` entry keys `DecodeContext.mods`, the source file's
  keys `g.ifaces` — so the lazy builder takes a suffix.
- **The tooling-only header records** (`sig`, `expansion`, `modulesrc`) are
  80% of every module header the loader walks (3.36M of 4.19M nodes) and
  skipping them entirely was measured at 53ms: `skip` on a `TagLit` is a
  jump, ~16ns a node. Not worth a format change.
- **The C compiler** is the largest CPU item (12.2s against a whole-program
  build's 10.2s) and the smallest wall lever: it fans out across cores, and the
  excess over a whole-program build is ~0.4s of wall. 3.8MB of the 5.4MB of
  extra C is per-TU prototypes and typedefs, intrinsic to 204 translation units
  instead of 139; 53 of the 204 object files define nothing and compiling all
  of them costs 0.23s of user time. Fewer, larger TUs is the only real fix and
  trades directly against what IC exists for.
- **Reading routine bodies off a `.bif` cursor instead of a `PNode`** was
  built and measured (branch `araq-ic-fixes2`, removed again in
  `araq-ic-fixes3`): it reached parity with the tree, not a win, and could
  only ever have saved `transformBody` + the body hand-off — under 1% of the
  build. The lasting result of that work is the loader's `oldLineInfo`
  memoization, which halved a cold `--ic:on` build, and the cgen files'
  iterator/named-accessor vocabulary (`sons`/`sonsFrom`/`sonsButLast`,
  `firstSon`/`secondSon`/`son`, `baseClass`/`returnType`/`elementType`).

Code, logic & debugging
========================

Core modules:
- **`compiler/deps.nim`** — graph construction, SCC grouping, discovery fixpoint,
  build-file generation; `commandIc`.
- **`compiler/ast2nif.nim`** — AST↔NIF, the cookie hashes (`cookieSd`,
  `writeIfaceCookie`, `writeImplCookie`, `writeEdgesFile`, `writeSemDeps`).
- **`compiler/nifbackend.nim`** — the per-module backend stages (`generateCgStage`,
  `generateMergeStage`, `generateEmitStage`, `generateLinkStage`).
- **`compiler/cnif.nim`** — `.c.nif` artifact read/write, `computeMergeDecision`,
  `renderCFromArtifact`.
- **`compiler/icconfig.nim`** — precompiled config.
- **`compiler/pipelines.nim`** / **`modulegraphs.nim`** — pipeline integration and
  the graph state (`importDeps`, `icImplDeps`, `icCnifFiles`, `instDisambs`, …).

Manual workflow:
- Frontend a module: ``nim m --nimcache:nifcache path/to/mod.nim`` (writes
  ``.nif`` + cookies + ``.s.deps``).
- Backend is stage-based (a bare ``nim nifc main.nim`` errors — there is no
  whole-program fallback). The exact per-stage commands `nifmake` runs are in the
  ``*.backend.build.nif`` build file; rerun one directly against an existing cache,
  e.g. ``nim nifc --nimcache:nifcache --icBackendStage:cg --icBackendModule:<suffix> main.nim``
  to regenerate one module's ``.c.nif``, then ``--icBackendStage:merge`` /
  ``:emit`` / ``:link``.
- NIF and ``.c.nif`` files are text — open/grep them directly; ``diff`` two
  successive ``.nif`` to see why a module rebuilt.
- Force a re-sem: delete the module's ``.nif`` and rerun `nim m`.
- A stale-cache crash after editing the serialization layout means bumping
  ``icFormatVersion`` (`compiler/options.nim`).

See also
========

- NIF format spec: [nifspec/doc/nif-spec.md](../nifspec/doc/nif-spec.md)
- NIFC (C-like target) spec: dist/nimony/doc/nifc-spec.md

Testing IC
==========

Two mechanisms, at very different scales.

**`tests/ic` — metamorphic tests.** A `t*.nim` whose body contains `#? metamorphic`
drives a sequence of cross-module edits through the IC driver in one fixed build
directory (see `testament/categories.nim`, `runMetamorphicIcTest`). Directives:

| directive | effect |
| --------- | ------ |
| ``#!FILE <name>`` | (re)write a module in the virtual file system |
| ``#!DELETE <name>`` | remove a module, from the vfs and from disk |
| ``#!FLAGS <switches>`` | change the compiler switches from here on |
| ``#!STEP <attrs>`` | materialise the files, build, run, check |

Step attributes: ``expect: <stdout>``, ``fails: <substring>`` (BOTH compilers must
reject it, with that text), ``noop``, ``body-edit``, ``iface-edit``,
``modules: <n>``, ``clean``, ``no-oracle``.

Every successful step is **also compiled with `nim c` and run, and the two
outputs must agree**. That oracle is the only check in the suite that is not
IC-against-IC: `clean == incremental`, `noop changes nothing` and the cookie
invariants are all satisfied by an IC that is *consistently* wrong, which is how
two silent miscompilations survived (a NIF-loaded module's `sfInjectDestructors`
was lost, so top-level destructors were never injected; `nfFirstWrite`/`nfLastRead`
had nowhere to live on a serialized sym node, so every first assignment to a
destructor-bearing local became `=sink` over zeroed memory). `koch bootic` has the
same blind spot — it proves the compiler reproduces *itself*.

**`testament --ic` — the whole corpus.** Appends `--ic:on` to every C and C++
test compile, so IC inherits the existing ~10k programs and their expected
output instead of the handful written for it by hand. Because it is a switch and
not a command, a test that overrides the command wholesale (`cmd: "nim cpp -r
$file"`) simply gains the switch — no verb rewriting, and the C++ corpus comes
along for free. Each also gets a private nimcache; without one they would share
a cache and thrash it.

To keep that affordable, testament borrows nimony's hastur model
(`warmupSharedCache` + `prefillFromWarmup`): a generated warmup program pulling in
`system` and the most-imported stdlib modules is compiled once per distinct
compile configuration into `nimcache/ic_warmup_<hash>`, and each test's empty
cache is seeded from it with **mtimes preserved** (nifmake compares
output-mtime > input-mtime, so stamping the copies "now" would re-fire the whole
graph). Only program-independent artifacts are copied — the frontend NIFs and
cookies plus the per-module `lower`/`cg` outputs. The `.c`/`.o` are deliberately
left behind: the merge decision (which module owns each emit-everywhere
definition) is whole-program, so those are re-rendered for every program anyway.

Measured on `tests/destructor` (97 test runs, 32-core box):

| | cold | warm |
| - | ---- | ---- |
| `nim c` | 35s | 32s |
| `--ic:on` | ~3m30 | **9.8s** |

The warm number is the developer loop and it is 3.2x faster than the classic
backend; the cold number is paid once per configuration and then cached on disk.
The disk cost is real and worth knowing: ~3.4 GB of nimcache for that one
category.

One property of an incremental compiler is worth spelling out because it looks
like a test bug: **a cached stage emits no diagnostics**. `--expandArc` output, a
hint, a warning — all of it is produced by the process that actually runs, so a
build that reuses every artifact prints nothing. Tests that check `nimout` (and
anything you are debugging by eye) therefore need a cold cache; running the same
test twice in a row makes the second run's `nimout` empty.

The C++ backend
===============

``nim cpp --ic:on`` works, and `tests/cpp` passes under it. Three things had to
change for that, and they are worth knowing because they are the shape of every
"C++ needs the whole program" problem the per-module backend has:

* **The driver must name the right file.** ``deps.nim`` DECLARES each module's
  translation unit to ``nifmake`` without loading a single module, so it cannot
  ask ``cgen.getCFile``; ``options.icCFileExt`` mirrors that formula at backend
  granularity (``.nim.cpp`` / ``.nim.m`` / ``.nim.c``).

* **C++ has no designated initializers**, so the RTTI record is a bare variable
  that ``DatInit`` fills field by field. That bare ``TNimTypeV2 x;`` is a
  tentative definition, which C's linker merges and C++'s does not — every TU
  that demanded the type defined it. It now gets the same extern-declaration +
  owned-``'d'``-definition split the C flavour has.

* **A C++ member is declared inside its class.** ``memberProcsPerType`` and
  ``initializersPerType`` live only in the sem process, so the backend emitted
  the struct WITHOUT its member declarations; they are replayed from a
  ``(repcppmember …)`` log entry now (``modulegraphs.replayCppMember`` re-derives
  the type from the routine's signature, exactly as ``semCppMember`` does).
  Two follow-on details: a member's ``loc.snippet`` is a CALL PATTERN
  (``#->salute(@)``), so it must be computed even in the TU that only *calls* the
  member (whole-program cgen got that for free by generating the defining module
  first), and it is not a linker name — every ``salute`` member in every class
  mints the same one, so definitions are keyed by their NIF name in the merge
  stage instead.
