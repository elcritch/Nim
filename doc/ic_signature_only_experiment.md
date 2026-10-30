# Experimental signature-only lowered BIFs

## Semantic-body omission prototype

Building with both `-d:icSignatureOnly` and `-d:icSemanticSignatures` also
omits source-owned, non-generic proc and func bodies from semantic `.s.bif`
files, leaving an `icsemsigbody` marker. It uses a separate cache version.
Full semantic data is kept in a temporary directory during a build. On a later
build that needs it, the compiler re-semantically checks the module's source
using its recorded frontend command, including other members of its cyclic
group. It validates recovered data against a stored fingerprint before using
it, and deletes the temporary directory at the end of the build. A fingerprint
of the full semantic data is also included in the slim BIF, so a body-only edit
invalidates backend artifacts.

On an Apple M3 Pro, with release compilers, `--parallelBuild:4`, and separate
fresh caches for FigDraw `tests/ttransfer.nim`, two sequential cold builds of
the original compiler took 34.09 and 34.32 seconds. The prototype took 36.42
and 36.47 seconds. A no-op took 0.24 versus 0.22 seconds. After changing an
`echo` in a temporary copy of the test, an incremental build took 2.26 versus
16.13 seconds; the prototype needed to regenerate semantic data. The test was
compiled, not run.

| Persistent data | Original | Prototype |
| --- | ---: | ---: |
| 238 semantic BIFs | 54,405,566 bytes | 47,970,538 bytes |
| 238 lowered BIFs | 61,639,690 bytes | 49,471,409 bytes |
| BIF total | 116,045,256 bytes | 97,441,947 bytes |
| Recovery command sidecars | 0 | 1,137,869 bytes |
| Whole cache, including generated C and objects | 161,627,729 bytes | 144,153,931 bytes |

The semantic BIFs were 11.8% smaller; the combined BIFs were 16.0% smaller.
Temporary full semantic data consumes additional space during a build and is
not included in the persistent totals. A focused cross-module test also changed
a function used both at compile time and at runtime, and rebuilt to the new
value in both places. This is experimental: source recovery repeats semantic
checking and compile-time execution, may fail if a regenerated fingerprint
differs, and has not been validated against the full IC suite or all cyclic
imports and macro side effects.

Build the compiler with `-d:icSignatureOnly` to try the experiment. The
ordinary compiler and its cache format are unchanged; the experimental build
uses a distinct IC cache version.

The expanded cut omits the semantic AST body and transformed body of source-owned,
non-generic procs and funcs from their `.t.bif`; their signatures and an explicit
marker remain. Generic instances, templates, macros, iterators, methods, and
backend-minted routines are not in that omission set. During code generation,
the compiler loads the `.s.bif` closure and re-lowers each target module's owned
routines together, recreating nested closure environments and injecting hooks in
the same pass. Unchanged generated C/object files are reused by the existing IC
backend.

With only `-d:icSignatureOnly`, `.s.bif` still contains semantic bodies,
including those needed by compile-time execution and new generic instantiations.
Re-lowering occurs for every target whose code generation runs; a no-op build
can reuse existing objects without it.

## Expanded FigDraw results

On an Apple M3 Pro, with release compilers, `--parallelBuild:4`, and separate
fresh caches for `tests/ttransfer.nim`:

| Measurement | Original compiler | Expanded experiment |
| --- | ---: | ---: |
| Cold build | 35.57 s | 34.15 s |
| Semantic `.s.bif` data | 54,405,566 bytes | 54,405,566 bytes |
| Lowered `.t.bif` data | 61,639,690 bytes | 49,471,380 bytes |
| No-op rebuild | 0.29 s | 0.21 s |
| Edited copied-test rebuild | 2.39 s | 2.36 s |

The lowered files were about 20% smaller, and total semantic plus lowered BIF
data about 10% smaller. There were 238 files of each kind; 170 lowered BIFs
contained the omission marker. Timings are single runs, not a reliable speed
ranking. On a no-op, all 238 object files retained their timestamps in both
variants. After changing an `echo` in a temporary copy of the test, 237 objects
were unchanged and one changed in each variant. Removing one cached object and
the output executable caused both to be rebuilt and the output still matched.
All tested binaries produced matching output, including the source edit.

The expanded version originally failed FigDraw because locals in restored
nested procedure bodies could be mistaken for module symbols. Restoring those
definitions from the semantic BIF fixed the captured crash. Re-lowering a nested
closure on its own then failed the nested-iterator regression; re-lowering the
enclosing owned routines together fixed that case. The nested iterator, closure
hooks, generic-closure ownership, async and generic incremental tests pass with
the expanded version, as do the focused compile-time and nested-closure tests.
The full IC suite and peak aggregate memory have not been measured.

## First conservative cut

On an Apple M3 Pro with FigDraw `tests/ttransfer.nim`, release compilers, fresh
caches and `--parallelBuild:4`, the baseline clean build took 35.57 s; the
experimental build took 34.29 s. Among 238 lowered `.t.bif` files, four used
the marker and their combined size fell by 1,168 bytes (61,639,690 to
61,638,522 bytes). Both `.s.bif` sets totaled 54,405,566 bytes. The two builds
produced identical test output. These single runs do not establish a meaningful
speed difference; this narrow cut saves effectively no cache space on FigDraw.

Validation included a cross-module test covering omitted bodies, a compile-time
call, a generic and an inline proc, plus IC regressions for closure iterators,
converter re-exports and type offers. This remains experimental and is not a
general correctness claim for other bodies or build configurations.
