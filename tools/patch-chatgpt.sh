#!/usr/bin/env bash
# patch-chatgpt.sh — patch the ChatGPT desktop app so it detects the Codex
# Micro through the CodexMicroBridge socket helper instead of an OS-level HID
# device. Reversible, no AMFI/SIP changes, no virtual-HID entitlement needed.
#
# What it does (idempotent, safe to re-run after every ChatGPT update):
#   1. extracts Resources/app.asar (merging app.asar.unpacked back in)
#   2. injects codex-hid-shim.js, replaces the nested node-hid entry point
#      with a shim loader, redirects the native hid-topology-watcher loader,
#      starts the main-process Codex Micro service eagerly, and enables the
#      renderer bridge that interprets dial/key events
#   3. repacks app.asar, preserving the original unpacked-file set
#   4. updates ElectronAsarIntegrity in Info.plist (SHA256 of asar header)
#   5. re-signs the app ad-hoc, embedding the original entitlements
#   6. keeps a pristine backup at ~/.codexbridge/backup/<version>/
#
# Usage:
#   ./tools/patch-chatgpt.sh            # patch (or re-patch after an update)
#   ./tools/patch-chatgpt.sh --restore  # restore the pristine OpenAI-signed app
#
# Env overrides: CHATGPT_APP (default /Applications/ChatGPT.app)
#                PACK_ONLY=1  stop before installing/signing (for testing)

set -euo pipefail

APP="${CHATGPT_APP:-/Applications/ChatGPT.app}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SHIM_SRC="$REPO_ROOT/tools/CodexMicroBridge/codex-hid-shim.js"
RESOURCES="$APP/Contents/Resources"
INFO_PLIST="$APP/Contents/Info.plist"
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$INFO_PLIST" 2>/dev/null || echo unknown)"
BACKUP_DIR="$HOME/.codexbridge/backup/$VERSION"
WORK=""

