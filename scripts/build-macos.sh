#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MACOS_ROOT="$REPO_ROOT/macos/CodexMicro"
DIST_ROOT="$REPO_ROOT/dist"
BUILD_ROOT="$DIST_ROOT/.build"
GENERATED_PROJECT_ROOT="$BUILD_ROOT/GeneratedProject"
DERIVED_DATA_ROOT="$BUILD_ROOT/DerivedData"
PRODUCTS_ROOT="$BUILD_ROOT/Products"
RUNTIME_ROOT="$BUILD_ROOT/PatchRuntime"
APP_NAME="AgentMicro.app"
APP_PATH="$DIST_ROOT/$APP_NAME"

NODE_VERSION="24.18.0"
NODE_ARCHIVE_SHA256="e1a97e14c99c803e96c7339403282ea05a499c32f8d83defe9ef5ec66f979ed1"
NODE_DISTRIBUTION="node-v${NODE_VERSION}-darwin-arm64"
NODE_ARCHIVE_NAME="${NODE_DISTRIBUTION}.tar.gz"
NODE_BASE_URL="https://nodejs.org/dist/v${NODE_VERSION}"
CACHE_ROOT="${CODEX_MICRO_BUILD_CACHE:-$HOME/Library/Caches/CodexMicroBuild}"
NODE_CACHE_ROOT="$CACHE_ROOT/node/v${NODE_VERSION}"
NPM_CACHE_ROOT="$CACHE_ROOT/npm"
SIGN_IDENTITY="${MACOS_SIGN_IDENTITY:--}"

log() {
    printf '[build-macos] %s\n' "$*"
}

die() {
    printf '[build-macos] ERROR: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

cleanup() {
    if [[ -n "${TEMP_ROOT:-}" && -d "$TEMP_ROOT" ]]; then
        rm -rf "$TEMP_ROOT"
    fi
}

prepare_node_runtime() {
    local destination="$1"

    local archive_override="${CODEX_MICRO_NODE_ARCHIVE:-}"
    local archive="$NODE_CACHE_ROOT/$NODE_ARCHIVE_NAME"

    mkdir -p "$NODE_CACHE_ROOT"

    if [[ -n "$archive_override" ]]; then
        [[ -f "$archive_override" ]] || die "CODEX_MICRO_NODE_ARCHIVE does not exist: $archive_override"
        cp "$archive_override" "$archive"
    elif [[ ! -f "$archive" ]]; then
        log "downloading the pinned Node.js ${NODE_VERSION} Apple Silicon runtime"
        curl --fail --location --retry 3 \
            --output "$archive.download" \
            "$NODE_BASE_URL/$NODE_ARCHIVE_NAME"
        mv "$archive.download" "$archive"
    fi

    local actual
    actual="$(shasum -a 256 "$archive" | awk '{ print $1 }')"
    [[ "$actual" == "$NODE_ARCHIVE_SHA256" ]] \
        || die "Node.js archive checksum does not match the pinned official release"

    local extract_root="$TEMP_ROOT/node"
    mkdir -p "$extract_root"
    tar -xzf "$archive" -C "$extract_root"
    install -m 0755 "$extract_root/$NODE_DISTRIBUTION/bin/node" "$destination"
    install -m 0644 \
        "$extract_root/$NODE_DISTRIBUTION/LICENSE" \
        "$(dirname "$destination")/NODE-LICENSE.txt"
}

prepare_patch_runtime() {
    log "preparing the self-contained ChatGPT patch runtime"
    mkdir -p "$RUNTIME_ROOT"

    install -m 0755 "$REPO_ROOT/tools/patch-chatgpt.sh" "$RUNTIME_ROOT/patch-chatgpt.sh"
    install -m 0644 \
        "$REPO_ROOT/tools/CodexMicroBridge/codex-hid-shim.js" \
        "$RUNTIME_ROOT/codex-hid-shim.js"
    install -m 0644 \
        "$MACOS_ROOT/PatchRuntime/asar-inspect.cjs" \
        "$RUNTIME_ROOT/asar-inspect.cjs"
    install -m 0644 \
        "$MACOS_ROOT/Support/PatchRuntime/package.json" \
        "$RUNTIME_ROOT/package.json"
    install -m 0644 \
        "$MACOS_ROOT/Support/PatchRuntime/package-lock.json" \
        "$RUNTIME_ROOT/package-lock.json"
    install -m 0644 \
        "$MACOS_ROOT/Support/THIRD-PARTY-NOTICES.txt" \
        "$RUNTIME_ROOT/THIRD-PARTY-NOTICES.txt"

    prepare_node_runtime "$RUNTIME_ROOT/node"

    npm ci \
        --prefix "$RUNTIME_ROOT" \
        --cache "$NPM_CACHE_ROOT" \
        --omit=dev \
        --ignore-scripts \
        --no-audit \
        --no-fund

    [[ -f "$RUNTIME_ROOT/node_modules/@electron/asar/bin/asar.mjs" ]] \
        || die "the locked ASAR runtime was not installed correctly"

    "$RUNTIME_ROOT/node" \
        "$RUNTIME_ROOT/node_modules/@electron/asar/bin/asar.mjs" \
        --version >/dev/null

    printf '{\n  "node": "%s",\n  "asar": "4.2.1"\n}\n' \
        "$NODE_VERSION" > "$RUNTIME_ROOT/runtime-version.json"
}

sign_application() {
    local app="$1"
    local node="$app/Contents/Resources/PatchRuntime/node"
    local entitlements="$MACOS_ROOT/Support/CodexMicro.entitlements"
    local node_entitlements="$MACOS_ROOT/Support/NodeRuntime.entitlements"

    if [[ "$SIGN_IDENTITY" == "-" ]]; then
        log "applying an ad-hoc signature"
        codesign --force --sign - "$node"
        codesign --force --sign - --entitlements "$entitlements" "$app"
    else
        log "signing with Developer ID identity: $SIGN_IDENTITY"
        codesign \
            --force \
            --timestamp \
            --options runtime \
            --entitlements "$node_entitlements" \
            --sign "$SIGN_IDENTITY" \
            "$node"
        codesign \
            --force \
            --timestamp \
            --options runtime \
            --entitlements "$entitlements" \
            --sign "$SIGN_IDENTITY" \
            "$app"
    fi

    local smoke_result
    smoke_result="$(
        "$node" -e \
            'const f = new Function("x", "return ((x * 3) + 7) | 0"); let v = 0; for (let i = 0; i < 200000; i += 1) v = f(i); if (v !== 600004) process.exit(9); process.stdout.write("v8-jit-ok");'
    )"
    [[ "$smoke_result" == "v8-jit-ok" ]] \
        || die "the signed bundled Node runtime failed its dynamic V8 smoke test"

    codesign --verify --deep --strict --verbose=2 "$app"
}

