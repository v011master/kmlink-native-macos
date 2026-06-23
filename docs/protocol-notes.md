# KMLink Native Protocol Notes

This file records the current evidence gathered from the installed MacKMLink bundle.

## Local Device

- USB product: `Android+Mac`
- Vendor/Product: `0EA0:2213`
- Device serial intentionally omitted from public notes.
- Existing app bundle: `com.oti.MacKMLinkWithGOBridge`
- Existing helper bundle: `com.oti.GoBridgeDemon`

## Existing Architecture

The installed software is x86_64-only and split into:

- `MacKMLink`: background UI, device detection, settings, accessibility prompts.
- `GoBridgeDemon`: event taps, local input posting, clipboard/file handling.
- `OTiTransfer.framework`: USB/SCSI transport layer.
- `KMKeyMouse.dylib`: keyboard/mouse event capture and switch logic.
- `KMClipboard.dylib`: clipboard bridge.

## Important Symbols And Strings

The OTi transport framework exports these function names:

- `OTi_Open`
- `OTi_Close`
- `OTi_ReadData`
- `OTi_SendData`
- `OTi_SendHIDPacket`
- `OTi_ReadDevicesInfo`
- `OTi_SetDeviceMode`
- `OTi_GetDeviceMode`
- `OTi_GetSideType`
- `OTi_USBRestart`

Strings indicate the transport is implemented over SCSI commands:

- `SendSCSICommandReceiveData`
- `SendSCSICommandSendData`
- `SCSITaskDeviceCategory`
- `SCSITaskAuthoringDevice`
- `IOUSBInterfaceUserClientV2`

Keyboard/mouse strings indicate event tap based capture:

- `CGEventTapCreate`
- `postMouseHIDEventToRemote:`
- `postKeyboardHIDEventToRemote:`
- `postMultimediaHIDEventToRemote:`
- `Cmd_Notify_KM_Switch_To_Remote`
- `Cmd_Notify_KM_Switch_To_Local`

## Replacement Strategy

The native rewrite should be built as separate modules:

- USB discovery for `0EA0:2213`.
- Accessibility trust and CGEvent tap management.
- Clipboard monitoring and serialization.
- OTi protocol transport over the device's exposed SCSI/USB path.
- Status-bar UI and diagnostics.

The native implementation now covers discovery, authorization status, clipboard
observation, diagnostics, SCSI Inquiry, selected read-only OTi vendor commands,
and an experimental HID forwarding path.

## Confirmed OTi SCSI Commands

Commands are 16-byte CDBs with trailing bytes `4F 54` (`OT`). The working path
uses the device's `IOCompactDiscServices` node through the MMC user client and
`GetSCSITaskDeviceInterface`.

- `F0 00 00 ... 4F 54`: read IC/version data, 12 bytes observed.
- `F0 00 02 ... 4F 54`: read physical bus/type data, 64 bytes observed.
- `D9 34 <12-byte keyboard report> 4F 54`: send keyboard HID report.
- `D9 33 <12-byte mouse report> 4F 54`: send mouse HID report.
- `D9 2A FF ... 4F 54`: send one queued data packet. Old code sends 0xFFEC
  bytes of payload followed by the first 20 bytes again, for 0x10000 bytes of
  data-out transfer.
- `D9 28 64 ... 4F 54`: receive one data packet. Old code expects 0x10000 bytes
  of data-in transfer and validates the first 20 bytes against the last 20 bytes
  or a known dummy packet.

