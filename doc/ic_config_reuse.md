# Opt-in configuration-aware semantic reuse

Build a compiler in the repository's `bin` directory, alongside `nifler` and
`nifmake`, then enable reuse for a project:

```sh
bin/nim c -d:release -d:nimIcConfigReuse -o:bin/nim_ic_config_reuse compiler/nim.nim
bin/nim_ic_config_reuse ic --nimcache:/tmp/project-ic -d:icConfigReuse project.nim
bin/nim_ic_config_reuse ic --nimcache:/tmp/project-ic -d:icConfigReuse -d:unused project.nim
```

`nim track` and the `--ic:on` driver use the same frontend gate. The compiler
build flag and project flag are both required. Omitting either retains ordinary
full-configuration cache selection. The first implementation uses POSIX file
locks; other platforms fall back to ordinary compilation. Reuse is experimental
and remains disabled by default.

A hit prints `IC config reuse: hit <group representative>`. A group with a known
unsupported observation prints a fallback reason. Other misses, including
missing candidates or incomplete input evidence, compile normally. A no-op
build normally launches no semantic children and therefore prints no hit lines.

## Restricted eligibility contract

This implements the plan's first conservative define-difference milestone.
It deliberately does not promote diagnostic `configtrace.json` or
`deptrace.json` files to complete manifests. Those files, and the isolated
synthetic-evidence checkers, retain their original contracts. The reuse path
has a separate producer and versioned store in `ic-config-variants-v1`.

A candidate can be published only after a successful semantic child has:

- Parsed exactly the independently scanned source/include set, with every
  captured input hash matching the bytes actually passed to the parser.
- Recorded every `options.isDefined` query in the process and all supported
  define-value queries, including reads in expanded templates and generics.
- Avoided macros, VM AST reflection and macro-cache operations, host VM callbacks,
  FFI, VM output/quit/diagnostic effects,
  `compiles` probes, source define/undef mutations, `compileOption` queries,
  compilation date/time, external compile/link pragmas and the other recorded
  untracked operations. Pure VM evaluation of constant functions is permitted.
- Loaded only dependencies in the independently scanned current graph. Every
  loaded BIF mapping hash and externally consumed interface-cookie hash must
  match the independently built current dependency snapshot. Every reachable
  dependency must have a current external-input status proving that it did not
  execute unknown host callbacks, FFI or other external-input operations.
- Produced all five required artifacts for every member of its compilation
  group: semantic BIF, interface cookie, implementation cookie, implementation
  edges and semantic imports.

Unknown or incomplete source/graph evidence produces a miss. For example,
macro-generated imports currently compile normally, and an over-approximated
conditional include set can prevent publication even when its artifacts would
have been compatible. Eligibility belongs to the entire semantic process/SCC,
including operations reached indirectly through imported compile-time code.

`compiles` is excluded because it can observe negative import resolution;
adding a previously missing file need not change a previously recorded positive
input. Host callbacks are excluded centrally at both VM callback dispatch
sites, rather than relying on a list of known filesystem/environment APIs.
Macro invocation and FFI are also excluded centrally. Pure arithmetic VM
execution uses the same compiler, base options and exact dependency bodies.
Successful children save a versioned `.reuse-inputs.json` context beside every
member's BIF. It contains the five artifact hashes, their file identities, and
direct dependency context IDs. Its content ID includes those dependency IDs,
so transitive input changes propagate even when a producer's own BIF is
unchanged. The queried define names and values are cached beside the BIF and in the
variant manifest; lookup compares them without rerunning semantic analysis.
The context is a required rule output when reuse is enabled, is removed before
a child starts sem and is regenerated after a hit. Missing, stale, malformed
or external-input statuses anywhere in the reachable dependency closure force
a miss. This also covers a dependency creating a new earlier-path import after
the driver scan: even an unchanged exported BIF cannot authorize consumer reuse
in that situation.

## Configuration and graph validation

The base key retains ordered non-define forwarded switches, ordered effective
config-file switches, resolved search/lazy/nimble paths, C defines, effective
options, language features, target, backend, memory management and exception
model. The compiler executable's SHA-256 and IC format version scope the store.
`release`, `danger`, `quick` and `nimQuirky`, including their undef switches,
remain in the base key because `commands.specialDefine` changes options while
processing them. Every setting not explicitly classified as an ordinary define
stays in the base key.

