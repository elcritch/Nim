# Experimental signature-only lowered BIFs

Build the compiler with `-d:icSignatureOnly` to try the experiment. The
ordinary compiler and its cache format are unchanged; the experimental build
uses a distinct IC cache version.

The first cut omits both the semantic AST body and the transformed body of a
small set of simple, non-generic runtime procedures from their `.t.bif`. Their
signatures and an explicit marker remain. When code generation needs such a
procedure, it loads the semantic AST from the module's `.s.bif` and re-lowers
it. Templates, macros, generic and inline routines retain their existing bodies.
Unchanged generated C/object files are reused by the existing IC backend.

This is deliberately narrower than removing all cached procedure bodies:
`.s.bif` still contains the semantic bodies, and `.t.bif` still contains most
lowered bodies. The first cut tests whether restoring a small, safe subset works
before changing how the frontend obtains compile-time and generic bodies.

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
