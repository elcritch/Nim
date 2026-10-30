# Experimental LMDB backing for IC BIFs

Build the compiler with `-d:icLmdb` and an LMDB development library to store
uncompressed semantic and lowered module BIFs in LMDB. The normal compiler
keeps the existing file-backed cache. This experiment uses a separate IC cache
version and requires a fresh nimcache.

The benchmark used LMDB 0.9.33, built as a local static library. For example,
with the LMDB source at `/path/to/lmdb`, from the Nim checkout:

```sh
make -C /path/to/lmdb/libraries/liblmdb liblmdb.a
bin/nim c -d:release -d:icLmdb \
  --passC:-I/path/to/lmdb/libraries/liblmdb \
  --passL:-L/path/to/lmdb/libraries/liblmdb \
  -o:bin/nim-ic-lmdb compiler/nim.nim
```

The LMDB-backed artifacts use a database in `.ic-lmdb` under each artifact
directory. A small `.s.bif` or `.t.bif` marker is still written at the normal
path: nifmake and other IC checks use its existence and modification time.
Other BIF sidecars remain ordinary files. LMDB is opened once per directory per
process, with short serialized write transactions and read transactions retained
when a loaded BIF borrows mapped data. Because LMDB does not guarantee that a
value is aligned for the BIF reader, unaligned values are copied into aligned
memory instead and their read transactions are closed.

## FigDraw measurements

On an Apple M3 Pro, with release compilers and `--parallelBuild:4`:

| Measurement | Ordinary files | LMDB |
| --- | ---: | ---: |
| Clean `tests/ttransfer.nim` build | 34.50 s | 34.79 s, 34.73 s |
| No-op rebuild, 3 runs | 0.20–0.22 s | 0.20–0.21 s |
| Clean build of copied test | 35.53 s | 35.50 s |
| Rebuild after changing an `echo` in copied test | 2.31 s | 2.31 s |
| Module BIF content | 115,951,298 bytes | 119,848,960 bytes in 3 LMDB data files |
| Whole nimcache, filesystem usage | 170,148 KiB | 177,248 KiB |

The edited test was a temporary copy in FigDraw's `tests` directory, using
separate empty caches. Both variants passed and produced identical output, and
the changed output was verified. The source copy was removed afterward. These
are single cold and edited-rebuild measurements, except as shown; they do not
establish a general performance difference. Aggregate worker memory and write
lock contention were not measured. The earlier file-only runs were 40.06 and
40.33 seconds, illustrating that comparisons across runs can vary.

## Block-addressed prototype

Add `-d:icLmdbBlocks` alongside `-d:icLmdb` to try the alternative layout.
Each module is stored as a manifest containing its shared pools and symbol
index, plus 64 KiB token blocks. The manifest, all blocks and the module hash
are committed in one LMDB write transaction. A symbol lookup can load the
blocks containing its indexed subtree. Operations that scan a module rebuild
its contiguous token buffer from all blocks. The manifest and subsequent block
lookups use the same retained LMDB read transaction, so they see one module
version even if another process replaces it.

For the same FigDraw test on the same machine, after making the declaration
width lookup lazy:

| Measurement | Whole-BIF LMDB | Block-addressed LMDB |
| --- | ---: | ---: |
| Clean build | 37.76 s | 39.76 s |
| No-op rebuild, 3 runs | 0.20–0.22 s | 0.20–0.21 s |
| Edited copied test rebuild | 2.28 s | 2.34 s |
| LMDB data files | 119,914,496 bytes | 145,358,848 bytes |
| Whole nimcache, filesystem usage | 177,104 KiB | 208,648 KiB |

The clean and edited measurements are one run each. Both executables produced
the same output and the edit was verified. Before the lazy-width change, an
instrumented cold run counted 96,083 manifest loads, 95,992 full-token
reconstructions, and 64 partial declaration reads across 1,777 reporting worker
processes. Those counters count repeated loads in different processes, not
unique modules or physical disk I/O. The instrumented build copied about 17.9
GB of token data in aggregate across all workers; this is not peak memory.
Most of the compiler's current module-loading paths traverse the full module,
so the block representation does not avoid that work in this workload. The
initial block version took 46.14 seconds on another cold run.

The block format is experimental: whole-module fallback copies tokens instead
of borrowing a mapped BIF, and stale block keys are not removed when a module
shrinks. Its manifest and scheduler marker are still separate updates; the
limitations below apply. The instrumented build can be enabled with
`-d:icBlockStats`; it writes per-process `ICBLOCKSTATS` counters to stderr.

## Limitations

This is an opt-in experiment, not a production-ready cache. Retained read
transactions can delay page reuse while workers are alive, and a sufficiently
large build can exhaust the configured reader table or fixed map size (64 GiB
on 64-bit, 1 GiB on 32-bit). Database entries are not garbage-collected when
modules disappear. The database update and marker-file update are separate
operations; a crash between them can leave a stale marker. Standalone BIF
tools cannot read the markers, and IDE usage scans lose their cheap file-only
symbol probe. The benchmark was run only on macOS; cross-platform builds and
crash recovery have not been validated. LMDB requires a local filesystem with
the locking and mapping semantics it expects.
