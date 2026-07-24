# SidePulse — Codex Micro iOS emulator

Makes an iPhone (or the Mac itself) act as an OpenAI **Codex Micro** BLE macropad
for the ChatGPT / Codex desktop app. The ChatGPT app is patched to detect the
device through a local socket bridge instead of a real USB HID device.

Architecture:

```
ChatGPT (patched shim) ⟷ /tmp/codexbridge.sock ⟷ codexbridge helper ⟷ iPhone app (BLE)
                                                                     └⟶ --emulate (built-in virtual device)
```

## Visible iPhone surfaces

The iPhone app shows two swipe pages:

- **Codex Micro** controls the patched ChatGPT/Codex desktop app.
- **Claude Desktop** opens Claude Code sessions explicitly in the native macOS
  Claude app. Exact `claude://code/<session-uuid>` links can be assigned to the
  six agent keys; the Mac helper stores those pins under
  `~/.codexbridge/claude-desktop-pins.json`. Its microphone key is a hands-free
  tap toggle for Claude Desktop's own dictation (`Command-D`), using the Mac's
  current audio input. The header clear button empties the focused Claude
  composer after verifying that macOS reports an editable text field.

The first Claude microphone or clear action asks for macOS **Accessibility**
permission for `codexbridge`. Enable it under **System Settings → Privacy &
Security → Accessibility**; the helper never modifies the Claude app.

The VS Code and T3 implementations remain in the app and helper, including
their persisted setup, but their pages are currently hidden.

## Hidden Claude Code (VS Code) mode

The same macropad can drive the **Claude Code VS Code extension** — plus Codex /
Kimi CLIs running in terminals — with live agent-status lighting, without
patching Claude or VS Code. A small additive companion extension receives the
key events over a socket and runs public editor commands.

```
iPhone (BLE) ⟷ codexbridge (auto) ⟷ $TMPDIR/codexbridge-vscode.sock ⟷ Codex Micro VSCode extension
             └ agent-key LEDs ← SidePulse status.json ← Claude/Codex/Kimi hooks
```

Setup and controls: **[docs/claude-vscode-setup.md](docs/claude-vscode-setup.md)**.
Quick start for development/testing: install
`vscode/CodexMicroVSCode/codex-micro-vscode-0.5.1.vsix`, then run
`./tools/CodexMicroBridge/codexbridge`. The VS Code page can be restored to the
pager without rebuilding its underlying integration.

## Commands

Run all three from the repo root (`/Users/lev/Documents/VibeCoding/AI tools/CodexMicro`).

### 1. Patch (remake) the ChatGPT app

Injects the bridge shim into `/Applications/ChatGPT.app`, eagerly starts the
Codex Micro service, and enables the renderer event bridge that interprets
dial/key input. It is idempotent — **re-run this after every ChatGPT
auto-update**, because updates replace the app bundle and wipe the patch
(symptoms: the phone says Mac connected but keys do nothing, onboarding
reappears, or the device stops being detected).

```bash
./tools/patch-chatgpt.sh
```

If macOS reports `Operation not permitted`, enable **Terminal** under System
Settings → Privacy & Security → App Management, then run the patch again.
App Management is the macOS permission that allows one app to update another
installed app bundle.

To revert to the pristine OpenAI-signed app:

```bash
./tools/patch-chatgpt.sh --restore
```

### 2. Run the helper on the Mac for the iPhone app

Bridges the CodexMicroRemote iPhone app to ChatGPT/Codex and Claude Desktop
over BLE. Leave it running, then open the app and swipe between its two control
pages. The selected page determines which isolated desktop integration receives
the keys.

```bash
./tools/CodexMicroBridge/codexbridge
```

### 3. Run the emulator on the Mac instead of the iPhone

Presents a built-in virtual Codex Micro straight to ChatGPT — no iPhone needed.

```bash
./tools/CodexMicroBridge/codexbridge --emulate
```

Note: run only one of command 2 or 3 at a time (both use the same socket).
Reopen ChatGPT after the helper/emulator is running.

## Connection status and clean reconnect

The iPhone's Codex page now separates the connection stages:

- **Waiting for Mac** — the phone is advertising, but the helper has not subscribed.
- **Mac linked** — Bluetooth transport is up; ChatGPT is not ready yet.
- **Waiting for ChatGPT** — the helper is linked to the phone but no patched ChatGPT
  socket client is present.
- **Checking ChatGPT** — ChatGPT sent a real device request and the helper is waiting
  for the iPhone's reply.
- **Fully connected** — shown in green only after a successful, matched
  ChatGPT → helper → iPhone → helper → ChatGPT RPC round trip.
- **Recovering** or **Connection error** — the end-to-end path is not usable.

Codex controls are intentionally disabled until the status is **Fully connected**.
For a clean reconnect, keep the iPhone app open in the foreground, fully quit
ChatGPT with Command-Q, then reopen ChatGPT. The helper starts automatically.
The badge should progress to **Fully connected** within a few seconds. If it
stops at **Waiting for ChatGPT** after a ChatGPT update, re-run
`./tools/patch-chatgpt.sh`, then quit and reopen ChatGPT once more.

## Key binding sync

ChatGPT persists the Codex Micro layout (which command each key runs) and its
lighting brightness to `~/.codex/config.toml`, but it does not send those as
durable device configuration. The `codexbridge` helper (command 2 above)
watches that file (honoring `$CODEX_HOME`) and pushes a snapshot to the iPhone
as a private channel-3 config message on the bridge output characteristic.
Remap a key or change brightness in ChatGPT's Codex Micro settings and the
iPhone app updates within ~1 s; the raw slot ids the phone sends are unchanged.
The synced layout is also listed under **Setup › Key bindings** in the app.

## Lighting brightness

Brightness is owned by ChatGPT's Codex Micro settings. The iPhone app displays
the host-reported percentage under **Setup › Lighting** and mirrors it on both
the agent-key LEDs and body glow; it does not keep separate local brightness
settings.

## iPhone display modes

Under **Setup › Display mode**, **Framed** keeps the physical enclosure,
fasteners, and legends. **Maximized** removes the enclosure and expands the
same control grid nearly edge-to-edge for the largest practical touch targets.
The choice is stored on the iPhone and survives relaunches.
