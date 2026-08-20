#!/usr/bin/env bash

set -euo pipefail

REPOSITORY_URL="https://github.com/thatlev/AgentMicro.git"
APPLICATION_PATH="/Applications/AgentMicro.app"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agentmicro-install.XXXXXX")"
SOURCE_ROOT="$TEMP_ROOT/AgentMicro"

log() {
    printf '[AgentMicro] %s\n' "$*"
}

die() {
    printf '[AgentMicro] ERROR: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [[ -d "$TEMP_ROOT" ]]; then
        rm -rf "$TEMP_ROOT"
    fi
}

trap cleanup EXIT

[[ "$(uname -s)" == "Darwin" ]] || die "AgentMicro requires macOS."
[[ "$(uname -m)" == "arm64" ]] || die "This build currently requires an Apple silicon Mac."
command -v git >/dev/null 2>&1 || die "Git is required. Install Xcode Command Line Tools with: xcode-select --install"
command -v xcodebuild >/dev/null 2>&1 || die "Xcode is required. Install it from the App Store, open it once, then rerun this command."
command -v curl >/dev/null 2>&1 || die "curl is required."

install_build_dependency() {
    local command_name="$1"
    local formula="$2"

    if command -v "$command_name" >/dev/null 2>&1; then
        return
    fi
    command -v brew >/dev/null 2>&1 \
        || die "$command_name is required. Install Homebrew from https://brew.sh, then rerun this command."
    log "Installing $formula with Homebrew"
    brew install "$formula"
}

install_build_dependency xcodegen xcodegen
install_build_dependency npm node

log "Downloading the latest AgentMicro source"
git clone --depth 1 "$REPOSITORY_URL" "$SOURCE_ROOT"

log "Building the self-contained Mac app"
"$SOURCE_ROOT/scripts/build-macos.sh"

BUILT_APPLICATION="$SOURCE_ROOT/dist/AgentMicro.app"
[[ -d "$BUILT_APPLICATION" ]] || die "The build completed without producing AgentMicro.app."

log "Installing AgentMicro in Applications"
osascript -e 'tell application "AgentMicro" to quit' >/dev/null 2>&1 || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if ! pgrep -x AgentMicro >/dev/null 2>&1; then
        break
    fi
    sleep 0.2
done

if [[ -e "$APPLICATION_PATH" ]]; then
    [[ "$APPLICATION_PATH" == "/Applications/AgentMicro.app" ]] \
        || die "Refusing to replace an unexpected path: $APPLICATION_PATH"
    rm -rf "$APPLICATION_PATH"
fi
ditto "$BUILT_APPLICATION" "$APPLICATION_PATH"

codesign --verify --deep --strict "$APPLICATION_PATH"
log "Launching AgentMicro"
open "$APPLICATION_PATH"

log "Installed. Follow the onboarding window; no terminal is needed for the ChatGPT patch."
