#!/usr/bin/env bash
# Reversible ChatGPT patch manager for AgentMicro.
#
# The distributed menu-bar app supplies a pinned Node runtime, @electron/asar,
# the read-only ASAR inspector, and the bridge shim through PatchRuntime. A
# source checkout may opt into the developer fallback, which uses system Node
# and npx.
#
# Usage:
#   patch-chatgpt.sh --status [--json]
#   patch-chatgpt.sh --patch [--relaunch]
#   patch-chatgpt.sh --restore [--relaunch]
#
# Environment:
#   CHATGPT_APP                    ChatGPT.app path
#   AGENT_MICRO_PATCH_RUNTIME      bundled PatchRuntime directory
#   AGENT_MICRO_NODE               explicit Node executable
#   AGENT_MICRO_ASAR_JS            explicit @electron/asar bin/asar.mjs
#   AGENT_MICRO_SHIM               explicit codex-hid-shim.js
#   AGENT_MICRO_INSPECTOR          explicit asar-inspect.cjs
#   AGENT_MICRO_BACKUP_ROOT        versioned backup root
#   AGENT_MICRO_LEGACY_BACKUP_ROOT existing resource-only backup root
#   AGENT_MICRO_STATE_ROOT         operation-lock directory
#   AGENT_MICRO_DEVELOPER_FALLBACK allow system Node/npx when set to 1
#   PACK_ONLY                      build artifacts without installing when 1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP="${CHATGPT_APP:-/Applications/ChatGPT.app}"
RUNTIME_ROOT="${AGENT_MICRO_PATCH_RUNTIME:-$SCRIPT_DIR}"
BACKUP_ROOT="${AGENT_MICRO_BACKUP_ROOT:-$HOME/Library/Application Support/AgentMicro/Backups}"
LEGACY_BACKUP_ROOT="${AGENT_MICRO_LEGACY_BACKUP_ROOT:-$HOME/.codexbridge/backup}"
STATE_ROOT="${AGENT_MICRO_STATE_ROOT:-$HOME/Library/Application Support/AgentMicro}"
DEVELOPER_FALLBACK="${AGENT_MICRO_DEVELOPER_FALLBACK:-}"
OPENAI_TEAM_IDENTIFIER="2DC432GLL2"
PATCH_SCHEMA=2
MODE="patch"
JSON_OUTPUT=0
RELAUNCH=0
WORK=""
LOCK_DIR=""

case "$SCRIPT_DIR" in
    "$REPO_ROOT/tools") : "${DEVELOPER_FALLBACK:=1}" ;;
    *) : "${DEVELOPER_FALLBACK:=0}" ;;
esac

while [ "$#" -gt 0 ]; do
    case "$1" in
        --status) MODE="status" ;;
        --patch) MODE="patch" ;;
        --restore) MODE="restore" ;;
        --json) JSON_OUTPUT=1 ;;
        --relaunch) RELAUNCH=1 ;;
        -h|--help)
            sed -n '2,29p' "$0"
            exit 0
            ;;
        *) printf 'AgentMicro patcher: unknown argument: %s\n' "$1" >&2; exit 64 ;;
    esac
    shift
done

json_escape() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\t'/\\t}"
    printf '%s' "$value"
}

emit_event() {
    local event="$1"
    local stage="$2"
    local message="$3"
    local progress="${4:--1}"
    printf 'AGENT_MICRO_EVENT\t{"event":"%s","stage":"%s","message":"%s","progress":%s}\n' \
        "$(json_escape "$event")" \
        "$(json_escape "$stage")" \
        "$(json_escape "$message")" \
        "$progress"
}

log() {
    printf '[AgentMicro] %s\n' "$*" >&2
}

die() {
    local stage="$1"
    local message="$2"
    local code="${3:-1}"
    emit_event "error" "$stage" "$message"
    printf '[AgentMicro] ERROR: %s\n' "$message" >&2
    exit "$code"
}

cleanup() {
    if [ -n "$WORK" ] && [ -d "$WORK" ]; then
        rm -rf "$WORK"
    fi
    if [ -n "$LOCK_DIR" ] && [ -d "$LOCK_DIR" ]; then
        rm -f "$LOCK_DIR/pid" 2>/dev/null || true
        rmdir "$LOCK_DIR" 2>/dev/null || true
    fi
}

unexpected_error() {
    local code="$1"
    emit_event "error" "internal" \
        "The patch operation stopped before installation. ChatGPT was not force-quit."
    exit "$code"
}

trap 'unexpected_error $?' ERR
trap cleanup EXIT INT TERM