log() { printf '\033[1m[patch]\033[0m %s\n' "$*"; }
die() { printf '\033[1m[patch] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT

chatgpt_is_running() {
    [ "$(osascript -e 'application "ChatGPT" is running' 2>/dev/null || printf false)" = "true" ]
}

quit_chatgpt() {
    log "quitting ChatGPT if running…"
    osascript -e 'tell application "ChatGPT" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 1 40); do
        chatgpt_is_running || return 0
        sleep 0.25
    done
    die "ChatGPT did not finish quitting; no app files were changed"
}

app_management_denied() {
    open 'x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AppBundles' \
        >/dev/null 2>&1 || true
    die "macOS blocked changes to ChatGPT.app. In Privacy & Security > App Management, enable Terminal, then run this command again"
}

app_write() {
    "$@" || app_management_denied
}

[ -d "$APP" ] || die "ChatGPT.app not found at $APP (set CHATGPT_APP)"
[ -f "$SHIM_SRC" ] || die "shim not found at $SHIM_SRC"
command -v node >/dev/null || die "node is required"

# ---------------------------------------------------------------- restore ---
if [ "${1:-}" = "--restore" ]; then
    [ -d "$BACKUP_DIR" ] || die "no backup found at $BACKUP_DIR"
    quit_chatgpt
    log "restoring pristine files from $BACKUP_DIR"
    app_write cp "$BACKUP_DIR/app.asar" "$RESOURCES/app.asar"
    app_write rm -rf "$RESOURCES/app.asar.unpacked"
    app_write cp -pR "$BACKUP_DIR/app.asar.unpacked" "$RESOURCES/app.asar.unpacked"
    app_write cp "$BACKUP_DIR/Info.plist" "$INFO_PLIST"
    log "restored. The original OpenAI signature is intact again — no re-sign needed."
    exit 0
fi

# ------------------------------------------------------------------ setup ---
WORK="$(mktemp -d /tmp/codex-patch.XXXXXX)"
EXTRACTED="$WORK/extracted"
log "working in $WORK"

quit_chatgpt

# --------------------------------------------------------------- backup -----
if [ ! -d "$BACKUP_DIR" ]; then
    log "backing up pristine app.asar + Info.plist to $BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
    cp "$RESOURCES/app.asar" "$BACKUP_DIR/app.asar"
    cp -pR "$RESOURCES/app.asar.unpacked" "$BACKUP_DIR/app.asar.unpacked"
    cp "$INFO_PLIST" "$BACKUP_DIR/Info.plist"
else
    log "backup already exists at $BACKUP_DIR (kept)"
fi

# --------------------------------------------------------------- extract ----
log "extracting app.asar…"
npx --yes @electron/asar extract "$RESOURCES/app.asar" "$EXTRACTED"
# `asar extract` creates placeholder copies of unpacked files with mode 0644.
# Overlay the real files with `-p` so executable helpers retain their modes.
# Losing this bit from node-pty/build/Release/spawn-helper prevents ChatGPT
# from opening terminals even though the helper's bytes/signature are intact.
cp -pR "$RESOURCES/app.asar.unpacked/" "$EXTRACTED/"

# ----------------------------------------------------------------- patch ----
log "injecting codex-hid-shim.js"
cp "$SHIM_SRC" "$EXTRACTED/codex-hid-shim.js"

NODEHID_DIR="$(find "$EXTRACTED/node_modules/@worklouder" -type d -name node-hid | head -1)"
[ -n "$NODEHID_DIR" ] || die "nested node-hid package not found under @worklouder"
log "replacing node-hid entry: $NODEHID_DIR/nodehid.js"
cat > "$NODEHID_DIR/nodehid.js" <<'NODEHID_EOF'
// node-hid replacement — installed by patch-chatgpt.sh (Codex Micro bridge).
// Loads the injected bridge shim instead of the real HID binding. The shim
// mirrors the node-hid API surface the app uses (devices, HIDAsync, HID).
'use strict';

const path = require('path');

let shimPath;
try {
  // Inside the packaged app this file lives in app.asar.unpacked while the
  // shim is packed at the app.asar root.
  shimPath = path.join(process.resourcesPath, 'app.asar', 'codex-hid-shim.js');
  require('fs').accessSync(shimPath);
} catch (_) {
  // Fallback for a plain-nodejs checkout of the extracted asar tree.
  shimPath = path.join(
    __dirname, '..', '..', '..', '..', '..', '..', '..', '..',
    'codex-hid-shim.js'
  );
}

module.exports = require(shimPath).nodehid;
NODEHID_EOF

SERVICE_BUNDLE="$(ls "$EXTRACTED"/.vite/build/codex-micro-service-*.js 2>/dev/null | head -1)"
[ -n "$SERVICE_BUNDLE" ] || die "codex-micro-service bundle not found in .vite/build"
log "redirecting native hid-topology-watcher in $(basename "$SERVICE_BUNDLE")"
SERVICE_BUNDLE="$SERVICE_BUNDLE" node <<'PATCH_EOF'
const fs = require('fs');
const f = process.env.SERVICE_BUNDLE;
let s = fs.readFileSync(f, 'utf8');
const oldLoader = 'function p(){let e=m().find(o.existsSync);if(e==null)throw Error(`HID topology watcher addon not found`);return u(e)}';
const newLoader = 'function p(){return u("../../codex-hid-shim.js").native}';
if (s.includes(newLoader)) {
  console.log('[patch] watcher loader already redirected (already patched) — OK');
  process.exit(0);
}
const count = s.split(oldLoader).length - 1;
if (count !== 1) {
  console.error(`[patch] ERROR: expected exactly 1 native watcher loader, found ${count}.`);
  console.error('[patch] This ChatGPT build changed its bundle — the patch needs updating.');
  process.exit(1);
}
fs.writeFileSync(f, s.replace(oldLoader, newLoader));
console.log('[patch] watcher loader redirected OK');
PATCH_EOF

# The stock service manager is lazy: it does not import/start the HID service
# until the renderer asks for state. If the remote Codex Micro feature flag is
# off, that request never happens, so the helper socket can be healthy while
# ChatGPT is not connected to it. Start the existing service as soon as its
# manager is constructed. The catch preserves normal app startup if a future
# build has a transient device error.
log "making the Codex Micro main-process service start eagerly"
BUILD_DIR="$EXTRACTED/.vite/build" node <<'PATCH_MAIN_EOF'
const fs = require('fs');
const path = require('path');
const dir = process.env.BUILD_DIR;
const candidates = fs.readdirSync(dir)
  .filter((name) => /^main-.*\.js$/.test(name))
  .map((name) => path.join(dir, name));
const oldCtor = 'unsubscribePrimaryWindowChanges;constructor(e){this.options=e,this.unsubscribePrimaryWindowChanges=e.windowManager.subscribePrimaryWindowChanges(e=>{this.setOwnerWindow(e)})}';
const newCtor = 'unsubscribePrimaryWindowChanges;constructor(e){this.options=e,this.unsubscribePrimaryWindowChanges=e.windowManager.subscribePrimaryWindowChanges(e=>{this.setOwnerWindow(e)}),this.getState().catch(()=>{})}';
const oldMatches = candidates.filter((file) => fs.readFileSync(file, 'utf8').includes(oldCtor));
const newMatches = candidates.filter((file) => fs.readFileSync(file, 'utf8').includes(newCtor));

if (newMatches.length === 1 && oldMatches.length === 0) {
  console.log('[patch] main-process service is already eager — OK');
  process.exit(0);
}
if (oldMatches.length !== 1 || newMatches.length !== 0) {
  console.error(`[patch] ERROR: expected exactly 1 lazy service manager, found old=${oldMatches.length}, new=${newMatches.length}.`);
  console.error('[patch] This ChatGPT build changed its main bundle — the patch needs updating.');
  process.exit(1);
}
const file = oldMatches[0];
const source = fs.readFileSync(file, 'utf8');
fs.writeFileSync(file, source.replace(oldCtor, newCtor));
console.log(`[patch] eager service startup installed in ${path.basename(file)}`);
PATCH_MAIN_EOF

# The React bridge owns the HID-event listener and converts raw Codex Micro
# reports into ChatGPT actions. It is normally mounted only behind OpenAI's
# remote feature flag 3207467860. Force that one app-shell gate on so an
# emulated device remains functional even when the account is outside the
# feature rollout. Other uses of the flag are deliberately left untouched.
log "enabling the renderer dial/key event bridge"
WEBVIEW_DIR="$EXTRACTED/webview/assets" node <<'PATCH_RENDERER_EOF'
const fs = require('fs');
const path = require('path');
const dir = process.env.WEBVIEW_DIR;
const candidates = fs.readdirSync(dir)
  .filter((name) => name.endsWith('.js'))
  .map((name) => path.join(dir, name))
  .filter((file) => {
    const source = fs.readFileSync(file, 'utf8');
    return source.includes('codex-micro-bridge-') && source.includes('3207467860');
  });
// Match the app-shell gate structurally instead of by the exact minified
// helper name: each ChatGPT build re-minifies the feature-flag lookup wrapper
// (es → qo → …), but the surrounding gate `let s=n||r||i||a||o,c=<fn>(`3207467860`),l;`
// is stable. Capture whatever the wrapper is currently called and force it on.
const newGate = 'let s=n||r||i||a||o,c=!0,l;';
// A fresh (non-global) regex per use, so no shared lastIndex state can leak
// between the filter below and the match/replace further down.
const gateRe = () => /let s=n\|\|r\|\|i\|\|a\|\|o,c=[A-Za-z_$][\w$]*\(`3207467860`\),l;/g;
const oldMatchFiles = candidates.filter((file) => (fs.readFileSync(file, 'utf8').match(gateRe()) || []).length > 0);
const newMatches = candidates.filter((file) => fs.readFileSync(file, 'utf8').includes(newGate));

if (newMatches.length === 1 && oldMatchFiles.length === 0) {
  console.log('[patch] renderer event bridge is already enabled — OK');
  process.exit(0);
}
if (oldMatchFiles.length !== 1 || newMatches.length !== 0) {
  console.error(`[patch] ERROR: expected exactly 1 renderer bridge gate, found old=${oldMatchFiles.length}, new=${newMatches.length}.`);
  console.error('[patch] This ChatGPT build changed its renderer bundle — the patch needs updating.');
  process.exit(1);
}
const file = oldMatchFiles[0];
const source = fs.readFileSync(file, 'utf8');
const gateMatches = source.match(gateRe()) || [];
if (gateMatches.length !== 1) {
  console.error(`[patch] ERROR: expected exactly 1 gate occurrence in the bundle, found ${gateMatches.length}.`);
  process.exit(1);
}
const wrapper = gateMatches[0].match(/c=([A-Za-z_$][\w$]*)\(/)[1];
fs.writeFileSync(file, source.replace(gateRe(), newGate));
console.log(`[patch] renderer event bridge enabled in ${path.basename(file)} (matched wrapper ${wrapper})`);
PATCH_RENDERER_EOF

# ------------------------------------------------------------------ pack ----
# Keep every natively-loaded package unpacked (the original asar unpacks
# these top-level packages: .node binaries + helper executables
# cannot be dlopen'd from inside an archive). Extglob with pipes: the asar
# CLI mis-splits comma-brace lists and only honors the last alternative.
log "packing patched app.asar…"
npx --yes @electron/asar pack "$EXTRACTED" "$WORK/app.asar" \
    "--unpack-dir=node_modules/@(@worklouder|better-sqlite3|node-mac-permissions|node-pty|objc-js)"

# Refuse to install if repacking changed an executable helper into a regular
# data file. This covers node-pty's terminal spawn-helper as well as future
# native helpers added by ChatGPT.
log "verifying unpacked executable modes…"
while IFS= read -r -d '' ORIGINAL_EXECUTABLE; do
    RELATIVE_PATH="${ORIGINAL_EXECUTABLE#"$RESOURCES/app.asar.unpacked/"}"
    REPACKED_EXECUTABLE="$WORK/app.asar.unpacked/$RELATIVE_PATH"
    [ -f "$REPACKED_EXECUTABLE" ] \
        || die "repack omitted executable helper: $RELATIVE_PATH"
    [ -x "$REPACKED_EXECUTABLE" ] \
        || die "repack stripped executable mode from: $RELATIVE_PATH"
done < <(find "$RESOURCES/app.asar.unpacked" -type f -perm -111 -print0)
log "unpacked executable modes preserved"

# ------------------------------------------------------- asar integrity -----
log "computing new ElectronAsarIntegrity hash…"
NEW_HASH="$(WORK_ASAR="$WORK/app.asar" node <<'HASH_EOF'
const fs = require('fs'), crypto = require('crypto');
const buf = fs.readFileSync(process.env.WORK_ASAR);
const jsonLen = buf.readUInt32LE(12); // asar header: 4x u32 pickle words, JSON at offset 16
process.stdout.write(crypto.createHash('sha256').update(buf.subarray(16, 16 + jsonLen)).digest('hex'));
HASH_EOF
)"
[ -n "$NEW_HASH" ] || die "integrity hash computation failed"

if [ "${PACK_ONLY:-0}" = "1" ]; then
    log "PACK_ONLY=1 — stopping before install. Artifacts:"
    log "  asar:     $WORK/app.asar"
    log "  unpacked: $WORK/app.asar.unpacked"
    log "  tree:     $EXTRACTED"
    log "  hash:     $NEW_HASH"
    WORK="" # keep workdir for inspection
    exit 0
fi

# --------------------------------------------------------------- install ----
log "installing into $APP"
app_write cp "$WORK/app.asar" "$RESOURCES/app.asar"
app_write rm -rf "$RESOURCES/app.asar.unpacked"
app_write cp -pR "$WORK/app.asar.unpacked" "$RESOURCES/app.asar.unpacked"

app_write /usr/libexec/PlistBuddy -c "Set :ElectronAsarIntegrity:Resources/app.asar:hash $NEW_HASH" "$INFO_PLIST" \
    || die "failed to update ElectronAsarIntegrity in Info.plist"

# ------------------------------------------------------------------ sign ----
log "extracting current entitlements…"
codesign -d --entitlements :- "$APP" 2>/dev/null > "$WORK/entitlements.plist" \
    || die "could not read entitlements"

# Restricted entitlements (team-scoped) require OpenAI's certificate and
# provisioning profile; an ad-hoc signature holding them is rejected by amfid
# with an instant SIGKILL at launch. Strip them, keep the unrestricted rest.
# Side effect: the app can no longer read keychain items sealed to the
# OpenAI team signature — ChatGPT will ask you to log in again (once).
for KEY in \
    com.apple.application-identifier \
    com.apple.developer.team-identifier \
    com.apple.developer.aps-environment \
    com.apple.security.application-groups \
    keychain-access-groups; do
    /usr/libexec/PlistBuddy -c "Delete :$KEY" "$WORK/entitlements.plist" 2>/dev/null || true
done

log "re-signing ad-hoc (hardened runtime dropped; unrestricted entitlements kept)…"
codesign --force --deep --sign - --entitlements "$WORK/entitlements.plist" "$APP" \
    || die "codesign failed"
codesign --verify --deep --strict "$APP" || die "signature verification failed"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

log "done. Codex Micro bridge patch installed."
log "next: ./tools/CodexMicroBridge/codexbridge --emulate   (or without --emulate for the iPhone)"
log "then open ChatGPT. Re-run this script after every ChatGPT update."
