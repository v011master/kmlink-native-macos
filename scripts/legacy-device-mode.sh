#!/bin/zsh
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
root_dir=$(cd "$script_dir/.." && pwd)
tool_dir="$root_dir/tools/legacy-oti-mode"
binary="$tool_dir/OTiModeProbe.app/Contents/MacOS/OTiModeProbe"

if [[ ! -x "$binary" ]]; then
  "$tool_dir/build.sh" >/dev/null
fi

exec arch -x86_64 "$binary" "$@"