first_executable() {
    for candidate in "$@"; do
        if [ -n "$candidate" ] && [ -x "$candidate" ]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

first_file() {
    for candidate in "$@"; do
        if [ -n "$candidate" ] && [ -f "$candidate" ]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

SYSTEM_NODE=""
SYSTEM_NPX=""
if [ "$DEVELOPER_FALLBACK" = "1" ]; then
    SYSTEM_NODE="$(command -v node 2>/dev/null || true)"
    SYSTEM_NPX="$(command -v npx 2>/dev/null || true)"
fi

NODE_BIN="$(first_executable \
    "${AGENT_MICRO_NODE:-}" \
    "$RUNTIME_ROOT/node" \
    "$RUNTIME_ROOT/bin/node" \
    "$SYSTEM_NODE" || true)"

INSPECTOR="$(first_file \
    "${AGENT_MICRO_INSPECTOR:-}" \
    "$RUNTIME_ROOT/asar-inspect.cjs" \
    "$REPO_ROOT/macos/AgentMicro/PatchRuntime/asar-inspect.cjs" || true)"

if [ "${AGENT_MICRO_SHIM+x}" = "x" ]; then
    # An explicit runtime path is authoritative. Falling back when it is
    # missing would hide an incomplete distributed app and offer Patch anyway.
    SHIM_SRC="$(first_file "$AGENT_MICRO_SHIM" || true)"
else
    SHIM_SRC="$(first_file \
        "$RUNTIME_ROOT/codex-hid-shim.js" \
        "$REPO_ROOT/tools/AgentMicroBridge/codex-hid-shim.js" || true)"
fi

ASAR_JS="$(first_file \
    "${AGENT_MICRO_ASAR_JS:-}" \
    "$RUNTIME_ROOT/node_modules/@electron/asar/bin/asar.mjs" \
    "$RUNTIME_ROOT/node_modules/@electron/asar/bin/asar.js" \
    "$REPO_ROOT/node_modules/@electron/asar/bin/asar.mjs" \
    "$REPO_ROOT/node_modules/@electron/asar/bin/asar.js" || true)"

ASAR_MODE=""
if [ -n "$NODE_BIN" ] && [ -n "$ASAR_JS" ]; then
    ASAR_MODE="bundled"
elif [ "$DEVELOPER_FALLBACK" = "1" ] && [ -n "$SYSTEM_NPX" ]; then
    ASAR_MODE="npx"
fi

run_asar() {
    if [ "$ASAR_MODE" = "bundled" ]; then
        "$NODE_BIN" "$ASAR_JS" "$@"
    elif [ "$ASAR_MODE" = "npx" ]; then
        "$SYSTEM_NPX" --yes @electron/asar "$@"
    else
        return 127
    fi
}

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true
}

safe_component() {
    printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_'
}

APP_INFO="$APP/Contents/Info.plist"
RESOURCES="$APP/Contents/Resources"
ASAR_PATH="$RESOURCES/app.asar"
BUNDLE_ID=""
EXECUTABLE_NAME=""
VERSION=""
BUILD=""
BACKUP_DIR=""
LEGACY_BACKUP_DIR=""
BACKUP_KIND="none"
PATCH_STATE="not-installed"
PATCHED=false
COMPATIBLE=false
STATUS_REASON="ChatGPT is not installed at the configured location."
BACKUP_AVAILABLE=false
RUNNING=false

chatgpt_is_running() {
    if [ -z "$EXECUTABLE_NAME" ]; then
        return 1
    fi
    local executable_path="$APP/Contents/MacOS/$EXECUTABLE_NAME"
    local escaped_path
    escaped_path="$(
        printf '%s' "$executable_path" \
            | /usr/bin/sed 's/[][\\.^$*+?(){}|]/\\&/g'
    )"
    /usr/bin/pgrep -f "^${escaped_path}([[:space:]]|$)" >/dev/null 2>&1
}

json_field() {
    local json="$1"
    local field="$2"
    INSPECTION_JSON="$json" "$NODE_BIN" -e \
        'const v=JSON.parse(process.env.INSPECTION_JSON); const x=v[process.argv[1]]; process.stdout.write(x == null ? "" : String(x));' \
        "$field"
}

json_file_field() {
    local file="$1"
    local field="$2"
    "$NODE_BIN" -e '
      const fs = require("fs");
      const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const result = value[process.argv[2]];
      process.stdout.write(result == null ? "" : String(result));
    ' "$file" "$field" 2>/dev/null || true
}

inspect_asar_state_quiet() {
    local candidate="$1"
    local result=""
    if [ -z "$NODE_BIN" ] || [ -z "$INSPECTOR" ] || [ ! -f "$candidate" ]; then
        printf 'incompatible'
        return 0
    fi
    if result="$("$NODE_BIN" "$INSPECTOR" "$candidate" 2>/dev/null)"; then
        :
    fi
    if [ -z "$result" ]; then
        printf 'incompatible'
    else
        json_field "$result" state
    fi
}

asar_header_hash() {
    local candidate="$1"
    ASAR_TO_HASH="$candidate" "$NODE_BIN" -e '
      const fs = require("fs");
      const crypto = require("crypto");
      const maximumHeaderBytes = 64 * 1024 * 1024;
      const descriptor = fs.openSync(process.env.ASAR_TO_HASH, "r");
      const readExact = (buffer, position) => {
        let offset = 0;
        while (offset < buffer.length) {
          const count = fs.readSync(
            descriptor,
            buffer,
            offset,
            buffer.length - offset,
            position + offset
          );
          if (count === 0) process.exit(2);
          offset += count;
        }
      };
      try {
        const prefix = Buffer.alloc(16);
        readExact(prefix, 0);
        const headerBlockSize = prefix.readUInt32LE(4);
        const jsonLength = prefix.readUInt32LE(12);
        if (
          headerBlockSize < 8
          || jsonLength === 0
          || jsonLength > headerBlockSize
          || jsonLength > maximumHeaderBytes
        ) {
          process.exit(2);
        }
        const headerJSON = Buffer.alloc(jsonLength);
        readExact(headerJSON, 16);
        process.stdout.write(
          crypto.createHash("sha256").update(headerJSON).digest("hex")
        );
      } finally {
        fs.closeSync(descriptor);
      }
    '
}

backup_identity_matches() {
    local info="$1"
    [ -f "$info" ] \
        && [ "$(plist_value "$info" CFBundleIdentifier)" = "$BUNDLE_ID" ] \
        && [ "$(plist_value "$info" CFBundleShortVersionString)" = "$VERSION" ] \
        && [ "$(plist_value "$info" CFBundleVersion)" = "$BUILD" ]
}

signature_metadata_is_openai() {
    local candidate="$1"
    local signature_info
    local team_identifier
    signature_info="$(/usr/bin/codesign -d --verbose=4 "$candidate" 2>&1 || true)"
    printf '%s\n' "$signature_info" | grep -q '^Signature=adhoc$' && return 1
    team_identifier="$(
        printf '%s\n' "$signature_info" \
            | /usr/bin/sed -n 's/^TeamIdentifier=//p' \
            | head -1
    )"
    [ "$team_identifier" = "$OPENAI_TEAM_IDENTIFIER" ]
}

asar_header_matches_plist() {
    local asar="$1"
    local info="$2"
    local expected
    local actual
    expected="$(plist_value "$info" "ElectronAsarIntegrity:Resources/app.asar:hash")"
    [ -n "$expected" ] || return 1
    actual="$(asar_header_hash "$asar" 2>/dev/null || true)"
    [ -n "$actual" ] && [ "$actual" = "$expected" ]
}