For each name queried by a successful eligible child, its initial effective
symbol-table presence and raw value are recorded. A new child must have the
same state for all recorded names. Target-derived aliases are fixed by the
base target. This is conservative: changing a present boolean's raw value can
miss even if its `defined` result remains true. Compiler setup additions such
as `nimcheck` are deterministic within the same base; recording the initial
state avoids confusing the driver's symbols with those added during sem.
Source mutations remain ineligible.

The define-read audit for this contract covers:

| Path | Treatment |
| --- | --- |
| `options.isDefined`, including compiler-internal callers | Process-wide name recording |
| `semexprs.semDefined` | Semantic observation plus central presence recording |
| `semfold.foldDefine` | Presence and raw value recording, including absent/default cases |
| `commands.specialDefine` | Names pinned to the base key |
| Driver symbol iteration and numeric scheduling switches | Current graph and scheduling only; backend retains full configuration |
| Backend-only numeric symbol reads | Backend retains full configuration |
| Define enumeration in dump commands | Not executed by semantic children |
| Configuration/NimScript symbol mutation | Effective config snapshot and base; conditional snapshots keyed by invocation |
| Source define/undef pragmas | Ineligible |
| VM config/define enumeration or other host callbacks | Ineligible |

New compiler define-read paths must extend this audit/instrumentation or pin the
corresponding setting to the base key before they can participate in reuse.

Each rule receives a driver-created plan containing its current resolved
source/include set, freshly resolved Nimble package identities, SCC membership
and complete reachable dependency set. Package checks use a private cache so
they cannot change the compiler's own lookup behavior.
Candidates never supply the current graph. The plan also fixes the original
entry point and main-module role, so this store does not introduce cross-project
sharing. Imported dependencies are scheduled and built by the existing driver
before the consumer's reuse check. Producers compute their artifact hashes
once; consumers compare saved direct dependency context IDs after checking
file identities. They do not rehash or walk the transitive closure on a hit.
Context sidecars are build-rule inputs as well as outputs, so changes refresh
consumer contexts through the DAG. This is more conservative than ordinary
interface/implementation-cookie gating: a body-only change invalidates a
consumer even if it never needed that body. Full dependency evidence is
checked when first publishing an eligible variant.

The driver now forwards resolved search paths in reverse insertion order and
omits the raw path arguments, preserving its lookup precedence in children.
Config snapshots are keyed by command-line invocation as well as source
staleness, so config files branching on defines cannot silently replay a
previous invocation's settings. An immutable copy of the resolved snapshot is
used throughout a reuse-enabled build.

## Publication, materialization and concurrency

Semantic input streams are captured once and parsed from those same bytes,
including source-filter directives. Imported BIF hashes cover the exact memory mapping consumed by the decoder
and lazy pools. Semantic writers publish by rename using `storeBifStable`;
they never rewrite a published BIF inode, so borrowed mappings remain stable. Interface
cookie observations record the actual bytes consumed during serialization.
These identities, rather than the diagnostic cookie samples, gate publication.
Standard-input and command-string projects are excluded from this file-input
contract.
Artifact digests are memoized in `ic-config-digests-v1`, keyed by path, inode,
size and nanosecond modification/change timestamps. Records include their own
checksum and are atomically published; corrupt or stale records are rehashed.
The BIF loader checks the file identity around mapping and only uses a cached
digest for that identity. Otherwise it hashes the exact mapping. This relies on
the coordinated atomic-write protocol, and avoids rehashing the same dependency
closure in every child. Source digests use the same file-identity cache;
publication also compares them with the exact bytes parsed. Package identities
are resolved once per driver discovery round, carried in each plan, and checked
for the child's own sources before reuse.

A variant is written into a unique private directory. Its manifest contains
source/dependency fingerprints, observed initial define states and hashes for
the entire group's artifacts. A `READY` digest is published last by rename.
Readers ignore interrupted directories, invalid schemas, missing files and
hash mismatches. Files copied from a candidate are read and verified before
any destination changes; no hard links or mutable references to shared
artifacts are installed.

Hits materialize into the active full-configuration semantic directory. Equal
artifacts keep their mtimes; the implementation-edge sidecar is always written
as nifmake's group freshness marker. This preserves discovery, IDE lookup and
backend paths without immediately recompiling a hit. Backend outputs and links
continue to use the full configuration and entry-point keys.

