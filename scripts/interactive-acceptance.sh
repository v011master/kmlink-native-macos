#!/bin/zsh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/build/KMLinkNative.app"
exe="$app/Contents/MacOS/KMLinkNative"
legacy_app="${KMLINK_LEGACY_APP_PATH:-$HOME/Library/MacKMLinkFull/MacKMLink.app}"
legacy_launch_agent="${KMLINK_LEGACY_LAUNCH_AGENT_PATH:-}"
dry_run=0
mac_to_windows_text="KMLink Native acceptance clipboard"
windows_to_mac_text="KMLink Windows acceptance clipboard"
keyboard_text="kmlink test"

for arg in "$@"; do
  case "$arg" in
    --dry-run)
      dry_run=1
      ;;
    *)
      echo "unknown argument: $arg" >&2
      echo "usage: $0 [--dry-run]" >&2
      exit 64
      ;;
  esac
done

if [[ -z "${KMLINK_ACCEPTANCE_LOGGING:-}" ]]; then
  mkdir -p "$root/build/logs"
  timestamp="$(date +%Y%m%d-%H%M%S)"
  log="$root/build/logs/acceptance-$timestamp.log"
  export KMLINK_ACCEPTANCE_LOGGING=1
  export KMLINK_ACCEPTANCE_LOG="$log"
  set +e
  "$0" "$@" 2>&1 | tee "$log"
  acceptance_status="${pipestatus[1]}"

  echo | tee -a "$log"
  if [[ "$acceptance_status" -eq 0 && "$*" != *"--dry-run"* ]]; then
    "$root/scripts/summarize-acceptance.sh" "$log" 2>&1 | tee -a "$log"
    summary_status="${pipestatus[1]}"
    exit "$summary_status"
  fi

  if [[ "$*" == *"--dry-run"* ]]; then
    echo "dry-run complete; summary skipped" | tee -a "$log"
    exit "$acceptance_status"
  fi

  echo "acceptance script failed before summary; log saved: $log" | tee -a "$log"
  exit "$acceptance_status"
fi

run_step() {
  local name="$1"
  shift
  echo
  echo "==> $name"
  if [[ "$dry_run" -eq 1 ]]; then
    echo "dry-run: $*"
  else
    "$@"
  fi
}

stop_legacy_app() {
  if [[ -n "$legacy_launch_agent" ]]; then
    launchctl bootout gui/$(id -u) "$legacy_launch_agent" 2>/dev/null || true
  fi
  pkill -f "$legacy_app" 2>/dev/null || true
  pkill -f "$legacy_app/Contents/PlugIns/GoBridgeDemon.app" 2>/dev/null || true
  sleep 0.3
}

emit_environment_state() {
  local phase="$1"
  local native_pids
  local old_pids

  native_pids="$(pgrep -fl KMLinkNative 2>/dev/null || true)"
  old_pids="$(pgrep -fl MacKMLink 2>/dev/null || true)"

  echo "$phase.executable.exists: $([[ -x "$exe" ]] && echo true || echo false)"
  echo "$phase.oldMacKMLink.running: $([[ -n "$old_pids" ]] && echo true || echo false)"
  if [[ -n "$old_pids" ]]; then
    echo "$phase.oldMacKMLink.processes:"
    printf "%s\n" "$old_pids"
  fi
  echo "$phase.kmlinkNative.running: $([[ -n "$native_pids" ]] && echo true || echo false)"
  if [[ -n "$native_pids" ]]; then
    echo "$phase.kmlinkNative.processes:"
    printf "%s\n" "$native_pids"
  fi
}

ask_yes_no() {
  local prompt="$1"
  local answer
  echo
  printf "%s [y/N] " "$prompt"
  read -r answer
  [[ "$answer" == "y" || "$answer" == "Y" ]]
}

