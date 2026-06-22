# exportnimabi hook wrapper example

This example exercises producer-side ABI artifact generation for an
`exportnimabi` library type with a custom attached hook.

From the repository root, build a compiler with the local changes:

```sh
./bin/nim c -d:release -o:compiler/nim-abi-test compiler/nim.nim
```

Then compile the example as a shared library and emit ABI artifacts:

```sh
rm -rf dynlibs/exportnimabi_hooks/nimcache \
  dynlibs/exportnimabi_hooks/importcache
./compiler/nim-abi-test c --app:lib --compileOnly \
  --nimcache:dynlibs/exportnimabi_hooks/nimcache \
  dynlibs/exportnimabi_hooks/producer.nim
```

The nimcache should contain:

```text
producer_abi.nim
producer.abi.h
producer.abi.json
```

Validate the generated Nim ABI module:

```sh
./compiler/nim-abi-test check \
  --nimcache:dynlibs/exportnimabi_hooks/importcache \
  --path:dynlibs/exportnimabi_hooks/nimcache \
  dynlibs/exportnimabi_hooks/nimcache/producer_abi.nim
```

Validate the generated C ABI header:

```sh
printf '#include "producer.abi.h"\n' > dynlibs/exportnimabi_hooks/nimcache/check_abi_header.c
cc -fsyntax-only -I"$PWD/lib" -Idynlibs/exportnimabi_hooks/nimcache \
  dynlibs/exportnimabi_hooks/nimcache/check_abi_header.c
```

Inspect the generated hook wrapper:

```sh
sed -n '1,120p' dynlibs/exportnimabi_hooks/nimcache/producer_abi.nim
```

You should see a normal attached hook wrapper named `=destroy` for `Resource`,
plus an unavailable `=copy` hook. The wrapper imports a generated
`NimAbiHookDestroy` thunk; the producer C keeps the real `=destroy` hook private
and exports the thunk.
