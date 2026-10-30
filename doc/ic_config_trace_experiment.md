# Experimental module config trace

Build the compiler with `-d:nimIcConfigTrace` to write tab-separated
`IC_CONFIG_DEFINED` and `IC_CONFIG_VALUE` records to stderr. Records report
module name, queried define, and result; value queries also report an escaped
value when present. This is diagnostic instrumentation, not a cache manifest.
Module names alone are not unique identifiers, output from concurrent processes
can interleave, and values can contain sensitive configuration data.

The hooks cover `semDefined` and `foldDefine` only. They do not cover every
compiler-internal config lookup, VM callback, compile-time external input,
define mutation, or dependency attribution. They must not be used to decide
whether a cached artifact is safe to reuse. The compiler behaves as before when
built without the flag.

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
