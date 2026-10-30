# FigDraw local configuration and dependency analysis

## Setup

The frontend was run on the actual `../figdraw` checkout at commit `2662543`
(`fix/siwin-upstream-abi`), with its existing Atlas `nim.cfg` and dependencies.
The host was FreeBSD amd64. The Nim compiler was built from this experiment
branch with `-d:nimIcConfigTrace`; the frontend entry point was
`src/figdraw.nim`, with `-d:icJobs=2` and an isolated cache at
`/tmp/figdraw-local-config-tracking/cache`. The drawing test was not run.
The FigDraw checkout remained clean.

The following `nim track` configurations completed:

| Configuration | Semantic BIFs | BIF bytes | Wall time |
| --- | ---: | ---: | ---: |
| Baseline | 248 | 91,447,664 | 29.83 s |
| Baseline plus `-d:icConfigTraceUnusedProbe` | 248 | 91,447,664 | 28.30 s |
| Baseline plus `-d:ShadowCount=5` | 248 | 91,447,188 | 28.34 s |
| Baseline plus `-d:figdrawTextBackend=harfbuzzy` | 252 | 94,443,461 | 30.69 s |
| Return to the populated baseline cache | 248 | 91,447,664 | 0.03 s |

Times are individual observations, with tracing enabled and filesystem caches
potentially warm. The return run used the existing baseline configuration cache;
it is not evidence of reuse across configurations. The different source
revision and dependency set explain why these counts should not be compared as
if they were the same build as the earlier detached-worktree experiment.

## Dependency graph

The baseline's 248 semantic BIFs correspond to 83 Nim standard-library files,
41 FigDraw source files, and 124 Atlas dependency files. The corresponding BIF
sizes are 13,230,532, 16,368,246, and 61,848,886 bytes respectively. Large
individual BIFs include `vulkan.nim` (22,354,839 bytes), `opengl.nim`
(9,703,595), and `vmath.nim` (7,847,302). Those sizes show where duplication
occurs; they do not establish that any of those artifacts can safely be shared.

The 248 decoded `.s.deps.bif` sidecars recorded 1,005 resolved import entries;
all referred to source files represented in this build. These are post-semantic
imports, not a complete list of every dependency relevant to reuse: implicit
system dependencies, includes, compile-time inputs, and implementation-consumption
edges also matter. The frontend build file contained 221 compilation groups:
219 single-file groups, a 26-file system-related group, and a three-file
Chronicles group. Group artifacts must be handled coherently.

`figbasics.nim` defines `ShadowCount`; `fignodes.nim` imports it and uses it
in the exported `RenderShadows` array type. The baseline semantic-import
sidecars show two direct importers of `figbasics`, and 10 direct importers of
`fignodes`. The latter are all FigDraw modules, including `figdraw.nim`,
`figbackend`, `figrender`, `renderfragments`, both renderer contexts, and four
drawing utilities. The sidecar graph does not by itself prove which importers
consume a type or implementation.

## Configuration comparisons

Adding the unused define produced 248 pairwise byte-identical semantic BIFs.
All 248 corresponding interface cookies, implementation cookies, implementation
edge sidecars, and semantic-import sidecars were also pairwise identical. This
shows duplicate artifacts in these two completed runs, not safe reuse: the
manifests are incomplete and do not validate all inputs or dependencies.

With `ShadowCount=5`, 244 BIFs remained byte-identical (87,250,812 bytes) and
four changed: `fignodes`, `figrender`, `renderfragments`, and `utils/drawutils`.
Eleven interface cookies and eleven implementation cookies changed, including
`fignodes` and its ten recorded direct importers. The semantic-import sidecars
were unchanged, but `figrender`'s implementation edge sidecar changed: its
recorded `fignodes` implementation edge was present in baseline and absent in
the changed run. The interface writer chains direct dependency cookies, and the
implementation writer incorporates the interface cookie; byte-identical BIFs
therefore do not make their accompanying metadata interchangeable. Independent
`nim check` assertions confirmed that `RenderShadows` has length 4 by default
and 5 with `ShadowCount=5`.

