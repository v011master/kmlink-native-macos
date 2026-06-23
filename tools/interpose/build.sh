#!/bin/zsh
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
src="$script_dir/oti_senddata_logger.c"

build_one() {
  local arch="$1"
  local out="$script_dir/liboti_senddata_logger.$arch.dylib"
  clang -arch "$arch" -dynamiclib -O2 -Wall -Wextra -o "$out" "$src"
  echo "built $out"
}

build_one arm64
build_one x86_64