full_backup_is_valid_quick() {
    local backup_app="$BACKUP_DIR/ChatGPT.app"
    local info="$backup_app/Contents/Info.plist"
    local asar="$backup_app/Contents/Resources/app.asar"
    local unpacked="$backup_app/Contents/Resources/app.asar.unpacked"
    local manifest="$BACKUP_DIR/manifest.json"
    local expected_asar_hash
    local expected_info_hash
    [ -d "$backup_app" ] && [ -f "$asar" ] && [ -d "$unpacked" ] \
        && [ -f "$manifest" ] || return 1
    backup_identity_matches "$info" || return 1
    [ "$(json_file_field "$manifest" schemaVersion)" = "1" ] || return 1
    [ "$(json_file_field "$manifest" bundleIdentifier)" = "$BUNDLE_ID" ] || return 1
    [ "$(json_file_field "$manifest" version)" = "$VERSION" ] || return 1
    [ "$(json_file_field "$manifest" build)" = "$BUILD" ] || return 1
    [ "$(json_file_field "$manifest" signatureKind)" = "openai-developer-id" ] \
        || return 1
    [ "$(json_file_field "$manifest" signerTeamIdentifier)" = "$OPENAI_TEAM_IDENTIFIER" ] \
        || return 1
    expected_asar_hash="$(json_file_field "$manifest" pristineAsarSHA256)"
    [ "${#expected_asar_hash}" -eq 64 ] || return 1
    [ "$(json_file_field "$manifest" pristineAsarBytes)" = "$(/usr/bin/stat -f %z "$asar")" ] \
        || return 1
    expected_info_hash="$(json_file_field "$manifest" pristineInfoSHA256)"
    [ -n "$expected_info_hash" ] \
        && [ "$expected_info_hash" = "$(/usr/bin/shasum -a 256 "$info" | awk '{print $1}')" ] \
        && signature_metadata_is_openai "$backup_app"
}

legacy_backup_is_valid_quick() {
    local info="$LEGACY_BACKUP_DIR/Info.plist"
    local asar="$LEGACY_BACKUP_DIR/app.asar"
    [ -f "$asar" ] && [ -d "$LEGACY_BACKUP_DIR/app.asar.unpacked" ] || return 1
    backup_identity_matches "$info" || return 1
    asar_header_matches_plist "$asar" "$info"
}

select_available_backup() {
    BACKUP_AVAILABLE=false
    BACKUP_KIND="none"
    if full_backup_is_valid_quick; then
        BACKUP_AVAILABLE=true
        BACKUP_KIND="complete-signed"
    elif legacy_backup_is_valid_quick; then
        BACKUP_AVAILABLE=true
        BACKUP_KIND="legacy-resources"
    fi
}

inspect_installation() {
    if [ ! -d "$APP" ]; then
        return 0
    fi
    if [ ! -f "$APP_INFO" ]; then
        PATCH_STATE="incompatible"
        STATUS_REASON="The selected application has no Contents/Info.plist."
        return 0
    fi

    BUNDLE_ID="$(plist_value "$APP_INFO" CFBundleIdentifier)"
    EXECUTABLE_NAME="$(plist_value "$APP_INFO" CFBundleExecutable)"
    VERSION="$(plist_value "$APP_INFO" CFBundleShortVersionString)"
    BUILD="$(plist_value "$APP_INFO" CFBundleVersion)"
    VERSION="${VERSION:-unknown}"
    BUILD="${BUILD:-unknown}"
    BACKUP_DIR="$BACKUP_ROOT/$(safe_component "${VERSION}_${BUILD}")"
    LEGACY_BACKUP_DIR="$LEGACY_BACKUP_ROOT/$VERSION"
    if chatgpt_is_running; then
        RUNNING=true
    fi

    case "$BUNDLE_ID" in
        com.openai.codex|com.openai.chat) ;;
        *)
            PATCH_STATE="incompatible"
            STATUS_REASON="The selected app is not a supported OpenAI ChatGPT/Codex desktop bundle."
            return 0
            ;;
    esac

    if [ -z "$NODE_BIN" ] || [ -z "$INSPECTOR" ]; then
        PATCH_STATE="runtime-unavailable"
        STATUS_REASON="The bundled patch inspection runtime is missing."
        return 0
    fi
    select_available_backup
    if [ ! -f "$ASAR_PATH" ] || [ ! -d "$RESOURCES/app.asar.unpacked" ]; then
        PATCH_STATE="incompatible"
        STATUS_REASON="ChatGPT has an unsupported resource layout."
        return 0
    fi

    local inspection_json=""
    if inspection_json="$("$NODE_BIN" "$INSPECTOR" "$ASAR_PATH" 2>/dev/null)"; then
        :
    else
        # The inspector deliberately exits non-zero for an incompatible build
        # while still returning a complete JSON result.
        if [ -z "$inspection_json" ]; then
            PATCH_STATE="incompatible"
            STATUS_REASON="The ChatGPT ASAR could not be inspected."
            return 0
        fi
    fi

    PATCH_STATE="$(json_field "$inspection_json" state)"
    PATCHED="$(json_field "$inspection_json" patched)"
    COMPATIBLE="$(json_field "$inspection_json" compatible)"
    STATUS_REASON="$(json_field "$inspection_json" reason)"
    if [ "$PATCH_STATE" = "integration-update-required" ]; then
        if [ "$BACKUP_AVAILABLE" = true ]; then
            STATUS_REASON="The AgentMicro integration needs an update. Choose Restore ChatGPT, then Patch ChatGPT to install the current integration."
        else
            STATUS_REASON="The AgentMicro integration needs an update, but no exact backup is available. Reinstall ChatGPT, then choose Patch ChatGPT."
        fi
    fi
}

emit_status_json() {
    local installed=false
    local can_patch=false
    local can_restore=false
    [ -d "$APP" ] && installed=true
    [ "$PATCH_STATE" = "compatible-pristine" ] && [ -n "$ASAR_MODE" ] && [ -n "$SHIM_SRC" ] && can_patch=true
    [ "$BACKUP_AVAILABLE" = true ] && can_restore=true

    # A pristine build with incomplete patch tooling used to keep the
    # "supported bundle structure" reason while Patch was disabled, and an
    # unpatched install has no backup to restore. That left both buttons grey
    # behind a reason claiming nothing was wrong. Report the real blocker so
    # the UI can state a recovery step.
    if [ "$PATCH_STATE" = "compatible-pristine" ] && [ "$can_patch" = false ]; then
        STATUS_REASON="AgentMicro's patch runtime is incomplete, so ChatGPT cannot be patched. Reinstall AgentMicro."
    fi

    printf '{"schemaVersion":2,"installed":%s,"running":%s,"path":"%s","bundleIdentifier":"%s","version":"%s","build":"%s","patchState":"%s","patched":%s,"compatible":%s,"backupAvailable":%s,"backupKind":"%s","canPatch":%s,"canRestore":%s,"reason":"%s"}\n' \
        "$installed" \
        "$RUNNING" \
        "$(json_escape "$APP")" \
        "$(json_escape "$BUNDLE_ID")" \
        "$(json_escape "$VERSION")" \
        "$(json_escape "$BUILD")" \
        "$(json_escape "$PATCH_STATE")" \
        "$PATCHED" \
        "$COMPATIBLE" \
        "$BACKUP_AVAILABLE" \
        "$(json_escape "$BACKUP_KIND")" \
        "$can_patch" \
        "$can_restore" \
        "$(json_escape "$STATUS_REASON")"
}

