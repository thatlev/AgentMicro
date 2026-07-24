# Codex Micro for macOS

Codex Micro is a native macOS 14+ menu-bar app. It contains the existing
Bluetooth-to-ChatGPT bridge, setup and diagnostics UI, and explicit controls
for applying or restoring the reversible ChatGPT integration.

The first release targets Apple Silicon and direct DMG distribution. It is not
configured for Mac App Store distribution.

## Build

Requirements:

- Apple Silicon Mac running macOS 14 or later
- Xcode and the Xcode command-line tools
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- npm on the build machine
- Internet access on the first build to download the pinned Node.js runtime
  and integrity-locked ASAR dependencies

Run either script from any working directory:

```bash
/absolute/path/to/CodexMicro/scripts/build-macos.sh
/absolute/path/to/CodexMicro/scripts/package-dmg.sh
```

The build script recreates `dist/` and produces:

```text
dist/Codex Micro.app
```

The packaging script builds the app and then produces:

```text
dist/Codex-Micro-1.0.0-arm64.dmg
```

Pass `--skip-build` to `package-dmg.sh` only when the app in `dist/` is already
the exact build to package.

## Self-contained patch runtime

Distribution builds contain their own Apple Silicon Node.js executable and a
locked `@electron/asar` dependency tree under:

```text
Codex Micro.app/Contents/Resources/PatchRuntime
```

Users do not need Node.js, npm, or a network download to patch or restore
ChatGPT. The build cache lives in:

```text
~/Library/Caches/CodexMicroBuild
```

For an offline build, set `CODEX_MICRO_NODE_ARCHIVE` to the official
`node-v24.18.0-darwin-arm64.tar.gz` archive. The build still checks it against
the pinned official SHA-256 digest
`e1a97e14c99c803e96c7339403282ea05a499c32f8d83defe9ef5ec66f979ed1`.
The build deliberately does not accept a local Homebrew Node binary because
Homebrew builds normally depend on libraries that do not exist on a user's
Mac.

Fresh ChatGPT patches keep a complete, version-matched backup under
`~/Library/Application Support/CodexMicro/Backups/`. A complete backup can be
roughly the size of ChatGPT itself. Codex Micro checks available disk space
before staging a patch and does not automatically delete old backups. Older
backups can be removed manually after the corresponding ChatGPT version is no
longer needed.

Installations migrated from the earlier command-line patcher may instead use
its exact version-matched resource backup under `~/.codexbridge/backup/`.
Restoring that legacy backup removes the integration but remains locally
signed; reinstall ChatGPT to recover OpenAI's signature.

## Clean reconnect

1. Stop direct T3 Code or any command-line bridge that currently owns the
   iPhone's BLE connection.
2. Keep Codex Micro Remote open on the iPhone.
3. Choose **Reconnect** from the Mac menu-bar popover.
4. Open ChatGPT.
5. If Integration says **Update required**, choose **Restore ChatGPT**, wait
   for restoration to finish, then choose **Patch ChatGPT**. If it says
   **Patch required**, patch directly. Allow App Management when macOS asks.
6. Wait for a fresh end-to-end round trip. The attention dot disappears only
   after ChatGPT and the iPhone successfully exchange matched data.

The menu-bar state describes the ChatGPT route. The current iPhone build is
T3-only at the control-surface level, and direct T3 Code uses a separate BLE
connection, so test the two paths sequentially.

## Signing and notarization

With no environment variables, the scripts apply an ad-hoc signature suitable
for testing on the developer's Mac. It is not a public-distribution artifact:

```bash
scripts/package-dmg.sh
```

For public direct distribution, supply a Developer ID Application identity:

```bash
MACOS_SIGN_IDENTITY="Developer ID Application: Example Name (TEAMID)" \
scripts/package-dmg.sh
```

To notarize and staple the DMG, first store notary credentials with
`notarytool`, then add the keychain profile:

```bash
MACOS_SIGN_IDENTITY="Developer ID Application: Example Name (TEAMID)" \
MACOS_NOTARY_PROFILE="codex-micro-notary" \
scripts/package-dmg.sh
```

The Xcode project intentionally has App Sandbox disabled because the app
connects to a local Unix socket, manages its own local support files, and—only
after explicit confirmation—updates or restores the separately installed
ChatGPT application.

Developer ID builds sign the bundled Node.js executable separately with the
single `com.apple.security.cs.allow-jit` entitlement required by V8. The main
application does not receive that entitlement. Every build runs a dynamic V8
smoke test after signing Node and before accepting the application signature.

## App icon

The neutral app icon is an abstract 3×3 key grid with no third-party names,
logos, or hardware trade dress. Regenerate every macOS icon size with:

```bash
swift macos/CodexMicro/Support/IconSource/generate-icon.swift \
  macos/CodexMicro/Support/Assets.xcassets/AppIcon.appiconset
```

## Project generation

`project.yml` is the source of truth. The generated `.xcodeproj` is a build
artifact and is created under `dist/.build/`, keeping the repository clean.
Opening a project generated manually with XcodeGen is useful for development,
but only the official build script injects the full self-contained patch
runtime before signing.
