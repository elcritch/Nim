# exportnimabi transparent ref example

This example exercises generated transparent `ref object` layout for a Nim ABI
producer and a Nim consumer.

From the repository root, build a compiler with the local changes:

```sh
./bin/nim c -d:release -o:compiler/nim-abi-test compiler/nim.nim
```

Compile the producer and emit ABI artifacts:

```sh
rm -rf dynlibs/exportnimabi_refs/nimcache \
  dynlibs/exportnimabi_refs/importcache
./compiler/nim-abi-test c --app:lib --compileOnly \
  --nimcache:dynlibs/exportnimabi_refs/nimcache \
  dynlibs/exportnimabi_refs/producer.nim
```

The nimcache should contain:

```text
producer_abi.nim
producer.abi.h
producer.abi.json
```

Compile the Nim consumer against the generated ABI module and C header:

```sh
./compiler/nim-abi-test c --compileOnly \
  --nimcache:dynlibs/exportnimabi_refs/importcache \
  --path:dynlibs/exportnimabi_refs/nimcache \
  dynlibs/exportnimabi_refs/consumer.nim
```

Validate the generated C ABI header:

```sh
printf '#include "producer.abi.h"\n' > dynlibs/exportnimabi_refs/nimcache/check_abi_header.c
cc -fsyntax-only -I"$PWD/lib" -Idynlibs/exportnimabi_refs/nimcache \
  dynlibs/exportnimabi_refs/nimcache/check_abi_header.c
```

Validate that direct C access is limited to ABI-POD field names:

```sh
printf '#include "producer.abi.h"\nvoid f(NimAbi_ZN8producer24RenderercolonObjectType_E *r){ r->size.x = 1.0f; r->scale = 2.0f; }\n' \
  > dynlibs/exportnimabi_refs/nimcache/check_pod_field_access.c
cc -fsyntax-only -I"$PWD/lib" -Idynlibs/exportnimabi_refs/nimcache \
  dynlibs/exportnimabi_refs/nimcache/check_pod_field_access.c
```

This managed-field probe should fail with "no member named 'name'" and "no
member named 'child'":

```sh
printf '#include "producer.abi.h"\nvoid f(NimAbi_ZN8producer24RenderercolonObjectType_E *r){ (void)r->name; (void)r->child; }\n' \
  > dynlibs/exportnimabi_refs/nimcache/check_managed_field_access_fails.c
cc -fsyntax-only -I"$PWD/lib" -Idynlibs/exportnimabi_refs/nimcache \
  dynlibs/exportnimabi_refs/nimcache/check_managed_field_access_fails.c
```

The generated Nim ABI module exposes public fields with their Nim names, so the
consumer can use ordinary Nim reads and writes such as `r.name = "imported"` and
`r.child.label = "nested"`. Managed fields are emitted in the C header with
compiler-owned names such as `nimAbiManaged_name`, so direct C code that tries
to write `r->name` is rejected by the C compiler.