inspect_installation

if [ "$MODE" = "status" ]; then
    if [ "$JSON_OUTPUT" = "1" ]; then
        emit_status_json
    else
        printf 'ChatGPT: %s (%s)\n' "${VERSION:-not installed}" "${BUILD:-no build}"
        printf 'Running: %s\n' "$RUNNING"
        printf 'Patch state: %s\n' "$PATCH_STATE"
        printf 'Backup available: %s (%s)\n' "$BACKUP_AVAILABLE" "$BACKUP_KIND"
        printf '%s\n' "$STATUS_REASON"
    fi
    exit 0
fi

[ -d "$APP" ] || die "preflight" "ChatGPT.app was not found at $APP."
[ -n "$NODE_BIN" ] || die "runtime" "The bundled Node runtime is missing."
[ -n "$INSPECTOR" ] || die "runtime" "The bundled ASAR inspector is missing."

LOCK_PARENT="$STATE_ROOT"
mkdir -p "$LOCK_PARENT"
LOCK_DIR="$LOCK_PARENT/.patch-operation.lock"
if [ -d "$LOCK_DIR" ]; then
    lock_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
        die "busy" "Another AgentMicro patch or restore operation is already running." 75
    fi
    rm -f "$LOCK_DIR/pid" 2>/dev/null || true
    rmdir "$LOCK_DIR" 2>/dev/null || true
fi
mkdir "$LOCK_DIR" 2>/dev/null \
    || die "permission" "AgentMicro could not create its operation lock." 77
printf '%s\n' "$$" > "$LOCK_DIR/pid"

request_chatgpt_quit() {
    if ! chatgpt_is_running; then
        return 0
    fi
    emit_event "progress" "quitting" "Waiting for ChatGPT to close safely…" 0.82
    /usr/bin/osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    local attempt=0
    while [ "$attempt" -lt 60 ]; do
        if ! chatgpt_is_running; then
            return 0
        fi
        sleep 0.25
        attempt=$((attempt + 1))
    done
    die "quitting" "ChatGPT did not finish quitting. Nothing was replaced; close it normally and try again." 73
}

relaunch_chatgpt_if_requested() {
    if [ "$RELAUNCH" = "1" ]; then
        emit_event "progress" "relaunching" "Opening ChatGPT…" 0.98
        /usr/bin/open "$APP" >/dev/null 2>&1 \
            || die "relaunching" "The operation succeeded, but ChatGPT could not be reopened."
    fi
}

require_pristine_signature() {
    local candidate="$1"
    /usr/bin/codesign --verify --deep --strict "$candidate" >/dev/null 2>&1 \
        || die "backup" "The pristine ChatGPT signature is invalid; reinstall ChatGPT before patching."
    signature_metadata_is_openai "$candidate" \
        || die "backup" \
            "The pristine ChatGPT signature is not from OpenAI TeamIdentifier $OPENAI_TEAM_IDENTIFIER; it cannot be called an OpenAI-signed backup."
}

inspect_asar_state() {
    inspect_asar_state_quiet "$1"
}

validate_complete_backup_full() {
    full_backup_is_valid_quick \
        || die "backup" "The complete backup metadata does not exactly match ChatGPT $VERSION ($BUILD)."
    local backup_app="$BACKUP_DIR/ChatGPT.app"
    local info="$backup_app/Contents/Info.plist"
    local asar="$backup_app/Contents/Resources/app.asar"
    local expected_hash
    local actual_hash
    expected_hash="$(json_file_field "$BACKUP_DIR/manifest.json" pristineAsarSHA256)"
    actual_hash="$(/usr/bin/shasum -a 256 "$asar" | awk '{print $1}')"
    [ -n "$expected_hash" ] && [ "$expected_hash" = "$actual_hash" ] \
        || die "backup" "The complete backup app.asar no longer matches its retained manifest."
    [ "$(inspect_asar_state "$asar")" = "compatible-pristine" ] \
        || die "backup" "The complete backup is not a supported pristine ChatGPT bundle."
    asar_header_matches_plist "$asar" "$info" \
        || die "backup" "The complete backup ASAR header does not match its Info.plist."
    require_pristine_signature "$backup_app"
}

validate_legacy_backup_full() {
    local validation_stage="${1:-restore}"
    legacy_backup_is_valid_quick \
        || die "$validation_stage" "The legacy backup does not exactly match ChatGPT $VERSION ($BUILD)."

    local result=""
    if result="$(
        "$NODE_BIN" "$INSPECTOR" "$LEGACY_BACKUP_DIR/app.asar" \
            --verify-integrity 2>/dev/null
    )"; then
        :
    fi
    [ -n "$result" ] \
        || die "$validation_stage" "The legacy backup could not be fully integrity-checked."
    [ "$(json_field "$result" state)" = "compatible-pristine" ] \
        || die "$validation_stage" "The legacy backup is not a supported pristine ChatGPT bundle."
    [ "$(json_field "$result" compatible)" = "true" ] \
        || die "$validation_stage" "The legacy backup failed its compatibility check."
    asar_header_matches_plist \
        "$LEGACY_BACKUP_DIR/app.asar" \
        "$LEGACY_BACKUP_DIR/Info.plist" \
        || die "$validation_stage" "The legacy app.asar header does not match its pristine Info.plist."
}