record_result() {
  local name="$1"
  local answer
  local first_word
  local result
  local note

  while true; do
    echo
    printf "Manual result for %s (pass/fail/skip + optional note): " "$name"
    if ! read -r answer; then
      answer="skip"
    fi
    first_word="${answer%% *}"
    note=""
    if [[ "$answer" != "$first_word" ]]; then
      note="${answer#* }"
    fi

    case "$first_word" in
      pass|PASS|passed|PASSED|p|P)
        result="pass"
        ;;
      fail|FAIL|failed|FAILED|f|F)
        result="fail"
        ;;
      skip|SKIP|skipped|SKIPPED|s|S|"")
        result="skip"
        ;;
      *)
        echo "Please start the result with pass, fail, or skip."
        continue
        ;;
    esac

    if [[ -n "$note" ]]; then
      echo "manual.$name: $result $note"
    else
      echo "manual.$name: $result"
    fi
    break
  done
}

echo "KMLink Native interactive acceptance"
echo "root: $root"
echo "log: ${KMLINK_ACCEPTANCE_LOG:-none}"
echo
echo "This script is for Windows-side validation. It will ask before every visible"
echo "keyboard, mouse, or clipboard action."

run_step "stop legacy MacKMLink app" stop_legacy_app

run_step "environment preflight" emit_environment_state "preflight"

run_step "baseline non-interactive regression" "$root/scripts/regression.sh" --restart-app

run_step "environment post-baseline" emit_environment_state "postBaseline"

if ask_yes_no "Run visible keyboard test? Focus a safe Windows text field first."; then
  echo "Expected Windows result: focused field receives exactly: $keyboard_text"
  run_step "visible HID text input" "$exe" --test-hid-type-text "$keyboard_text"
  record_result "hid.visibleText"
else
  echo "manual.hid.visibleText: skip"
fi

if ask_yes_no "Run left-click test? Move Windows pointer to a safe clickable target first."; then
  echo "Expected Windows result: the selected safe target receives one left click."
  run_step "interactive HID left click" "$exe" --test-hid-mouse-click
  record_result "hid.leftClick"
else
  echo "manual.hid.leftClick: skip"
fi

if ask_yes_no "Run scroll test? Move Windows pointer over a safe scrollable area first."; then
  echo "Expected Windows result: the scrollable area moves."
  run_step "interactive HID scroll" "$exe" --test-hid-scroll
  record_result "hid.scroll"
else
  echo "manual.hid.scroll: skip"
fi

if ask_yes_no "Run Mac-to-Windows clipboard send? Prepare a Windows paste target first."; then
  echo "Expected Windows paste result: $mac_to_windows_text"
  run_step "legacy remote session probe" "$exe" --test-legacy-remote-session
  run_step "clipboard Mac to Windows send" "$exe" --test-clipboard-send-legacy "$mac_to_windows_text"
  record_result "clipboard.macToWindows"
else
  echo "manual.clipboard.macToWindows: skip"
fi

if ask_yes_no "Run Windows-to-Mac clipboard receive? The probe will wait; copy the expected text on Windows while it is running."; then
  echo "Expected Windows copied text: $windows_to_mac_text"
  echo "Copy this text on Windows after you see 'clipboard.receive.ready: true': $windows_to_mac_text"
  run_step "clipboard Windows to Mac receive/apply" "$exe" --test-clipboard-receive-apply --test-clipboard-receive-wait-seconds 35 --test-clipboard-receive-expected "$windows_to_mac_text"
  if [[ "$dry_run" -eq 1 ]]; then
    echo "mac.clipboard.preview: dry-run"
  elif command -v pbpaste >/dev/null 2>&1; then
    if mac_clipboard="$(pbpaste)"; then
      if [[ "$mac_clipboard" == "$windows_to_mac_text" ]]; then
        mac_clipboard_matches="true"
      else
        mac_clipboard_matches="false"
      fi
      echo "mac.clipboard.expected: $windows_to_mac_text"
      echo "mac.clipboard.matchesExpected: $mac_clipboard_matches"
      echo "mac.clipboard.preview: $(printf "%s" "$mac_clipboard" | head -c 160)"
    else
      echo "mac.clipboard.preview: pbpaste failed"
    fi
  else
    echo "mac.clipboard.preview: pbpaste unavailable"
  fi
  record_result "clipboard.windowsToMac"
else
  echo "manual.clipboard.windowsToMac: skip"
fi

echo
echo "acceptance complete"
echo "log saved: ${KMLINK_ACCEPTANCE_LOG:-none}"
echo "Summary will be appended by summarize-acceptance.sh."
