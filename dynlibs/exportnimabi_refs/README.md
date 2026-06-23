# exportnimabi transparent ref example

This example exercises generated transparent `ref object` layout for a Nim ABI
producer and a Nim consumer.

From the repository root, build a compiler with the local changes:

```sh
./bin/nim c -d:release -o:compiler/nim-abi-test compiler/nim.nim
```

Build the producer shared library and emit ABI artifacts:

```sh
rm -rf dynlibs/exportnimabi_refs/nimcache \
  dynlibs/exportnimabi_refs/importcache

case "$(uname -s)" in
  Darwin) export LIBPRODUCER=libproducer.dylib ;;
  *) export LIBPRODUCER=libproducer.so ;;
esac

./compiler/nim-abi-test c --app:lib \
  --nimcache:dynlibs/exportnimabi_refs/nimcache \
  --out:dynlibs/exportnimabi_refs/$LIBPRODUCER \
  dynlibs/exportnimabi_refs/producer.nim
```

The nimcache should contain:

```text
producer.abi.c
producer_abi.nim
producer.abi.h
producer.abi.json
```

Run the Nim consumer end-to-end against the generated ABI module, generated C
header, and shared library:

```sh
./compiler/nim-abi-test c -r \
  --nimcache:dynlibs/exportnimabi_refs/importcache \
  --path:dynlibs/exportnimabi_refs/nimcache \
  --cincludes:"$PWD/dynlibs/exportnimabi_refs/nimcache" \
  --passL:"$PWD/dynlibs/exportnimabi_refs/$LIBPRODUCER" \
  --passL:"-Wl,-rpath,$PWD/dynlibs/exportnimabi_refs" \
  dynlibs/exportnimabi_refs/consumer.nim
```

The consumer calls `makeRenderer()` through the generated public proc wrapper,
which validates ABI expectations and initializes the producer. It then performs
ordinary Nim reads and writes on transparent `ref object` fields, including
managed fields (`string`, nested `ref`, and a custom-hook object field).

The generated Nim ABI module exposes `initProducerAbi()`. Public imported proc
wrappers call it automatically before forwarding to private mangled imports. The
producer library also exports `NimAbiInit_producer`, which compares generated
ABI expectations for artifact hashes, compiler/backend/runtime settings, layout,
hooks, and proc signatures, then calls `NimMain` exactly once on success.

Validate the generated C ABI header:

```sh
printf '#include "producer.abi.h"\n' > dynlibs/exportnimabi_refs/nimcache/check_abi_header.c
cc -fsyntax-only -I"$PWD/lib" -Idynlibs/exportnimabi_refs/nimcache \
  dynlibs/exportnimabi_refs/nimcache/check_abi_header.c
```

Validate the generated explicit init C entry point:

```sh
cc -fsyntax-only -I"$PWD/lib" -Idynlibs/exportnimabi_refs/nimcache \
  dynlibs/exportnimabi_refs/nimcache/producer.abi.c
```

Build and inspect the shared library:

```sh
case "$(uname -s)" in
  Darwin) nm -gU dynlibs/exportnimabi_refs/$LIBPRODUCER ;;
  *) nm -D dynlibs/exportnimabi_refs/$LIBPRODUCER ;;
esac | grep 'NimAbiInit_producer\|NimMain'
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