ensure_pristine_backup() {
    if full_backup_is_valid_quick; then
        emit_event "progress" "backup" \
            "Validating the complete signed ChatGPT backup…" 0.22
        validate_complete_backup_full
        return 0
    fi
    if legacy_backup_is_valid_quick; then
        validate_legacy_backup_full "backup"
        emit_event "progress" "backup" \
            "Using the validated resource backup for ChatGPT $VERSION ($BUILD); it will not be overwritten." 0.12
        BACKUP_AVAILABLE=true
        BACKUP_KIND="legacy-resources"
        return 0
    fi
    if [ -d "$BACKUP_DIR/ChatGPT.app" ]; then
        die "backup" "The complete versioned backup is invalid. Move it aside and reinstall ChatGPT before patching."
    fi

    require_pristine_signature "$APP"
    emit_event "progress" "backup" "Saving a complete pristine backup for ChatGPT $VERSION ($BUILD)…" 0.12
    mkdir -p "$BACKUP_ROOT"
    local incoming="$BACKUP_ROOT/.incoming-$(safe_component "${VERSION}_${BUILD}")-$$"
    rm -rf "$incoming"
    mkdir -p "$incoming"
    /usr/bin/ditto --rsrc --extattr --acl "$APP" "$incoming/ChatGPT.app" \
        || die "backup" "The complete pristine ChatGPT backup could not be created."
    require_pristine_signature "$incoming/ChatGPT.app"
    [ "$(inspect_asar_state "$incoming/ChatGPT.app/Contents/Resources/app.asar")" = "compatible-pristine" ] \
        || die "backup" "Backup validation failed because its bundle is not pristine."

    local asar_hash
    local asar_bytes
    local info_hash
    asar_hash="$(/usr/bin/shasum -a 256 "$ASAR_PATH" | awk '{print $1}')"
    asar_bytes="$(/usr/bin/stat -f %z "$ASAR_PATH")"
    info_hash="$(/usr/bin/shasum -a 256 "$APP_INFO" | awk '{print $1}')"
    VERSION_VALUE="$VERSION" BUILD_VALUE="$BUILD" BUNDLE_VALUE="$BUNDLE_ID" \
        HASH_VALUE="$asar_hash" BYTES_VALUE="$asar_bytes" INFO_HASH_VALUE="$info_hash" \
        TEAM_VALUE="$OPENAI_TEAM_IDENTIFIER" \
        "$NODE_BIN" -e '
          const fs = require("fs");
          const value = {
            schemaVersion: 1,
            bundleIdentifier: process.env.BUNDLE_VALUE,
            version: process.env.VERSION_VALUE,
            build: process.env.BUILD_VALUE,
            pristineAsarSHA256: process.env.HASH_VALUE,
            pristineAsarBytes: Number(process.env.BYTES_VALUE),
            pristineInfoSHA256: process.env.INFO_HASH_VALUE,
            signatureKind: "openai-developer-id",
            signerTeamIdentifier: process.env.TEAM_VALUE,
            createdAt: new Date().toISOString()
          };
          fs.writeFileSync(process.argv[1], JSON.stringify(value, null, 2) + "\n");
        ' "$incoming/manifest.json"
    mv "$incoming" "$BACKUP_DIR" \
        || die "backup" "The validated backup could not be committed."
    BACKUP_AVAILABLE=true
    BACKUP_KIND="complete-signed"
}

app_management_error() {
    die "permission" "macOS blocked changes to ChatGPT.app. Allow AgentMicro under Privacy & Security › App Management, then try again." 77
}

nearest_existing_path() {
    local candidate="$1"
    while [ ! -e "$candidate" ] && [ "$candidate" != "/" ]; do
        candidate="$(dirname "$candidate")"
    done
    printf '%s' "$candidate"
}

available_kilobytes() {
    local candidate
    candidate="$(nearest_existing_path "$1")"
    /bin/df -Pk "$candidate" | tail -1 | awk '{print $4}'
}

require_free_space() {
    local multiplier="$1"
    shift
    local app_kilobytes
    local required_kilobytes
    local required_megabytes
    app_kilobytes="$(/usr/bin/du -sk "$APP" | awk '{print $1}')"
    [ -n "$app_kilobytes" ] \
        || die "storage" "AgentMicro could not determine the ChatGPT app size."

    # Keep 512 MiB untouched in addition to conservative whole-app copies for
    # extraction, staging, installation, and (when needed) a retained backup.
    required_kilobytes=$((app_kilobytes * multiplier + 524288))
    required_megabytes=$((required_kilobytes / 1024))

    local checked_devices=""
    local target
    for target in "$@"; do
        local existing
        local device
        local available
        existing="$(nearest_existing_path "$target")"
        device="$(/bin/df -Pk "$existing" | tail -1 | awk '{print $1}')"
        case " $checked_devices " in
            *" $device "*) continue ;;
        esac
        checked_devices="$checked_devices $device"
        available="$(available_kilobytes "$existing")"
        [ -n "$available" ] \
            || die "storage" "AgentMicro could not determine free space for $existing."
        if [ "$available" -lt "$required_kilobytes" ]; then
            die "storage" \
                "At least ${required_megabytes} MiB of free space is required before staging ChatGPT; $existing does not have enough."
        fi
    done
}

swap_in_staged_app() {
    local source_app="$1"
    local parent
    local name
    local incoming
    local previous
    local failed
    parent="$(dirname "$APP")"
    name="$(basename "$APP")"
    incoming="$parent/.${name}.agent-micro-incoming-$$"
    previous="$parent/.${name}.agent-micro-previous-$$"
    failed="$parent/.${name}.agent-micro-failed-$$"

    if ! /usr/bin/ditto --rsrc --extattr --acl "$source_app" "$incoming"; then
        rm -rf "$incoming" 2>/dev/null || true
        app_management_error
    fi
    if ! mv "$APP" "$previous"; then
        rm -rf "$incoming" 2>/dev/null || true
        app_management_error
    fi
    if ! mv "$incoming" "$APP"; then
        if mv "$previous" "$APP" 2>/dev/null; then
            die "installing" "The staged app could not be installed; the previous ChatGPT app was restored."
        fi
        die "installing" \
            "The staged app could not be installed and automatic rollback failed. The previous app is preserved at $previous."
    fi
    if ! /usr/bin/codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
        if ! mv "$APP" "$failed" 2>/dev/null; then
            die "installing" \
                "Installed-app verification failed. The previous app is preserved at $previous; the unverified replacement remains at $APP."
        fi
        if mv "$previous" "$APP" 2>/dev/null; then
            rm -rf "$failed" 2>/dev/null || true
            die "installing" "Installed-app verification failed; the previous ChatGPT app was restored."
        fi
        die "installing" \
            "Installed-app verification failed and automatic rollback failed. The previous app is preserved at $previous and the unverified replacement at $failed."
    fi
    if ! rm -rf "$previous"; then
        log "replacement verified; the previous app remains recoverable at $previous"
    fi
}