The clipboard UPipe payload is XML shaped. For text, the old `KMClipboard.dylib`
builds an outer message with `NP_Cmd=Cmd_Transfer_Clipboard`,
`NP_Up_Notice_NamePipe_Name=\\.\pipe\OTI_ClipboardAgent`, and
`Param_Clipboard_Info_2=<inner clipboard XML>`. The inner clipboard XML contains
`CB_Format_Type` (`CB_Format_Text` or `CB_Format_UnicodeText`) and `CP_Content`.
The native encoder currently supports text-only UPipe generation and the 64 KiB
OTi data frame shape. Clipboard send is available through the explicit
`--test-clipboard-send` command and through status-bar menu actions, with
automatic send defaulting to off. `--test-clipboard-rx-parse` receives one data
packet and prints a conservative summary only. `--test-clipboard-receive`
decodes `Cmd_Transfer_Clipboard` packets without writing the pasteboard, while
`--test-clipboard-receive-apply` and the status-bar `Receive Clipboard from
Remote` action write the local pasteboard only after a valid clipboard packet is
decoded.
The status-bar app also has a default-off `Clipboard Auto-Receive` mode. When
enabled, it polls the device queue every 1.5 seconds, skips polling while a
clipboard send is in flight, and suppresses the next auto-send after applying a
received clipboard packet.
The menu keeps a compact clipboard transport status and the latest few TX/RX
summaries so Windows-side testing can tell whether an action sent, found no
packet, decoded a clipboard packet, or failed before reaching the device.
The SCSI media preparation step must unmount all media nodes exposed by the USB
device. The device can expose a small `NO NAME` disk and a separate `MacKMLink`
CD-ROM partition; unmounting only the first media node can leave the CD-ROM
mounted and prevent exclusive SCSI access.

Received packets seen so far can contain a higher GoBridge command layer after
the 20-byte OTi frame header. The current observed valid RX packet has a
length-prefixed `TXLIN1` label at offset 25 with no embedded `<OTIMSG>` XML, so
it is treated as a non-clipboard command/file-data frame until the command layer
is fully decoded.

`XmlPacketCommand` in `GoBridgeDemon` uses command ID `0x39`. Its command bytes
are `0x39`, followed by a 4-byte big-endian UTF-8 XML length, followed by the
XML bytes. `--test-clipboard-gobridge-encode` verifies this command-layer
encoding for the native text clipboard XML without sending it.

Before `OTi_SendData`, `GoBridgeDemon` wraps command bytes in a 20-byte
`CommandData` header and then pads that payload to `0xFFEC` bytes. The native
encoder now mirrors that shape for GoBridge clipboard test frames:

- offset 0: packet serial/count, little-endian UInt32.
- offset 4: transfer session ID, little-endian UInt32.
- offset 8: zero-based chunk index, little-endian UInt32.
- offset 12: total chunk count, little-endian UInt32.
- offset 16: command bytes in this chunk, little-endian UInt32.
- offset 20: command payload, starting with `0x39` for `XmlPacketCommand`.

The padded `0xFFEC` payload is still followed by a mirror copy of the first 20
bytes to form the `0x10000` OTi data-out transfer.
`--test-clipboard-send` sends the encoded GoBridge clipboard text frame over
`D9 2A FF ... OT`. The status-bar app also exposes manual
`Send Clipboard to Remote`, `Receive Clipboard from Remote`, default-off
`Clipboard Auto-Send`, and default-off `Clipboard Auto-Receive` menu actions.
The data-out path is considered transport-valid when all 65536 bytes transfer,
even if the SCSI task status is check-condition.

The current `--test-hid-release` command sends a 12-byte all-zero keyboard
report and has succeeded against the observed `Android+Mac` device.
`--test-hid-type-text "KMLINK TEST"` sends visible ASCII key press/release
reports, and the status-bar app exposes `Type Test Text to Remote` for
Windows-side keyboard verification in a focused text field. Mouse and scroll
reports are implemented from reverse-engineering evidence. `--test-hid-mouse-click`
and `--test-hid-scroll` send explicit left-click and scroll reports for
Windows-side validation when the pointer is in a safe location.

## Legacy Clipboard Send Findings

Launching the legacy x86_64 `GoBridgeDemon` directly and watching its own debug
output while changing the macOS pasteboard revealed the clipboard XML shape it
actually sends when the device is online:

- It waits until after login, `A1`, `AD`, `A4`, the remote screen-info XML, a
  directory-info round trip, and a final `A1` + `A2`.
- Clipboard send happens a few seconds later rather than immediately after
  login.
- The outer XML order is:
  `Param_Clipboard_Info_2`, then `NP_Cmd=Cmd_Transfer_Clipboard`, then
  `NP_Up_Notice_NamePipe_Name=\\.\pipe\OTI_ClipboardAgent`.
