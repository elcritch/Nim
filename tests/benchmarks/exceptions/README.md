# Exception implementation benchmark

Run from the repository root with a compiler that supports `--exceptions:native`:

```sh
python3 tests/benchmarks/exceptions/run.py --nim ./bin/nim_native
```

The runner builds the **same Nim source** as three executables with native,
setjmp, and goto exceptions. It prints a Markdown comparison table and saves
`results.md` and `results.json` in `nimcache/exception-bench/`. The JSON contains
individual samples, their range, exact build commands, build times, and executable
sizes. Builds are excluded from runtime measurements.

Options include `--cc clang|gcc`, `--mm arc|orc|refc`, `--samples 5`,
`--seconds 0.15`, `--depth 16`, `--payload reuse|fresh|both`, and `--out PATH`.
For an installed GCC on macOS, select its C compiler and matching C++ linker:

```sh
python3 tests/benchmarks/exceptions/run.py --cc gcc \
  --nim-flag=--gcc.exe=/opt/homebrew/bin/gcc-16 \
  --nim-flag=--gcc.linkerexe=/opt/homebrew/bin/g++-16
```

## Workloads

- **Plain:** a no-throw baseline with the same calls and arithmetic, without a
  caller's try/except region.
- **Try:** one try/except per operation, with no throws, one throw per 1024
  operations, or a throw on every operation.
- **Propagation:** the same rates, with 16 additional recursive calls between
  the catch and the leaf. These frames have no finalizers.
- **Finally each frame:** the recursive version with a counter increment in
  each frame's `finally`, including the depth-zero frame. At depth 16 this
  executes 17 finalizers per operation, on both normal and exceptional paths.

The throwing workloads run twice by default: once reusing a preallocated Nim
exception and once allocating a fresh exception on every throw. Reuse clears
its trace before each raise, preventing unbounded trace accumulation. That reset
and Nim's normal exception bookkeeping are included in the time. The fresh case
also includes payload allocation and reclamation. Native C++ exception runtime
allocation remains part of the native measurement in both cases.

## Measurement and correctness

The default build is release/ARC with checks, stack traces, line traces, and
threads disabled, and assertions enabled. All modes use the same settings and
C compiler. Non-inline calls, post-call arithmetic, and
`-fno-optimize-sibling-calls` preserve the requested call depth. LTO is not enabled.
User, parent, and project config files are skipped; the compiler's base config
still applies. Extra flags apply to all modes.

The input batch is deterministic and prepared before timing. Each batch contains
4096 inputs; the rare-throw workload has exactly four throws per batch. There is
no random generation, modulo operation, output, or timing call inside the hot
loop. Every input contributes to a checksum, including thrown operations.

Each process warms up for one batch before timing. The runner calibrates the
batch count for each mode/workload to the requested sample duration, then runs
samples sequentially in a reproducibly shuffled mode order. Different modes may
run different batch counts but repeat the same inputs and report nanoseconds per
**attempted operation**. Results use the median; raw min/max and samples remain
available for judging noise. No baseline subtraction is applied.

Each execution verifies its checksum, catch count, cleanup count, and empty
current-exception state after timing. Each executable also asserts its requested
exception mode at compile time and reports that mode at runtime. The runner
checks native runtime calls in the generated C. These checks guard against
optimizing away work, swallowing exceptions, dropping cleanup, or comparing the
wrong mode.

The results measure these small workloads, not application-wide performance.
Keep the machine idle, use the same compiler/allocator settings, and increase
`--seconds` or `--samples` when comparing close results. A no-throw row measures
normal-path overhead; only an every-call-throws row is also a cost per throw.

A single executable can also be invoked directly:

```sh
nimcache/exception-bench/exceptionbench-native try 100 16 1024 reuse
# Arguments: kind, rounds, depth, throw-every (0 = never), payload strategy.
```