sign_staged_app_locally() {
    local staged_app="$1"
    local entitlements="$2"
    /usr/bin/codesign -d --entitlements :- "$APP" > "$entitlements" 2>/dev/null \
        || die "signing" "The current ChatGPT entitlements could not be read."
    for key in \
        com.apple.application-identifier \
        com.apple.developer.team-identifier \
        com.apple.developer.aps-environment \
        com.apple.security.application-groups \
        keychain-access-groups; do
        /usr/libexec/PlistBuddy -c "Delete :$key" "$entitlements" 2>/dev/null || true
    done
    /usr/bin/codesign --force --deep --sign - --entitlements "$entitlements" "$staged_app" \
        || die "signing" "The staged ChatGPT app could not be locally signed."
    /usr/bin/codesign --verify --deep --strict "$staged_app" \
        || die "signing" "The locally signed staged ChatGPT app failed verification."
    /usr/bin/xattr -dr com.apple.quarantine "$staged_app" 2>/dev/null || true
}

if [ "$MODE" = "restore" ]; then
    case "$BACKUP_KIND" in
        complete-signed)
            require_free_space 2 "$(dirname "$APP")" "${TMPDIR:-/tmp}"
            emit_event "progress" "validating-complete-backup" \
                "Validating the complete signed ChatGPT backup…" 0.8
            validate_complete_backup_full

            request_chatgpt_quit
            emit_event "progress" "restoring" "Restoring the complete OpenAI-signed ChatGPT app…" 0.9
            swap_in_staged_app "$BACKUP_DIR/ChatGPT.app"
            relaunch_chatgpt_if_requested
            emit_event "result" "complete" "ChatGPT was restored to its pristine OpenAI-signed build." 1
            exit 0
            ;;
        legacy-resources)
            require_free_space 3 \
                "$(dirname "$APP")" \
                "${TMPDIR:-/tmp}" \
                "$LEGACY_BACKUP_ROOT"
            emit_event "progress" "validating-backup" \
                "Fully validating the exact pristine resource backup…" 0.1
            validate_legacy_backup_full

            WORK="$(mktemp -d "${TMPDIR:-/tmp}/agent-micro-legacy-restore.XXXXXX")"
            STAGED_APP="$WORK/ChatGPT.app"
            ORIGINAL_ASAR_HASH="$(/usr/bin/shasum -a 256 "$ASAR_PATH" | awk '{print $1}')"
            ORIGINAL_INFO_HASH="$(/usr/bin/shasum -a 256 "$APP_INFO" | awk '{print $1}')"

            emit_event "progress" "staging" \
                "Building a complete local restore without changing the installed app…" 0.35
            /usr/bin/ditto --rsrc --extattr --acl "$APP" "$STAGED_APP" \
                || die "staging" "The installed ChatGPT app could not be copied into staging."
            STAGED_RESOURCES="$STAGED_APP/Contents/Resources"
            cp "$LEGACY_BACKUP_DIR/app.asar" "$STAGED_RESOURCES/app.asar" \
                || die "staging" "The pristine app.asar could not be staged."
            rm -rf "$STAGED_RESOURCES/app.asar.unpacked"
            cp -pR \
                "$LEGACY_BACKUP_DIR/app.asar.unpacked" \
                "$STAGED_RESOURCES/app.asar.unpacked" \
                || die "staging" "The pristine unpacked resources could not be staged."
            cp "$LEGACY_BACKUP_DIR/Info.plist" "$STAGED_APP/Contents/Info.plist" \
                || die "staging" "The pristine Info.plist could not be staged."

            emit_event "progress" "signing" \
                "Locally signing and verifying the complete staged restore…" 0.62
            sign_staged_app_locally "$STAGED_APP" "$WORK/restore-entitlements.plist"

            backup_identity_matches "$STAGED_APP/Contents/Info.plist" \
                || die "staging" "The staged restore identity changed unexpectedly."
            [ "$(inspect_asar_state "$STAGED_RESOURCES/app.asar")" = "compatible-pristine" ] \
                || die "staging" "The staged restore is not structurally pristine."
            asar_header_matches_plist \
                "$STAGED_RESOURCES/app.asar" \
                "$STAGED_APP/Contents/Info.plist" \
                || die "staging" "The staged restore failed its ASAR header-integrity check."
            [ "$(
                /usr/bin/shasum -a 256 "$STAGED_RESOURCES/app.asar" | awk '{print $1}'
            )" = "$(
                /usr/bin/shasum -a 256 "$LEGACY_BACKUP_DIR/app.asar" | awk '{print $1}'
            )" ] || die "staging" "The staged pristine app.asar differs from its validated backup."

            request_chatgpt_quit
            CURRENT_ASAR_HASH="$(/usr/bin/shasum -a 256 "$ASAR_PATH" | awk '{print $1}')"
            CURRENT_INFO_HASH="$(/usr/bin/shasum -a 256 "$APP_INFO" | awk '{print $1}')"
            [ "$CURRENT_ASAR_HASH" = "$ORIGINAL_ASAR_HASH" ] \
                && [ "$CURRENT_INFO_HASH" = "$ORIGINAL_INFO_HASH" ] \
                || die "installing" "ChatGPT changed during restore preparation. No files were replaced; try again."

            emit_event "progress" "restoring" \
                "Installing the validated, locally signed pristine-resource build…" 0.9
            swap_in_staged_app "$STAGED_APP"
            relaunch_chatgpt_if_requested
            emit_event "result" "complete" \
                "Pristine ChatGPT resources were restored. This app is locally signed, not OpenAI-signed; you can now patch it again with AgentMicro." 1
            exit 0
            ;;
        *)
            die "restore" "No exact validated backup exists for ChatGPT $VERSION ($BUILD)."
            ;;
    esac
fi

# A fully compatible installed patch is an idempotent success. In particular,
# never overwrite a missing pristine backup with an already-patched app.
if [ "$PATCH_STATE" = "compatible-patched" ]; then
    emit_event "result" "complete" "The AgentMicro patch is already installed and compatible." 1
    exit 0
fi

[ "$PATCH_STATE" = "compatible-pristine" ] \
    || die "preflight" "$STATUS_REASON"
[ -n "$SHIM_SRC" ] || die "runtime" "The bundled AgentMicro bridge shim is missing."
[ -n "$ASAR_MODE" ] \
    || die "runtime" "The bundled @electron/asar runtime is missing; no download was attempted."