Drivers built with `nimIcConfigReuse` serialize config publication and active
cache access using a POSIX advisory lock beside the canonical cache directory.
Symlink spellings of the same cache use the same lock inode. The lock
is close-on-exec, is released on process termination and survives cache-format
resets because its inode is outside the cache. Parallel children still run
within a build, and different cache roots remain independent. On/off builds
using this compiler participate in the same lock. As with the existing IC
cache, direct artifact edits and older compiler binaries writing the same
active cache are outside this coordination protocol; use an isolated cache for
the experiment. Compile-time filesystem effects between modules require an
import dependency that orders them, as in the existing IC driver; untracked
writes between unrelated modules are outside that input model. Binary hashes are computed once by the driver; children verify
the executable's inode, size and nanosecond modification/change timestamps.

The variant namespace is independent of the diagnostic audit store. Opting in
does not migrate or clear caches. Existing IC format-reset behavior is unchanged.
The existing limitations of timestamp-based same-configuration rebuild detection
and arbitrary compile-time external inputs also remain; unsupported operations
are freshly compiled when a different configuration is selected.

## Validation

```sh
python3 tests/ic/config_reuse_test.py bin/nim_ic_config_reuse
bin/nim c -r --path:. -d:nimIcConfigReuse tests/compiler/ticconfigreuse.nim
bin/nim c -r --path:. tests/compiler/ticconfigmanifest.nim
bin/nim c -r --path:. tests/compiler/ticconfigbundle.nim
bin/nim c -r --path:. tests/compiler/ticbundleaudit.nim
```

The integration probe compares executed results with fresh full-configuration
builds. It covers unused define changes/removal, queried presence and values,
style-equivalent names, opposing switch order, nested import selection,
template expansion, compile-time-consumed dependency bodies, source/include
edits, cyclic groups, changed resolution after a new earlier-path file,
conditional config snapshots, target aliases/changes, separate main-module
contexts, non-define options and special defines, external
input/macro and mutation fallbacks, dependency-created shadow imports, malformed/corrupt/missing publication data,
no-op builds, frontend-only builds and concurrent configuration switches.
The unit test additionally exercises incomplete consumption evidence, whole
bundle verification before copying, missing required manifest fields, stale or
corrupt digest records, stable decoder mappings after atomic replacement,
cache-lock aliases, persisted define footprints after hits, transitive context
changes with identical producer BIFs, replaced artifacts and missing/changed
dependency external-input statuses.

A compiler built with both `nimIcConfigTrace` and `nimIcConfigReuse` also runs
the original `tests/ic/config_trace_test.py` probe. Diagnostic traces remain
explicitly incomplete, independently of successful restricted publications.

## FigDraw measurement

A FreeBSD amd64 run used FigDraw revision `2662543`, `nim track`, two semantic
jobs and isolated caches. Each configuration produced 248 semantic BIFs in
221 groups. These are individual elapsed-time observations, not a controlled
statistical benchmark; other validation processes ran on the host.

| Build | Elapsed seconds | Reused groups | Maximum process RSS, KiB |
| --- | ---: | ---: | ---: |
| Initial reuse-enabled configuration | 41.35 | 0 | 649356 |
| New unused define | 35.48 | 104 | 544564 |
| New `ShadowCount=5` configuration | 34.67 | 104 | 544540 |
| Return to original configuration | 0.10 | 0 | 16236 |
| Immediate no-op | 0.11 | 0 | 16324 |

All 248 BIFs in each configuration were byte-identical to its fresh ordinary
IC control. `ShadowCount=5` changed four module BIFs relative to the baseline.
An earlier ordinary-compiler control took 35.34 seconds for its first new
configuration, 29.43 seconds for another unused define, 29.42 seconds for
`ShadowCount=5`, and 0.03 seconds for a no-op. The cached-context implementation
reduced the earlier repeated-validation unused-define result from 42.30 seconds
to 35.48 seconds, but does **not** establish an overall speed improvement over
ordinary IC. Unsupported compile-time operations still require fresh semantic
work, and variant copying, metadata and discovery have overhead. Reuse remains
opt-in. RSS is the maximum reported process, not the sum of parallel children.

After the three configurations, logical file sizes were 289,508,975 bytes in
active configuration directories, 11,816,178 bytes in shared parse outputs,
41,880,569 bytes in the immutable variant store, and 1,452,068 bytes in the
digest cache. The store held 104 published group variants; it currently adds
storage alongside the existing per-configuration materializations rather than
deduplicating those active copies.