[[ "$(uname -s)" == "Darwin" ]] || die "the macOS app can only be built on macOS"
[[ "$(uname -m)" == "arm64" ]] || die "this build is intentionally Apple Silicon only"
[[ -d "$MACOS_ROOT/Sources" ]] || die "macOS sources are missing at $MACOS_ROOT/Sources"
[[ -f "$MACOS_ROOT/project.yml" ]] || die "XcodeGen project specification is missing"

require_command xcodegen
require_command xcodebuild
require_command npm
require_command curl
require_command shasum
require_command codesign

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/codexmicro-build.XXXXXX")"
trap cleanup EXIT

# DIST_ROOT is fixed under the repository so this clean cannot expand to an
# unrelated directory through an environment variable.
rm -rf "$DIST_ROOT"
mkdir -p "$BUILD_ROOT" "$GENERATED_PROJECT_ROOT" "$PRODUCTS_ROOT"

prepare_patch_runtime

# Folder-reference resources are resolved from the generated Xcode project's
# SOURCE_ROOT. Keep the generated project isolated in dist while pointing its
# development placeholder at the source-controlled directory.
mkdir -p "$GENERATED_PROJECT_ROOT/Support"
ln -s "$MACOS_ROOT/Support/PatchRuntime" \
    "$GENERATED_PROJECT_ROOT/Support/PatchRuntime"

log "generating the Xcode project"
xcodegen generate \
    --spec "$MACOS_ROOT/project.yml" \
    --project "$GENERATED_PROJECT_ROOT" \
    --project-root "$MACOS_ROOT" \
    --quiet

log "building AgentMicro for macOS 14+ on Apple Silicon"
xcodebuild \
    -project "$GENERATED_PROJECT_ROOT/CodexMicro.xcodeproj" \
    -scheme CodexMicro \
    -configuration Release \
    -destination "platform=macOS,arch=arm64" \
    -derivedDataPath "$DERIVED_DATA_ROOT" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    INFOPLIST_FILE="$MACOS_ROOT/Support/Info.plist" \
    CODE_SIGN_ENTITLEMENTS="$MACOS_ROOT/Support/CodexMicro.entitlements" \
    CONFIGURATION_BUILD_DIR="$PRODUCTS_ROOT" \
    build

BUILT_APP="$PRODUCTS_ROOT/$APP_NAME"
[[ -d "$BUILT_APP" ]] || die "Xcode did not produce $BUILT_APP"

log "assembling the distribution app"
ditto "$BUILT_APP" "$APP_PATH"
rm -rf "$APP_PATH/Contents/Resources/PatchRuntime"
ditto "$RUNTIME_ROOT" "$APP_PATH/Contents/Resources/PatchRuntime"
chmod 0755 \
    "$APP_PATH/Contents/Resources/PatchRuntime/node" \
    "$APP_PATH/Contents/Resources/PatchRuntime/patch-chatgpt.sh"

sign_application "$APP_PATH"

[[ "$(plutil -extract LSUIElement raw -o - "$APP_PATH/Contents/Info.plist")" == "true" ]] \
    || die "built app is not configured as a menu-bar application"
[[ "$(plutil -extract CFBundleIdentifier raw -o - "$APP_PATH/Contents/Info.plist")" \
    == "io.github.thislev.codexmicro" ]] \
    || die "built app has the wrong bundle identifier"

log "finished: $APP_PATH"