- The inner XML order is `CP_Content`, then `CB_Format_Type`.
- For a normal text clipboard change, the legacy app logs
  `CB_Format_Text`, but `CP_Content` still contains UTF-16LE bytes rendered as
  uppercase hex, including the trailing NUL pair.
- The observed debug line was:
  `After send UPipe message to remote: <OTIMSG><Param_Clipboard_Info_2><OTIMSG><CP_Content>...</CP_Content><CB_Format_Type>CB_Format_Text</CB_Format_Type></OTIMSG></Param_Clipboard_Info_2><NP_Cmd>Cmd_Transfer_Clipboard</NP_Cmd><NP_Up_Notice_NamePipe_Name>\\.\pipe\OTI_ClipboardAgent</NP_Up_Notice_NamePipe_Name></OTIMSG>`

The native app's initialized clipboard-send path now mirrors that legacy
behavior more closely by sending one delayed `CB_Format_Text` clipboard packet
with raw uppercase UTF-16LE hex content and no extra Unicode companion packet.
That initialized clipboard path now also keeps the whole login/init/clipboard
sequence inside one long-lived exclusive SCSI session, matching the legacy app
more closely than the earlier per-command reopen path.

Launching the full legacy `MacKMLink` host instead of `GoBridgeDemon` alone
adds one more important layer of initialization:

- the host waits several seconds before spawning `GoBridgeDemon`;
- after `CGEvent keyboard tap enabled!!!`, the host injects
  `setDirHandleDelegate`, clipboard on/off state, switch state, and hotkey
  settings into the daemon;
- when the Windows side is not considered active, the host-side logs end at
  `got REMOTE_APP_OFF`, and the daemon never emits `remote has login`,
  `Send command: A2`, or `Send command: 39`.

This means the remaining clipboard-send failure is no longer explained only by
local startup timing. Even the full legacy host path can stall before clipboard
transport when the remote side never reaches the "remote app active" state.

## Legacy Device Mode Probe

A separate x86_64 helper can now query the installed legacy
`OTiTransfer.framework` directly:

- build: [`tools/legacy-oti-mode/build.sh`](../tools/legacy-oti-mode/build.sh)
- run: [`scripts/legacy-device-mode.sh`](../scripts/legacy-device-mode.sh)

The helper is packaged as a tiny local app bundle because the framework expects
to resolve its own bundle resources before `OTi_Open()` will locate the correct
`idVendor` / `idProduct`.

Current observed results on the connected `0EA0:2213` device:

- `OTi_Open()` succeeds and initializes the device normally.
- `OTi_GetFunctionType()` succeeds with value `136`.
- `OTi_GetSideType()` succeeds with value `0`.
- Public `OTi_GetDeviceMode()` calls vendor command `D9 60 ...` and fails with
  SCSI sense `0x05/0x20/0x00` on this hardware state.
- Public `OTi_SetDeviceMode(0)` and `OTi_SetDeviceMode(1)` both return failure
  because the legacy implementation first calls `OTi_GetDeviceMode()` and aborts
  when that read fails.

This means the device-mode path is now reproducible, but the current device
state does not accept the legacy mode-read command. That makes device mode less
likely to be a simple missing toggle in the native rewrite and more likely to be
gated by an earlier session/state transition.

## Single-Session Clipboard Attempt

The native `sendInitializedClipboardTextProbe()` sequence now runs:

- login
- `A1`
- dynamic `AD`
- `A4`
- four receive polls
- post-directory `A1`
- `A2`
- delayed clipboard `0x39`
- six receive polls

all within one `KMLinkSCSISessionOpen()` / `KMLinkSCSISessionClose()` lifetime.

This change did not alter the qualitative device response: after the clipboard
packet, the device still returns only the same `D9 28 64 ...` placeholder/check-
condition packets with app-command byte `0x00`, and still does not surface a
clipboard XML acknowledgement. So the earlier per-command reopen behavior was
not the main cause of the missing Windows-side clipboard acceptance.

