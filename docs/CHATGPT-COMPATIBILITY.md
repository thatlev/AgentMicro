# ChatGPT build compatibility workflow

This is the required repair and release procedure when AgentMicro reports an
unsupported ChatGPT desktop build. AgentMicro intentionally fails closed: an
unknown bundle is never patched merely because its version is newer.

OpenAI's desktop app normally installs updates automatically. A new release
therefore removes AgentMicro's local integration and must be inspected before
AgentMicro claims compatibility. OpenAI recommends testing desktop releases
before deployment and does not guarantee compatibility with older builds:

- [OpenAI: manage ChatGPT desktop app updates](https://learn.chatgpt.com/docs/enterprise/manage-app-updates)
- [Official ChatGPT desktop update feed](https://persistent.oaistatic.com/codex-app-prod/appcast.xml)

## Read these repository sources first

- [Patch and rollback implementation](https://github.com/thatlev/AgentMicro/blob/main/tools/patch-chatgpt.sh)
- [Fail-closed ASAR inspector](https://github.com/thatlev/AgentMicro/blob/main/macos/AgentMicro/PatchRuntime/asar-inspect.cjs)
- [Inspector and status fixtures](https://github.com/thatlev/AgentMicro/blob/main/macos/AgentMicro/PatchRuntime/asar-inspect.test.cjs)
- [Injected HID shim](https://github.com/thatlev/AgentMicro/blob/main/tools/AgentMicroBridge/codex-hid-shim.js)
- [Patch runtime contract](https://github.com/thatlev/AgentMicro/blob/main/macos/AgentMicro/PatchRuntime/README.md)
- [AgentMicro protocol research](https://github.com/thatlev/AgentMicro/blob/main/docs/agent-micro-protocol.md)
- [macOS build and signing script](https://github.com/thatlev/AgentMicro/blob/main/scripts/build-macos.sh)
- [DMG packaging script](https://github.com/thatlev/AgentMicro/blob/main/scripts/package-dmg.sh)

## Safety invariants

1. Work on an untouched staged copy of the exact official ChatGPT build. Do
   not investigate by changing `/Applications/ChatGPT.app`.
2. Verify the original app's Apple code signature and OpenAI team identifier
   `2DC432GLL2` before trusting the fixture.
3. Keep every ASAR integrity check, exact-match count, versioned full backup,
   normal-quit timeout, atomic replacement, entitlement-preservation, local
   signing, rollback, and post-operation verification in place.
4. Match semantic landmarks as narrowly as possible. Zero matches, multiple
   matches, mixed pristine/patched states, unknown shim schemas, or failed
   integrity checks remain incompatible.
5. Never weaken verification to make a new build pass. Never force-quit
   ChatGPT. Never commit or redistribute OpenAI's application or extracted
   proprietary bundles.

## Repair procedure

1. Record the version, build, bundle identifier, scanner reason, official
   archive URL, archive SHA-256, and original signature result.
2. Run the current inspector against the staged `app.asar`. Identify exactly
   which structural landmark changed and compare it with the last supported
   build.
3. Make the smallest corresponding change in both `asar-inspect.cjs` and
   `patch-chatgpt.sh`. Keep detection and mutation rules aligned.
4. Extend fixtures for the new pristine shape, the expected patched shape,
   mixed-state rejection, missing-target rejection, and duplicate-target
   rejection where applicable.
5. Confirm the shim protocol and expected schema have not changed. If they
   changed, update the shim, scanner, patch metadata, protocol documentation,
   and migration behavior together.

## Required verification

From the repository root, run:

```bash
node --test macos/AgentMicro/PatchRuntime/asar-inspect.test.cjs
node --test tools/wire-contract.test.cjs
xcodegen generate --spec macos/AgentMicro/project.yml --project macos/AgentMicro
xcodebuild -project macos/AgentMicro/AgentMicro.xcodeproj \
  -scheme AgentMicro -destination 'platform=macOS,arch=arm64' test
./scripts/build-macos.sh
./scripts/package-dmg.sh --skip-build
```

Then, using temporary staging paths only:

1. Verify the untouched app with `codesign --verify --deep --strict` and check
   that its team identifier is `2DC432GLL2`.
2. Confirm the inspector reports `compatible-pristine` with integrity
   verification enabled.
3. Patch the staged app and confirm `compatible-patched`, ASAR integrity,
   local signing, bundled Node execution, and application launch.
4. Restore the staged app from its exact-version complete backup and confirm
   byte identity and the original OpenAI signature.
5. Exercise the real ChatGPT → Mac → iPhone → Mac → ChatGPT round trip on a
   representative Mac before declaring the build supported.

If any gate cannot be completed, keep the build unsupported and document the
precise blocker. After all gates pass, update the tested-build badge and local
research references if they changed, review the complete diff, and use the
normal pull-request and release process.
