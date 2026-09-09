# Native exceptions with the C backend

`nim c --exceptions:native program.nim` selects an experimental exception
implementation for the C backend. It requires GCC or Clang and a compatible
C++ compiler and runtime. Windows and hot code reloading are not supported.
The default exception implementation is unchanged.

The compiler continues to generate C and adds `-fexceptions` to compilation
commands. A small runtime, `lib/system/nativeexc.cpp`, is compiled as C++;
Nim's existing mixed-language build support selects the C++ linker driver.
When overriding compiler executables, also select the matching C++ linker,
for example:

```sh
nim c --cc:gcc --gcc.exe:gcc-16 --gcc.linkerexe:g++-16 \
  --exceptions:native program.nim
```

Each protected region becomes a C callback. A stack-allocated context holds
pointers to the caller's captured storage, including compiler temporaries and
ABI parameters. Mutations are visible to the caller without copying managed
values. Return, break, and continue use explicit callback results; the caller
performs the transfer after running the required finalizers. Handlers and
finalizers have their own boundaries so exceptions raised from called
functions also run cleanup and restore the exception state.

The C++ runtime throws a private tag and catches only that tag. Nim retains
ownership of exception objects in its existing thread-local exception chain.
The tag owns no Nim references. Typed handlers, re-raising, `defer`, and
compiler-inserted destructor finalizers use the same Nim semantics as other
exception modes. An uncaught Nim exception uses Nim's normal error reporting.
Arbitrary foreign C++ exceptions are not supported by Nim handlers or Nim
finalizers in this mode; use a C++ boundary to translate them before they
enter Nim code.

There is no `setjmp` or `longjmp` registration at a protected region. The
tradeoffs are additional callback functions, context initialization, calls,
and native unwind metadata. This mode does not promise a speedup for every
workload.

C libraries through which these exceptions propagate must also be built with
`-fexceptions`. GCC/Clang `cleanup` attributes then run during native unwinding;
Nim cleanup is implemented through the outlined finalizer boundaries.
`-funwind-tables` alone is insufficient. Cleanup functions must return normally;
they must not use `longjmp` to simulate a catch.

See the [GCC code generation options](https://gcc.gnu.org/onlinedocs/gcc/Code-Gen-Options.html),
[Clang exception option](https://clang.llvm.org/docs/CommandGuide/clang.html#cmdoption-fexceptions),
and [GCC cleanup attribute](https://gcc.gnu.org/onlinedocs/gcc/Common-Variable-Attributes.html#index-cleanup-variable-attribute).

To compare runtime costs with setjmp and goto on your machine, use
`python3 tests/benchmarks/exceptions/run.py --nim ./bin/nim_native` from a
source checkout. The benchmark reports normal-path, throwing, propagation,
and finalizer costs separately; see `tests/benchmarks/exceptions/README.md`.
