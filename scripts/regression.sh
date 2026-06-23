#!/bin/zsh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/build/KMLinkNative.app"
exe="$app/Contents/MacOS/KMLinkNative"
legacy_app="${KMLINK_LEGACY_APP_PATH:-$HOME/Library/MacKMLinkFull/MacKMLink.app}"
legacy_launch_agent="${KMLINK_LEGACY_LAUNCH_AGENT_PATH:-}"

if [[ -z "${KMLINK_REGRESSION_LOGGING:-}" ]]; then
  mkdir -p "$root/build/logs"
  timestamp="$(date +%Y%m%d-%H%M%S)"
  log="$root/build/logs/regression-$timestamp.log"
  export KMLINK_REGRESSION_LOGGING=1
  export KMLINK_REGRESSION_LOG="$log"
  "$0" "$@" 2>&1 | tee "$log"
  exit "${pipestatus[1]}"
fi

run_device=1
run_visible_hid_text=0
run_interactive_mouse=0
stop_app=0
restart_app=0

for arg in "$@"; do
  case "$arg" in
    --no-device)
      run_device=0
      ;;
    --with-visible-hid-text)
      run_visible_hid_text=1
      ;;
    --with-interactive-mouse)
      run_interactive_mouse=1
      ;;
    --stop-app)
      stop_app=1
      ;;
    --restart-app)
      stop_app=1
      restart_app=1
      ;;
    *)
      echo "unknown argument: $arg" >&2
      echo "usage: $0 [--no-device] [--stop-app] [--restart-app] [--with-visible-hid-text] [--with-interactive-mouse]" >&2
      exit 64
      ;;
  esac
done

run_step() {
  local name="$1"
  shift
  echo
  echo "==> $name"
  "$@"
}

run_probe() {
  local name="$1"
  shift
  run_step "$name" "$exe" "$@"
}

stop_legacy_app() {
  if [[ -n "$legacy_launch_agent" ]]; then
    launchctl bootout gui/$(id -u) "$legacy_launch_agent" 2>/dev/null || true
  fi
  pkill -f "$legacy_app" 2>/dev/null || true
  pkill -f "$legacy_app/Contents/PlugIns/GoBridgeDemon.app" 2>/dev/null || true
  sleep 0.3
  if pgrep -fl "$legacy_app" >/dev/null 2>&1; then
    echo "legacy.mackmlink.running: true"
    pgrep -fl "$legacy_app" || true
  else
    echo "legacy.mackmlink.running: false"
  fi
}

echo "KMLink Native regression"
echo "root: $root"
echo "log: ${KMLINK_REGRESSION_LOG:-none}"

if [[ "$run_device" -eq 1 ]]; then
  run_step "stop legacy MacKMLink app" stop_legacy_app
fi

if [[ "$stop_app" -eq 1 ]]; then
  echo
  echo "==> stop running KMLink Native app"
  pkill -f "$app/Contents/MacOS/KMLinkNative" 2>/dev/null || true
  sleep 0.3
elif [[ "$run_device" -eq 1 ]] && pgrep -fl "$app/Contents/MacOS/KMLinkNative" >/dev/null 2>&1; then
  echo
  echo "==> warning"
  echo "    KMLink Native app is already running; device probes may report transport-busy."
  echo "    Use --stop-app or --restart-app for a cleaner device regression."
fi

run_step "build app" "$root/scripts/build-app.sh"

run_probe "clipboard XML frame encode" --test-clipboard-encode
run_probe "clipboard GoBridge command encode" --test-clipboard-gobridge-encode
run_probe "clipboard receive decoder round trip" --test-clipboard-receive-decode

if [[ "$run_device" -eq 1 ]]; then
  run_probe "self test" --self-test
  run_probe "HID release burst" --test-hid-burst
  run_probe "HID mouse nudge" --test-hid-mouse-nudge
  run_probe "data receive probe" --test-data-rx-probe
  run_probe "data dummy send probe" --test-data-tx-dummy
  run_probe "legacy remote session probe" --test-legacy-remote-session
  run_probe "clipboard legacy send probe" --test-clipboard-send-legacy "KMLink Native regression"
  run_probe "clipboard native probe" --test-clipboard-send-initialized "KMLink Native regression initialized"
  run_probe "clipboard receive probe" --test-clipboard-receive
  run_probe "clipboard receive parse" --test-clipboard-rx-parse
  run_probe "diagnostics" --diagnose
else
  echo
  echo "==> device probes skipped (--no-device)"
fi

if [[ "$run_visible_hid_text" -eq 1 ]]; then
  run_probe "VISIBLE HID text input" --test-hid-type-text "KMLINK TEST"
else
  echo
  echo "==> skipped visible HID text input"
  echo "    run with --with-visible-hid-text only when Windows focus is in a safe text field"
fi

if [[ "$run_interactive_mouse" -eq 1 ]]; then
  run_probe "INTERACTIVE HID left click" --test-hid-mouse-click
  run_probe "INTERACTIVE HID scroll" --test-hid-scroll
else
  echo
  echo "==> skipped interactive mouse click/scroll"
  echo "    run with --with-interactive-mouse only when the Windows pointer is in a safe place"
fi

if [[ "$restart_app" -eq 1 ]]; then
  run_step "restart KMLink Native app" open "$app"
fi

echo
echo "regression complete"
echo "log saved: ${KMLINK_REGRESSION_LOG:-none}"
