#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$script_dir"

nim=${NIM_NATIVE_DYNLIB_COMPILER:-"../../bin/nim"}

case "$(uname -s)" in
  Darwin) library="$script_dir/libproducer.dylib" ;;
  Linux) library="$script_dir/libproducer.so" ;;
  *) echo "unsupported platform" >&2; exit 1 ;;
esac

if [ ! -f "$library" ]; then
  echo "producer library not found; run ./build_producer.sh first" >&2
  exit 1
fi

"$nim" c -d:release --out:"$script_dir/generator" generate.nim
"$script_dir/generator" "$script_dir/nimcache" "$script_dir/producer.nim" \
  "$script_dir/nimcache/producer.abi.nif" "$library" \
  "$script_dir/generated/producer_abi.nim"

"$nim" c -r --mm:orc -d:useMalloc --out:"$script_dir/consumer" consumer.nim
