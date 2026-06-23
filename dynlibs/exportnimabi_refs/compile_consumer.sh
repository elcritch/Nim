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

if [ ! -f "nimcache/producer_abi.nim" ] || [ ! -f "nimcache/producer.abi.h" ]; then
  echo "missing generated ABI artifacts; run ./compile_producer.sh first" >&2
  exit 1
fi

if [ ! -f "$libproducer" ]; then
  echo "missing producer library: $script_dir/$libproducer" >&2
  echo "run ./compile_producer.sh first" >&2
  exit 1
fi

rm -rf importcache

"$nim_compiler" c \
  --nimcache:importcache \
  --path:nimcache \
  --cincludes:"$script_dir/nimcache" \
  --passL:"$script_dir/$libproducer" \
  --passL:"-Wl,-rpath,$script_dir" \
  consumer.nim

echo "Built consumer: $script_dir/consumer"
