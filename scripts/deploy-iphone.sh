#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT="$REPO_ROOT/ios/AgentMicroRemote/AgentMicroRemote.xcodeproj"
DERIVED_DATA="$REPO_ROOT/build/ios-device"
DEVICE_NAME="${1:-iPhone L}"
APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphoneos/AgentMicro.app"
BUNDLE_ID="io.github.thislev.codexmicroremote"

log() {
    printf '[deploy-iphone] %s\n' "$*"
}

[[ "$(uname -s)" == "Darwin" ]] || {
    printf '[deploy-iphone] ERROR: this script requires macOS and Xcode.\n' >&2
    exit 1
}
[[ -d "$PROJECT" ]] || {
    printf '[deploy-iphone] ERROR: Xcode project not found: %s\n' "$PROJECT" >&2
    exit 1
}

log "building AgentMicro for $DEVICE_NAME"
xcodebuild \
    -project "$PROJECT" \
    -scheme AgentMicroRemote \
    -configuration Debug \
    -destination "platform=iOS,name=$DEVICE_NAME" \
    -derivedDataPath "$DERIVED_DATA" \
    -allowProvisioningUpdates \
    build

[[ -d "$APP_PATH" ]] || {
    printf '[deploy-iphone] ERROR: build succeeded but app was not found: %s\n' "$APP_PATH" >&2
    exit 1
}

log "installing on $DEVICE_NAME"
xcrun devicectl device install app \
    --device "$DEVICE_NAME" \
    "$APP_PATH"

log "launching on $DEVICE_NAME"
xcrun devicectl device process launch \
    --device "$DEVICE_NAME" \
    "$BUNDLE_ID"

log "finished"