The default `figdrawTextBackend` is `pixie` in this checkout. Although the Atlas
config enables `feature.figdraw.harfbuzz`, the source selects the alternate
default using the different symbol `feature.figdraw.textBackendHarfbuzzy`.
Setting `-d:figdrawTextBackend=harfbuzzy` selected a different graph: five
modules appeared, including the Harfbuzzy text backend, glyph rasterizer, and
three Harfbuzzy package modules; the Pixie text-backend module disappeared.
Among the 247 common BIFs, six differed and 241 were byte-identical. Two common
semantic-import sidecars differed: `fontutils` selected the Harfbuzzy backend
instead of the Pixie backend, and `fontglyphs` gained the glyph-ID rasterizer.
The `fonttypes` BIF and its four compared sidecars stayed byte-identical even
though the trace recorded the changed define value and consumers selected new
branches. Independent `nim check` assertions confirmed the `pixie` and
`harfbuzzy` values. This case shows why a dependency's identical artifact alone
is insufficient to validate a consumer or its previous import graph.

The isolated config/dependency checker was also exercised using the saved
`fignodes` and `fonttypes` interface-cookie bytes. It rejected the changed
`fignodes` cookie. With the identical `fonttypes` BIF and interface cookie, a
synthetic complete observation of the old backend value was rejected against
the changed setting. The actual `fontutils` trace was rejected as incomplete.
The probe supplied its dependency-validation status and observation manually;
it does not prove that the production driver can validate or reuse either unit.

## Dependency snapshot probe

The diagnostic dependency snapshot was exercised on this checkout with fresh
`nim track` baseline and `ShadowCount=5` configurations in the isolated
`/tmp/figdraw-depsnap/cache`. Each run produced 221 process snapshots, all
incomplete, with 14,397 distinct per-process BIF-load samples and 961 recorded
interface-cookie reads in aggregate. These are process observations, not counts
of unique modules or independent dependency edges. In the baseline, every
recorded non-group `NeedsImpl` entry had a matching sampled BIF load; that is
an observation for this run, not a general coverage guarantee. For both configurations,
`figbackend` and `figrender` recorded `fignodes` as an import and sampled its
interface and implementation cookies; both sampled cookies changed between the
two runs. The process-level `NeedsImpl` set for `figrender` contained
`fignodes` in the baseline and omitted it with `ShadowCount=5`, consistent
with the earlier sidecar comparison. The drawing test was not run.

The samples are useful for examining the compilation, but they are not atomic
with BIF loads and do not establish complete dependency attribution or safe
cross-configuration reuse. See the trace experiment notes for the schema and
limitations.

## Coverage and ineligibility probe

A fresh baseline `nim track` run using version 2 config traces wrote 221
manifests. All marked every coverage area unknown and listed the corresponding
ineligibility reasons. Selected observed operations added `compileOption` in
81 processes, `compileOptionArg` in two, `staticRead` in two, and
`getProjectPath` in one. These are processes containing an observation, not
distinct source sites or a complete list of unsupported inputs. All 248
semantic BIFs matched the earlier baseline byte-for-byte. No drawing test was
run; the traces are not used for cache selection.

## Bundle checker probe

The isolated bundle checker was run on the `fignodes` source and copies of
its five baseline semantic artifacts. It rejected the real config trace as
incomplete. With synthetic claims of complete config and dependency evidence,
an assumed base key and an empty dependency set, it matched the supplied file
hashes; corrupting the copied interface cookie caused an artifact mismatch.
Those assumptions deliberately omit the module's real dependencies, so this
tests file validation only and does not establish that the module is reusable.

## Diagnostic bundle publication probe

Fresh `nim track` runs with `-d:icConfigBundleAudit` were made in an isolated
cache, once with the baseline settings and once with the unrelated
`icConfigTraceUnusedProbe` define. Each published 221 incomplete group copies
and skipped none. All groups had both config and dependency trace files; all
221 corresponding groups had matching hashes for every copied semantic BIF and
sidecar. The two sets of copied artifacts totalled 183,170,786 bytes. The
diagnostic reader verified the marker, metadata and copied-artifact hashes for
all 442 publications. This is evidence that the publisher captured duplicate
bytes, not a reuse result: neither run selected a published bundle, the input
observations remain incomplete, and files in the diagnostic store remain mutable. The drawing test
was not run.

## Trace limitations

The baseline emitted 221 process manifests, all marked incomplete. They include
observations of 294 distinct compiler `isDefined` lookup names. The selected
untracked-input hooks recorded six distinct `staticRead` source locations in two
process manifests: OpenGL shader reads and Vulkan shader reads. The source path
for the OpenGL template differs from its compilation context. The baseline
manifest recorded `ShadowCount` as absent, while the changed manifest recorded
it as present with value `5`.

These records cover selected operations, can aggregate multiple modules, and do
not establish complete macro, compiler-input, or dependency attribution. The
existing full-configuration cache remains in use. No cross-configuration reuse
was enabled or measured.