emit_event "progress" "preflight" "ChatGPT $VERSION ($BUILD) matches the supported bundle structure." 0.04
if full_backup_is_valid_quick || legacy_backup_is_valid_quick; then
    require_free_space 4 \
        "$(dirname "$APP")" \
        "${TMPDIR:-/tmp}" \
        "$BACKUP_ROOT"
else
    require_free_space 5 \
        "$(dirname "$APP")" \
        "${TMPDIR:-/tmp}" \
        "$BACKUP_ROOT"
fi
ensure_pristine_backup

WORK="$(mktemp -d "${TMPDIR:-/tmp}/agent-micro-patch.XXXXXX")"
EXTRACTED="$WORK/extracted"
STAGED_APP="$WORK/ChatGPT.app"
ORIGINAL_ASAR_HASH="$(/usr/bin/shasum -a 256 "$ASAR_PATH" | awk '{print $1}')"
ORIGINAL_INFO_HASH="$(/usr/bin/shasum -a 256 "$APP_INFO" | awk '{print $1}')"

emit_event "progress" "extracting" "Extracting ChatGPT resources into a private staging directory…" 0.24
run_asar extract "$ASAR_PATH" "$EXTRACTED" \
    || die "extracting" "The bundled ASAR runtime could not extract ChatGPT."
/usr/bin/ditto --rsrc "$RESOURCES/app.asar.unpacked/" "$EXTRACTED/" \
    || die "extracting" "The native unpacked resources could not be staged."

emit_event "progress" "patching" "Installing the AgentMicro bridge shim…" 0.38
cp "$SHIM_SRC" "$EXTRACTED/codex-hid-shim.js"

NODEHID_DIR="$(find "$EXTRACTED/node_modules/@worklouder" -type d -name node-hid 2>/dev/null | head -1)"
[ -n "$NODEHID_DIR" ] || die "patching" "The expected Work Louder node-hid package was not found."
cat > "$NODEHID_DIR/nodehid.js" <<'NODEHID_EOF'
// node-hid replacement — installed by patch-chatgpt.sh (AgentMicro bridge).
'use strict';

const path = require('path');
let shimPath;
try {
  shimPath = path.join(process.resourcesPath, 'app.asar', 'codex-hid-shim.js');
  require('fs').accessSync(shimPath);
} catch (_) {
  shimPath = path.join(
    __dirname, '..', '..', '..', '..', '..', '..', '..', '..',
    'codex-hid-shim.js'
  );
}
module.exports = require(shimPath).nodehid;
NODEHID_EOF

# ChatGPT 26.814 renamed this chunk to service-<hash>.js. Try the historical
# name first so a mixed build cannot match the wrong file.
SERVICE_BUNDLE="$(find "$EXTRACTED/.vite/build" -maxdepth 1 -type f -name 'codex-micro-service-*.js' | head -1)"
if [ -z "$SERVICE_BUNDLE" ]; then
    SERVICE_BUNDLE="$(find "$EXTRACTED/.vite/build" -maxdepth 1 -type f -name 'service-*.js' | head -1)"
fi
[ -n "$SERVICE_BUNDLE" ] || die "patching" "The expected AgentMicro service bundle was not found."
SERVICE_BUNDLE="$SERVICE_BUNDLE" "$NODE_BIN" <<'PATCH_SERVICE_EOF'
const fs = require('fs');
const file = process.env.SERVICE_BUNDLE;
const oldValue = 'function p(){let e=m().find(o.existsSync);if(e==null)throw Error(`HID topology watcher addon not found`);return u(e)}';
const newValue = 'function p(){return u("../../codex-hid-shim.js").native}';
const source = fs.readFileSync(file, 'utf8');
const count = source.split(oldValue).length - 1;
if (count !== 1 || source.includes(newValue)) {
  console.error(`Expected one pristine HID topology loader; found ${count}.`);
  process.exit(1);
}
fs.writeFileSync(file, source.replace(oldValue, newValue));
PATCH_SERVICE_EOF

BUILD_DIR="$EXTRACTED/.vite/build" "$NODE_BIN" <<'PATCH_MAIN_EOF'
const fs = require('fs');
const path = require('path');
const files = fs.readdirSync(process.env.BUILD_DIR)
  .filter((name) => /^main-.*\.js$/.test(name))
  .map((name) => path.join(process.env.BUILD_DIR, name));
const oldValue = 'unsubscribePrimaryWindowChanges;constructor(e){this.options=e,this.unsubscribePrimaryWindowChanges=e.windowManager.subscribePrimaryWindowChanges(e=>{this.setOwnerWindow(e)})}';
const newValue = 'unsubscribePrimaryWindowChanges;constructor(e){this.options=e,this.unsubscribePrimaryWindowChanges=e.windowManager.subscribePrimaryWindowChanges(e=>{this.setOwnerWindow(e)}),this.getState().catch(()=>{})}';
// 26.814 added sessionLockMonitor and routed the owner window through the
// session lock. Both shapes are patched the same way: append the getState
// warm-up to the constructor body.
const oldLocked = 'unsubscribePrimaryWindowChanges;sessionLockMonitor=null;constructor(e){this.options=e,this.unsubscribePrimaryWindowChanges=e.windowManager.subscribePrimaryWindowChanges(e=>{this.setOwnerWindow(this.isSessionLocked()?null:e)})}';
const newLocked = 'unsubscribePrimaryWindowChanges;sessionLockMonitor=null;constructor(e){this.options=e,this.unsubscribePrimaryWindowChanges=e.windowManager.subscribePrimaryWindowChanges(e=>{this.setOwnerWindow(this.isSessionLocked()?null:e)}),this.getState().catch(()=>{})}';
const variants = [
  { from: oldValue, to: newValue },
  { from: oldLocked, to: newLocked },
];
const variant = variants.find((candidate) =>
  files.some((file) => fs.readFileSync(file, 'utf8').includes(candidate.from))
);
if (variant === undefined) {
  console.error('No pristine service manager constructor was found.');
  process.exit(1);
}
const matches = files.filter((file) => fs.readFileSync(file, 'utf8').includes(variant.from));
if (matches.length !== 1 || files.some((file) => fs.readFileSync(file, 'utf8').includes(variant.to))) {
  console.error(`Expected one pristine service manager; found ${matches.length}.`);
  process.exit(1);
}
const source = fs.readFileSync(matches[0], 'utf8');
fs.writeFileSync(matches[0], source.replace(variant.from, variant.to));
PATCH_MAIN_EOF