## Legacy Clipboard Fallback

Because the native clipboard TX path is still not accepted by Windows, the app
now also contains an on-demand fallback bridge:

- [`LegacyClipboardBridge.swift`](../Sources/KMLinkNative/LegacyClipboardBridge.swift)
- menu action `Send Clipboard to Remote` now uses that fallback bridge
- menu action `Send Clipboard to Remote (Native Probe)` keeps the native path
  available for protocol debugging
- CLI probe: `build/KMLinkNative.app/Contents/MacOS/KMLinkNative --test-clipboard-send-legacy "sample"`

The fallback launches the user's installed x86_64 `MacKMLink` host through
`arch -x86_64`. The host starts `GoBridgeDemon` and performs the legacy login,
settings, clipboard, and remote-activity initialization. For send, the bridge
updates the macOS pasteboard after that startup window, waits for
`Send command: 39`, and then terminates the host. For receive, it waits until
the host reports a connected remote session and watches the macOS pasteboard
for the incoming `Cmd_Transfer_Clipboard` update.

Current validation shows that this fallback path returns successfully and is
stable enough for app integration, even though the helper process is terminated
after the send window instead of left running permanently. The current CLI probe
has captured the full legacy send sequence including:

- `sendGrabedClipboardData(): before send to delegate`
- `sendCBUPipeMessage(): Got Clipboard changed data in ClipboardHandler and send to daemon`
- `Send command: 39`
- `After send UPipe message to remote: <OTIMSG>...`
- `sendCBUPipeMessage(): Finish send to daemon`

The validated receive path has also captured:

- `Cmd_Transfer_Clipboard`
- `COSXClipboardUTF16Converter::handleUPipeClipboardData`
- `addFromUPipeMsg(): Found incoming clipboard data and success update to pastboard`

The legacy app location defaults to
`~/Library/MacKMLinkFull/MacKMLink.app` and can be overridden with
`KMLINK_LEGACY_APP_PATH`. No vendor framework or application is included in
this repository.

The HID sender keeps a reusable SCSI/MMC session open after the first successful
send. `--test-hid-burst` verifies that repeated HID packets can use the same
exclusive session instead of reopening the MMC user client for every event.
If opening the exclusive session fails because the device's virtual CD media is
busy, the sender unmounts the media and then re-discovers the SCSI service
before retrying.
The HID sender also holds a process-wide file lock while the reusable session is
open so command-line tests and the status-bar app do not compete for the same
exclusive SCSI transport.

## Input Forwarding Modes

- Watching: the event tap counts local input only.
- Mirrored forwarding: local input continues normally and is also sent to the
  remote side.
- Remote-only forwarding: local input is suppressed after it is sent to the
  remote side. `Control` + `Option` + `Command` + `K` exits this mode.

## Current Test Gates

- `./scripts/build-app.sh`
- `./scripts/regression.sh --no-device`
- `./scripts/regression.sh`
- `./scripts/interactive-acceptance.sh`
- `./scripts/summarize-acceptance.sh`
- `build/KMLinkNative.app/Contents/MacOS/KMLinkNative --diagnose`
- `build/KMLinkNative.app/Contents/MacOS/KMLinkNative --test-hid-release`
- `build/KMLinkNative.app/Contents/MacOS/KMLinkNative --test-hid-burst`
- `build/KMLinkNative.app/Contents/MacOS/KMLinkNative --test-hid-mouse-nudge`
- `build/KMLinkNative.app/Contents/MacOS/KMLinkNative --test-hid-mouse-click`
- `build/KMLinkNative.app/Contents/MacOS/KMLinkNative --test-hid-scroll`
- `build/KMLinkNative.app/Contents/MacOS/KMLinkNative --test-hid-type-text "KMLINK TEST"`
- `build/KMLinkNative.app/Contents/MacOS/KMLinkNative --test-data-rx-probe`
- `build/KMLinkNative.app/Contents/MacOS/KMLinkNative --test-data-tx-dummy`
- `build/KMLinkNative.app/Contents/MacOS/KMLinkNative --test-clipboard-encode`
- `build/KMLinkNative.app/Contents/MacOS/KMLinkNative --test-clipboard-gobridge-encode`
- `build/KMLinkNative.app/Contents/MacOS/KMLinkNative --test-clipboard-receive-decode`
- `build/KMLinkNative.app/Contents/MacOS/KMLinkNative --test-clipboard-send "sample text"`
- `build/KMLinkNative.app/Contents/MacOS/KMLinkNative --test-clipboard-receive`
- `build/KMLinkNative.app/Contents/MacOS/KMLinkNative --test-clipboard-receive-apply`
- `build/KMLinkNative.app/Contents/MacOS/KMLinkNative --test-clipboard-rx-parse`
- `build/KMLinkNative.app/Contents/MacOS/KMLinkNative --self-test`

