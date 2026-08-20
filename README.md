# AgentMicro

AgentMicro turns an iPhone into a Bluetooth control surface. This checkout
contains two Mac connection paths:

Existing bundle IDs, storage directories, socket names, and protocol identifiers
retain their `AgentMicro` values so installed builds upgrade in place and remain
compatible with ChatGPT's physical AgentMicro protocol.

- **T3 Code direct:** T3 Code connects straight to the iPhone's private BLE
  service. The current iPhone UI is intentionally T3-only.
- **ChatGPT companion:** the native AgentMicro menu-bar app owns Bluetooth,
  a reversible ChatGPT integration, launch at login, diagnostics, and strict
  end-to-end connection status.

Only one Mac process can own the iPhone's BLE connection at a time. Pause or
quit the menu-bar bridge before testing direct T3 Code, and disconnect T3 Code
before testing the menu-bar bridge.

## Architecture

Direct T3 Code:

```text
AgentMicro on iPhone ⟷ encrypted private BLE ⟷ T3 Code for macOS
```

ChatGPT companion:

```text
ChatGPT integration
        ⟷ $TMPDIR/AgentMicro/codexbridge.sock
        ⟷ AgentMicro menu-bar app
        ⟷ encrypted private BLE
        ⟷ AgentMicro on iPhone
```

The companion temporarily provides `/tmp/codexbridge.sock` as a migration
alias for ChatGPT installations patched by the older invisible helper. New
patches use the private per-user socket.

## Build and launch the iPhone app

Requirements:

- Xcode with an Apple ID signed in under **Xcode → Settings → Accounts**
- a development team selected for the `AgentMicroRemote` target
- `iPhone L` unlocked, trusted, in Developer Mode, and connected by USB or
  available over the same trusted developer Wi-Fi network

From this repository:

```bash
./scripts/deploy-iphone.sh "iPhone L"
```

The script builds, installs, and launches bundle
`io.github.thislev.codexmicroremote`. A free Apple ID is sufficient for
on-device development testing; a paid account is needed for TestFlight and
normal distribution.

## Run and test the BLE-enabled T3 Code source

Close other packaged T3 Code copies first, then from the T3 Code checkout:

```bash
pnpm dev:desktop
```

Test direct T3 control:

1. Pause or quit the AgentMicro menu-bar bridge.
2. Keep AgentMicro open on the iPhone.
3. In T3 Code, open **Settings → AgentMicro → Connect iPhone**.
4. Select **AgentMicro** and accept the Bluetooth pairing prompts.
5. Confirm T3 reports **Connected** and shows the iPhone battery.
6. Test all six thread keys, pin/unpin, NEW, joystick navigation, encoder
   model/effort changes, approve, decline, send, and dictation.
7. Relaunch T3 and confirm automatic reconnection.
8. Turn Bluetooth off briefly. Both sides must stop claiming a usable
   connection, then recover after Bluetooth is restored.

## Build the macOS menu-bar companion

On Apple Silicon with Xcode, XcodeGen, npm, and Internet access for the first
build:

```bash
./scripts/build-macos.sh
./scripts/package-dmg.sh --skip-build
```

Outputs:

```text
dist/AgentMicro.app
dist/AgentMicro-1.0.0-arm64.dmg
```

The default build is ad-hoc signed for local testing on this Mac. Public DMG
distribution requires Developer ID signing, notarization, and stapling. See
[macos/AgentMicro/README.md](macos/AgentMicro/README.md).

## Test the menu-bar companion

1. Disconnect direct T3 Code so the menu app can own Bluetooth.
2. Copy **AgentMicro.app** to `/Applications` and open it.
3. Keep the iPhone app open and click **Reconnect** in the menu.
4. If Integration says **Update required**, choose **Restore ChatGPT**, wait
   for it to reopen, then choose **Patch ChatGPT**. If it says
   **Patch required**, patch directly.
5. Open ChatGPT and watch the route progress through its actual stages.
6. Confirm the attention dot disappears only after a recent matched
   ChatGPT → Mac → iPhone → Mac → ChatGPT round trip.
7. Close ChatGPT, disable Bluetooth, or close the iPhone app one at a time.
   Each break must remove the healthy state.

The current phone UI exposes only the T3 surface. The companion can still
verify its transport and ChatGPT round trip, but button presses remain routed
to T3 in this iPhone build.

## Menu-bar status is the source of truth for the ChatGPT route

- **No dot / Verified:** compatible patch, encrypted phone link, active
  ChatGPT socket, and a recent successful two-way round trip.
- **Yellow / Connecting:** discovery, Bluetooth connection, or end-to-end
  verification is in progress.
- **Orange / Action needed:** permission, patch, update, or another user
  action is required.
- **Red / Failed:** an operation or route check failed.
- **Gray / Idle:** paused, not found, or waiting for a required app.

Green is deliberately temporary. The companion rechecks the route and removes
the healthy state when its proof becomes stale.

## Clean reconnect

1. Stop any other T3 or command-line process using the AgentMicro BLE device.
2. Open AgentMicro on the iPhone.
3. Open the AgentMicro menu and choose **Reconnect**.
4. Open ChatGPT.
5. Resolve **Update required** with **Restore → Patch**, or resolve
   **Patch required** with **Patch**.
6. Wait for **Verified**. Do not treat a Bluetooth-only link as fully
   connected.

Patch and restore are explicit, confirmed operations. AgentMicro asks ChatGPT
to close normally and aborts if it does not; it never force-quits ChatGPT.

## Development bridge

The command-line bridge remains available for protocol tests:

```bash
./tools/AgentMicroBridge/codexbridge
./tools/AgentMicroBridge/codexbridge --emulate
```

Run only one menu app, command-line bridge, direct T3 Code connection, or
emulator at a time.
