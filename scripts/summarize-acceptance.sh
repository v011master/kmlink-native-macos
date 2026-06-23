#!/bin/zsh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
log="${1:-}"

if [[ -z "$log" ]]; then
  log="$(ls -t "$root"/build/logs/acceptance-*.log 2>/dev/null | head -n 1 || true)"
fi

if [[ -z "$log" || ! -f "$log" ]]; then
  echo "no acceptance log found" >&2
  echo "usage: $0 [build/logs/acceptance-YYYYmmdd-HHMMSS.log]" >&2
  exit 66
fi

required_markers=(
  "KMLink Native interactive acceptance"
  "==> stop legacy MacKMLink app"
  "==> environment preflight"
  "==> baseline non-interactive regression"
  "regression complete"
  "==> environment post-baseline"
  "==> visible HID text input"
  "==> interactive HID left click"
  "==> interactive HID scroll"
  "==> legacy remote session probe"
  "==> clipboard Mac to Windows send"
  "==> clipboard Windows to Mac receive/apply"
  "acceptance complete"
)

echo "KMLink Native acceptance summary"
echo "log: $log"
echo

result_status=0
step_contains_line() {
  local marker="$1"
  local expected_line="$2"

  awk -v marker="$marker" -v expected_line="$expected_line" '
    $0 == marker { active = 1; next }
    active && (/^==> / || $0 == "acceptance complete" || $0 == "KMLink Native acceptance summary") { exit }
    active && $0 == expected_line { found = 1; exit }
    END { exit(found ? 0 : 1) }
  ' "$log"
}

require_step_line() {
  local marker="$1"
  local expected_line="$2"

  if ! step_contains_line "$marker" "$expected_line"; then
    echo "step.success.missing: $marker -> $expected_line"
    result_status=1
  fi
}

require_global_line() {
  local expected_line="$1"

  if ! grep -Fxq "$expected_line" "$log"; then
    echo "line.missing: $expected_line"
    result_status=1
  fi
}

step_key_value() {
  local marker="$1"
  local key="$2"

  awk -v marker="$marker" -v key="$key" '
    $0 == marker { active = 1; next }
    active && (/^==> / || $0 == "acceptance complete" || $0 == "KMLink Native acceptance summary") { exit }
    active {
      needle = key ": "
      found_at = index($0, needle)
      if (found_at) {
        print substr($0, found_at + length(needle))
        found = 1
        exit
      }
    }
    END { exit(found ? 0 : 1) }
  ' "$log"
}

require_step_manual_pass() {
  local marker="$1"
  local key="$2"
  local value
  local first_word

  value="$(step_key_value "$marker" "$key" || true)"
  if [[ -z "$value" ]]; then
    echo "$key: missing"
    result_status=1
    return
  fi

  first_word="${value%% *}"
  echo "$key: $value"
  case "$first_word" in
    pass|PASS|passed|PASSED)
      ;;
    *)
      result_status=1
      ;;
  esac
}

if grep -q '^dry-run:' "$log"; then
  echo "dry-run: detected"
  result_status=1
fi

for marker in "${required_markers[@]}"; do
  if ! grep -Fxq "$marker" "$log"; then
    echo "marker.missing: $marker"
    result_status=1
  fi
done

require_global_line "preflight.executable.exists: true"
require_global_line "preflight.oldMacKMLink.running: false"
require_global_line "postBaseline.executable.exists: true"
require_global_line "postBaseline.oldMacKMLink.running: false"
require_global_line "postBaseline.kmlinkNative.running: true"

require_step_line "==> visible HID text input" "hid.typeText.succeeded: true"
require_step_line "==> interactive HID left click" "hid.mouseClick.succeeded: true"
require_step_line "==> interactive HID scroll" "hid.scroll.succeeded: true"
require_step_line "==> legacy remote session probe" "legacy.session.connected: true"
require_step_line "==> clipboard Mac to Windows send" "clipboard.legacyTx.succeeded: true"
require_step_line "==> clipboard Windows to Mac receive/apply" "clipboard.receive.succeeded: true"
require_step_line "==> clipboard Windows to Mac receive/apply" "clipboard.receive.decoded: true"
require_step_line "==> clipboard Windows to Mac receive/apply" "clipboard.receive.applied: true"

require_step_manual_pass "==> visible HID text input" "manual.hid.visibleText"
require_step_manual_pass "==> interactive HID left click" "manual.hid.leftClick"
require_step_manual_pass "==> interactive HID scroll" "manual.hid.scroll"
require_step_manual_pass "==> clipboard Mac to Windows send" "manual.clipboard.macToWindows"
require_step_manual_pass "==> clipboard Windows to Mac receive/apply" "manual.clipboard.windowsToMac"

if step_contains_line "==> clipboard Windows to Mac receive/apply" "mac.clipboard.matchesExpected: true"; then
  echo "mac.clipboard.matchesExpected: true"
else
  echo "mac.clipboard.matchesExpected: missing"
  result_status=1
fi

echo
if [[ "$result_status" -eq 0 ]]; then
  echo "acceptance: PASS"
else
  echo "acceptance: INCOMPLETE"
fi

exit "$result_status"
