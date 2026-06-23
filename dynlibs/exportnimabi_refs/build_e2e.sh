#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$script_dir"

repo_root="../.."
nim_compiler=${NIM_ABI_TEST:-"$repo_root/compiler/nim-abi-test"}

if [ ! -x "$nim_compiler" ]; then
  echo "missing compiler: $nim_compiler" >&2
  echo "from the repository root, run:" >&2
  echo "  ./bin/nim c -d:release -o:compiler/nim-abi-test compiler/nim.nim" >&2
  exit 1
fi

case "$(uname -s)" in
  Darwin) libproducer=libproducer.dylib ;;
  *) libproducer=libproducer.so ;;
esac

rm -rf nimcache importcache

"$nim_compiler" c --app:lib \
  --nimcache:nimcache \
  --out:"$libproducer" \
  producer.nim

"$nim_compiler" c -r \
  --nimcache:importcache \
  --path:nimcache \
  --cincludes:"$script_dir/nimcache" \
  --passL:"$script_dir/$libproducer" \
  --passL:"-Wl,-rpath,$script_dir" \
  consumer.nim

case "$(uname -s)" in
  Darwin) nm -gU "$libproducer" ;;
  *) nm -D "$libproducer" ;;
esac | grep 'NimAbiInit_producer\|NimMain'
