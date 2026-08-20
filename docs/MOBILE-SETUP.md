# Set up AgentMicro on an iPhone

This guide is written for both people and coding agents. The goal is a real,
on-device build that opens on the phone and reaches **iPhone · Ready** in the
AgentMicro Mac menu.

## Rules for an agent doing the setup

- Inspect first. Do not change signing, bundle identifiers, Bluetooth service
  identifiers, socket paths, persisted keys, or wire-protocol strings unless
  the user explicitly asks for a product migration.
- Never ask for an Apple ID password, certificate private key, or two-factor
  code. Xcode owns those prompts; the user enters them directly.
- You may generate the Xcode project, build, install, and launch from the
  terminal. Stop and give one exact click path when Xcode requires the user to
  choose a team, trust the Mac, enable Developer Mode, or accept a permission.
- Do not report success from a successful compile alone. Success means the app
  launches on the selected iPhone and the Mac companion reports the iPhone as
  ready.

## 1. Preflight

Confirm all of the following:

1. The Mac is Apple silicon and runs macOS 14 or newer.
2. Full Xcode is installed and `xcode-select -p` points inside Xcode.
3. Xcode has an Apple ID under **Xcode → Settings → Accounts**.
4. The iPhone is unlocked, trusted, connected by USB for the first build, and
   appears under **Window → Devices and Simulators**.
5. Developer Mode is enabled under **iPhone Settings → Privacy & Security →
   Developer Mode**. The phone restarts when this is enabled.

From the repository root, generate the project if needed:

```bash
xcodegen generate \
  --spec ios/AgentMicroRemote/project.yml \
  --project ios/AgentMicroRemote
```

Open the project when signing needs attention:

```bash
open ios/AgentMicroRemote/AgentMicroRemote.xcodeproj
```

Select the **AgentMicroRemote** target, open **Signing & Capabilities**, enable
automatic signing, and choose the user's team. A free Apple ID works for local
device testing. Free-development builds normally expire after seven days and
must then be built to the phone again.

## 2. Build, install, and launch

With the phone name shown by Xcode, run:

```bash
./scripts/deploy-iphone.sh "YOUR IPHONE NAME"
```

The script builds with provisioning updates enabled, installs the resulting
app, and launches it. It intentionally uses the project's existing stable
application identity so upgrades and saved settings continue to work.

If the destination name is ambiguous, discover the exact device identifier:

```bash
xcrun devicectl list devices
```

Then select the same device in Xcode and press **Run** once. Xcode's UI gives
the clearest recovery path for account, team, and device-registration errors.

## 3. Connect to the Mac

1. Open AgentMicro on the iPhone and keep it in the foreground for first
   pairing.
2. Allow Bluetooth when iOS asks.
3. Open AgentMicro from the Mac menu bar and choose **Check connection**.
4. Keep other AgentMicro/T3 bridge processes closed while pairing; only one
   process can own the Bluetooth peripheral at a time.
5. Wait for the iPhone stage to show **Ready**.

For ChatGPT, keep the Mac companion running and use its onboarding to patch
ChatGPT. For a multi-agent desktop workspace, use the
[AgentMicro T3 Code fork](https://github.com/thatlev/t3code). For workflows
that begin in ChatGPT, Codex, Claude Code, or Cursor, use
[OpenCodex](https://github.com/lidge-jun/opencodex). Both paths use the same
iPhone app; do not run both Bluetooth owners at once.

## Troubleshooting

### “App is no longer available”

The local development profile expired. Reconnect the phone and run the deploy
script again. With a free Apple ID this is expected roughly every seven days.

### No signing team / provisioning profile

Open the Xcode project, select **AgentMicroRemote → Signing & Capabilities**,
enable automatic signing, and choose the user's Personal Team. If Xcode says
the application identifier is unavailable, do not edit the committed identity
silently. Show the error and ask the user whether they want a personal suffix.

### Developer Mode or trust error

Reconnect over USB, unlock the phone, accept **Trust This Computer**, verify it
appears in **Window → Devices and Simulators**, and enable Developer Mode on the
phone. Run once from Xcode after any trust reset.

### Build succeeds but install or launch fails

Remove the expired AgentMicro build from the phone, leave the phone unlocked,
and press **Run** from Xcode. Check device logs in **Window → Devices and
Simulators → Open Console**. Do not delete the repository's build settings as a
generic fix.

### The Mac stays on “Looking for your iPhone”

- Keep the iPhone app open and Bluetooth enabled on both devices.
- Allow Bluetooth for AgentMicro in macOS **System Settings → Privacy &
  Security → Bluetooth** and in iOS Settings.
- Quit or pause T3 Code and any command-line bridge that may already own the
  phone.
- Choose **Check connection** in the AgentMicro menu.

### ChatGPT stays on “Checking”

Confirm the Mac menu reports a compatible patch, then quit and reopen ChatGPT
normally. If ChatGPT was updated, use **Restore ChatGPT** when offered, wait for
it to finish, then use **Patch ChatGPT**. The menu is green only after a fresh
ChatGPT → Mac → iPhone → Mac → ChatGPT round trip; Bluetooth alone is not
reported as full success.

## Completion checklist

- AgentMicro launches on the selected iPhone.
- The iPhone granted Bluetooth permission.
- The Mac menu shows **iPhone · Ready**.
- ChatGPT is patched and opens normally when that route is being used.
- The menu reaches **Connected** after a real end-to-end check.
