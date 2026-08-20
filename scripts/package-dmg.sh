#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_ROOT="$REPO_ROOT/dist"
APP_PATH="$DIST_ROOT/AgentMicro.app"
STAGING_ROOT="$DIST_ROOT/.dmg-staging"
SIGN_IDENTITY="${MACOS_SIGN_IDENTITY:--}"
NOTARY_PROFILE="${MACOS_NOTARY_PROFILE:-}"
SKIP_BUILD=0

log() {
    printf '[package-dmg] %s\n' "$*"
}

die() {
    printf '[package-dmg] ERROR: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [[ -d "$STAGING_ROOT" ]]; then
        rm -rf "$STAGING_ROOT"
    fi
}

case "${1:-}" in
    "")
        ;;
    --skip-build)
        SKIP_BUILD=1
        ;;
    *)
        die "usage: $0 [--skip-build]"
        ;;
esac

[[ "$(uname -s)" == "Darwin" ]] || die "DMG packaging can only run on macOS"
command -v hdiutil >/dev/null 2>&1 || die "hdiutil is required"

if [[ "$SKIP_BUILD" == "0" ]]; then
    "$SCRIPT_DIR/build-macos.sh"
fi

[[ -d "$APP_PATH" ]] || die "built app not found; run scripts/build-macos.sh first"

VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$APP_PATH/Contents/Info.plist")"
DMG_PATH="$DIST_ROOT/AgentMicro-${VERSION}-arm64.dmg"

trap cleanup EXIT
cleanup
mkdir -p "$STAGING_ROOT"

log "preparing a readable installer volume"
ditto "$APP_PATH" "$STAGING_ROOT/AgentMicro.app"
ln -s /Applications "$STAGING_ROOT/Applications"
install -m 0644 \
    "$REPO_ROOT/macos/AgentMicro/Support/DMG-README.txt" \
    "$STAGING_ROOT/Read Me.txt"

rm -f "$DMG_PATH"
hdiutil create \
    -volname "AgentMicro" \
    -srcfolder "$STAGING_ROOT" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    "$DMG_PATH"

if [[ "$SIGN_IDENTITY" != "-" ]]; then
    log "signing the disk image"
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
fi

if [[ -n "$NOTARY_PROFILE" ]]; then
    [[ "$SIGN_IDENTITY" != "-" ]] \
        || die "MACOS_NOTARY_PROFILE requires a Developer ID MACOS_SIGN_IDENTITY"
    log "submitting the disk image for notarization"
    xcrun notarytool submit \
        "$DMG_PATH" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
fi

log "finished: $DMG_PATH"
shasum -a 256 "$DMG_PATH"