WEBVIEW_DIR="$EXTRACTED/webview/assets" "$NODE_BIN" <<'PATCH_RENDERER_EOF'
const fs = require('fs');
const path = require('path');
const files = fs.readdirSync(process.env.WEBVIEW_DIR)
  .filter((name) => name.endsWith('.js'))
  .map((name) => path.join(process.env.WEBVIEW_DIR, name))
  .filter((file) => {
    const value = fs.readFileSync(file, 'utf8');
    return value.includes('codex-micro-bridge-') && value.includes('3207467860');
  });
// The declaration list after the gate grew from `l;` to `l=Y(ay),...` in
// 26.814, so the match must stop at the comma.
const oldGate = () => /let s=n\|\|r\|\|i\|\|a\|\|o,c=[A-Za-z_$][\w$]*\(`3207467860`\),/g;
const newGate = 'let s=n||r||i||a||o,c=!0,';
const matches = files.filter((file) => (fs.readFileSync(file, 'utf8').match(oldGate()) || []).length === 1);
if (matches.length !== 1 || files.some((file) => fs.readFileSync(file, 'utf8').includes(newGate))) {
  console.error(`Expected one pristine renderer bridge gate; found ${matches.length}.`);
  process.exit(1);
}
const source = fs.readFileSync(matches[0], 'utf8');
fs.writeFileSync(matches[0], source.replace(oldGate(), newGate));
PATCH_RENDERER_EOF

emit_event "progress" "packing" "Repacking and validating ChatGPT resources…" 0.54
run_asar pack "$EXTRACTED" "$WORK/app.asar" \
    '--unpack-dir=node_modules/@(@worklouder|better-sqlite3|node-mac-permissions|node-pty|objc-js)' \
    || die "packing" "The patched ASAR could not be packed."

while IFS= read -r -d '' original_executable; do
    relative_path="${original_executable#"$RESOURCES/app.asar.unpacked/"}"
    repacked_executable="$WORK/app.asar.unpacked/$relative_path"
    [ -f "$repacked_executable" ] \
        || die "packing" "Repacking omitted executable helper: $relative_path"
    [ -x "$repacked_executable" ] \
        || die "packing" "Repacking stripped executable permission from: $relative_path"
done < <(find "$RESOURCES/app.asar.unpacked" -type f -perm -111 -print0)

[ "$(inspect_asar_state "$WORK/app.asar")" = "compatible-patched" ] \
    || die "packing" "The staged ASAR failed the post-patch compatibility check."

NEW_HASH="$(WORK_ASAR="$WORK/app.asar" "$NODE_BIN" <<'HASH_EOF'
const fs = require('fs');
const crypto = require('crypto');
const value = fs.readFileSync(process.env.WORK_ASAR);
const jsonLength = value.readUInt32LE(12);
process.stdout.write(
  crypto.createHash('sha256').update(value.subarray(16, 16 + jsonLength)).digest('hex')
);
HASH_EOF
)"
[ -n "$NEW_HASH" ] || die "packing" "The ASAR integrity hash could not be computed."

if [ "${PACK_ONLY:-0}" = "1" ]; then
    emit_event "result" "pack-only" "Patched ASAR created at $WORK/app.asar" 1
    WORK=""
    exit 0
fi

emit_event "progress" "staging" "Building and signing a complete staged ChatGPT app…" 0.67
/usr/bin/ditto --rsrc --extattr --acl "$APP" "$STAGED_APP" \
    || die "staging" "The complete ChatGPT app could not be staged."
STAGED_RESOURCES="$STAGED_APP/Contents/Resources"
cp "$WORK/app.asar" "$STAGED_RESOURCES/app.asar"
rm -rf "$STAGED_RESOURCES/app.asar.unpacked"
cp -pR "$WORK/app.asar.unpacked" "$STAGED_RESOURCES/app.asar.unpacked"

/usr/libexec/PlistBuddy -c "Set :ElectronAsarIntegrity:Resources/app.asar:hash $NEW_HASH" \
    "$STAGED_APP/Contents/Info.plist" \
    || die "staging" "ElectronAsarIntegrity could not be updated."
/usr/libexec/PlistBuddy -c "Delete :AgentMicroPatch" "$STAGED_APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :AgentMicroPatch dict" "$STAGED_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :AgentMicroPatch:Schema integer $PATCH_SCHEMA" "$STAGED_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :AgentMicroPatch:SourceVersion string $VERSION" "$STAGED_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :AgentMicroPatch:SourceBuild string $BUILD" "$STAGED_APP/Contents/Info.plist"

/usr/bin/codesign -d --entitlements :- "$APP" > "$WORK/entitlements.plist" 2>/dev/null \
    || die "signing" "The original ChatGPT entitlements could not be read."
for key in \
    com.apple.application-identifier \
    com.apple.developer.team-identifier \
    com.apple.developer.aps-environment \
    com.apple.security.application-groups \
    keychain-access-groups; do
    /usr/libexec/PlistBuddy -c "Delete :$key" "$WORK/entitlements.plist" 2>/dev/null || true
done
/usr/bin/codesign --force --deep --sign - --entitlements "$WORK/entitlements.plist" "$STAGED_APP" \
    || die "signing" "The staged ChatGPT app could not be ad-hoc signed."
/usr/bin/codesign --verify --deep --strict "$STAGED_APP" \
    || die "signing" "The staged ChatGPT signature failed verification."
/usr/bin/xattr -dr com.apple.quarantine "$STAGED_APP" 2>/dev/null || true

request_chatgpt_quit
CURRENT_ASAR_HASH="$(/usr/bin/shasum -a 256 "$ASAR_PATH" | awk '{print $1}')"
CURRENT_INFO_HASH="$(/usr/bin/shasum -a 256 "$APP_INFO" | awk '{print $1}')"
[ "$CURRENT_ASAR_HASH" = "$ORIGINAL_ASAR_HASH" ] \
    && [ "$CURRENT_INFO_HASH" = "$ORIGINAL_INFO_HASH" ] \
    || die "installing" "ChatGPT changed during patch preparation. No files were replaced; try again."

emit_event "progress" "installing" "Installing the validated AgentMicro patch…" 0.92
swap_in_staged_app "$STAGED_APP"
relaunch_chatgpt_if_requested
emit_event "result" "complete" "The AgentMicro patch was installed successfully." 1