`--test-data-rx-probe` is considered successful when the data receive command
reaches the SCSI device. A check-condition response with no bytes is recorded as
`no-packet-or-check-condition`, which is expected when no remote clipboard/file
packet is waiting.
`--test-data-tx-dummy` sends the same all-zero 64 KiB packet shape used by the
old private `OTi_SendDummyData` function.
On the observed device the dummy data-out probe may report
`sent-check-condition`: the 64 KiB transfer completed, but the SCSI task ended
with a check-condition status. Treat that as transport reachability, not as
proof that the remote clipboard/file protocol accepted an application packet.
Run these transport tests one at a time. The app and command-line probes share a
non-blocking SCSI lock, so a concurrent probe may report `transport-busy`
instead of competing for exclusive access.
`--self-test` includes the GoBridge clipboard command/header encoder and the
local receive decoder round trip, in addition to USB, accessibility, SCSI,
vendor read, and HID checks.
`./scripts/regression.sh` runs the build and the non-invasive command-line
gates serially. It skips `--test-hid-type-text` by default because that command
types into the current Windows focus; pass `--with-visible-hid-text` only when a
safe text field is focused on Windows. It also skips mouse click/scroll by
default; pass `--with-interactive-mouse` only when the Windows pointer is in a
safe place. Use `--no-device` for a protocol-only build/encode/decode pass. For
device runs it first unloads/kills the legacy MacKMLink/GoBridgeDemon bundle,
because plugging in the device can auto-launch the old software and steal the
SCSI transport.
`./scripts/interactive-acceptance.sh` is the Windows-side acceptance runner. It
first unloads/kills the legacy MacKMLink bundle, runs the non-invasive
regression with app restart, then asks before each visible keyboard, click,
scroll, Mac-to-Windows clipboard, and Windows-to-Mac clipboard step. It writes
`manual.*` result lines into
`build/logs/acceptance-*.log`, then appends the
`./scripts/summarize-acceptance.sh` result to the same log. `--dry-run` checks
the prompt/logging flow without sending device commands; dry-run logs are
detected by the summarizer and can never count as final acceptance. Real manual
pass/fail lines are normalized by the script and are the evidence needed before
the full app goal can be considered complete. The clipboard steps use fixed
acceptance strings so the operator can paste/compare exact text; the
Windows-to-Mac step also logs a Mac pasteboard preview and an exact-match hint
when `pbpaste` is available.
`./scripts/summarize-acceptance.sh [log]` summarizes those `manual.*` lines and
returns success only when visible keyboard, left click, scroll, Mac-to-Windows
clipboard, and Windows-to-Mac clipboard are all marked `pass`. It also requires
the real acceptance-run markers, a completed baseline regression, no dry-run
markers, successful command output for every interactive command, and a
successful Windows-to-Mac exact-match line. Command success lines must appear
inside their corresponding interactive acceptance step, and manual pass/fail
lines are read from the same step blocks rather than from summary output or
other later log text. The acceptance runner also records preflight and
post-baseline process state; final acceptance requires the old MacKMLink app to
be absent and the native app to be running after the baseline restart.
When running from a sandboxed development host, data-in/data-out probes can fail
before SCSI execution with MMC plugin creation errors and DiskManagement
unmount failures. Re-run those probes outside the sandbox to validate the real
device path.
