# Codex Micro

Codex Micro turns an iPhone into a BLE control surface for the Codex Micro
interface in the ChatGPT desktop app. A native macOS menu-bar companion owns
the Bluetooth bridge, connection truth, reversible ChatGPT integration, logs,
launch-at-login registration, and first-run setup.

Architecture:

```
ChatGPT (patched shim)
        ⟷ $TMPDIR/CodexMicro/codexbridge.sock
        ⟷ Codex Micro menu-bar app
        ⟷ iPhone app (BLE)
```

The companion temporarily provides `/tmp/codexbridge.sock` as a compatibility
alias for ChatGPT installations patched by the previous invisible helper.
Fresh patches use the private per-user socket directly.

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
permission for **Codex Micro**. Enable it under **System Settings → Privacy &
Security → Accessibility**; the companion never modifies the Claude app.

The VS Code and T3 implementations remain in the app and helper, including
their persisted setup, but their pages are currently hidden.

## Hidden Claude Code (VS Code) mode

The same macropad can drive the **Claude Code VS Code extension** — plus Codex /
Kimi CLIs running in terminals — with live agent-status lighting, without
patching Claude or VS Code. A small additive companion extension receives the
key events over a socket and runs public editor commands.

```
iPhone (BLE) ⟷ codexbridge (auto) ⟷ $TMPDIR/codexbridge-vscode.sock ⟷ Codex Micro VSCode extension
             └ agent-key LEDs ← Codex Micro status.json ← Claude/Codex/Kimi hooks
```

Setup and controls: **[docs/claude-vscode-setup.md](docs/claude-vscode-setup.md)**.
Quick start for development/testing: install
`vscode/CodexMicroVSCode/codex-micro-vscode-0.5.1.vsix`, then run
`./tools/CodexMicroBridge/codexbridge`. The VS Code page can be restored to the
pager without rebuilding its underlying integration.

## macOS menu-bar app

The source of truth is `macos/CodexMicro/project.yml`. On an Apple-silicon Mac
with Xcode, XcodeGen, and npm installed:

```bash
./scripts/build-macos.sh
./scripts/package-dmg.sh
```

The outputs are `dist/Codex Micro.app` and
`dist/Codex-Micro-1.0.0-arm64.dmg`. The DMG is ad-hoc signed for local testing
unless `MACOS_SIGN_IDENTITY` and, optionally, `MACOS_NOTARY_PROFILE` are set.
See [macos/CodexMicro/README.md](macos/CodexMicro/README.md).

On first launch the app disables the previous invisible KeepAlive launch item,
retains its plist under `~/Library/Application Support/CodexMicro/Legacy/`,
and enables Launch at Login. It does not delete the previous helper app.

Patching and restoring ChatGPT are explicit, confirmed actions in the menu.
Codex Micro asks ChatGPT to quit normally and aborts without replacement if it
does not close; it never force-quits ChatGPT.

The command-line bridge and emulator remain available for development:

```bash
./tools/CodexMicroBridge/codexbridge
./tools/CodexMicroBridge/codexbridge --emulate
```

Run only one menu app, command-line bridge, or emulator at a time.

## Connection status and clean reconnect

The iPhone's Codex page now separates the connection stages:

- **Waiting for Mac** — the phone is advertising, but the helper has not subscribed.
- **Mac linked** — Bluetooth transport is up; ChatGPT is not ready yet.
- **Waiting for ChatGPT** — the helper is linked to the phone but no patched ChatGPT
  socket client is present.
- **Checking ChatGPT** — ChatGPT sent a real device request and the helper is waiting
  for the iPhone's reply.
- **Fully connected** — shown without an attention dot only after a recent,
  successful, matched ChatGPT → companion → iPhone → companion → ChatGPT RPC
  round trip. The companion keeps rechecking this route.
- **Recovering** or **Connection error** — the end-to-end path is not usable.

Codex controls are intentionally disabled until the status is **Fully connected**.
For a clean reconnect, open Codex Micro on the iPhone, choose **Reconnect** in
the Mac menu, and open ChatGPT. If the Integration row says **Patch required**,
use **Patch ChatGPT**, allow App Management if macOS asks, and let the app reopen
ChatGPT. The status should progress through yellow checking states and become
**Fully connected** only after the fresh round trip succeeds.

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
