#!/usr/bin/env node
'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const childProcess = require('child_process');

const runtimeDirectory = __dirname;
const repositoryRoot = path.resolve(runtimeDirectory, '..', '..', '..');
const inspectorPath = path.join(runtimeDirectory, 'asar-inspect.cjs');
const patchScriptPath = path.join(repositoryRoot, 'tools', 'patch-chatgpt.sh');
const currentShimPath = path.join(
  repositoryRoot,
  'tools',
  'AgentMicroBridge',
  'codex-hid-shim.js'
);

const oldWatcher =
  'function p(){let e=m().find(o.existsSync);if(e==null)throw Error(`HID topology watcher addon not found`);return u(e)}';
const newWatcher =
  'function p(){return u("../../codex-hid-shim.js").native}';
const oldConstructor =
  'unsubscribePrimaryWindowChanges;constructor(e){this.options=e,this.unsubscribePrimaryWindowChanges=e.windowManager.subscribePrimaryWindowChanges(e=>{this.setOwnerWindow(e)})}';
const newConstructor =
  'unsubscribePrimaryWindowChanges;constructor(e){this.options=e,this.unsubscribePrimaryWindowChanges=e.windowManager.subscribePrimaryWindowChanges(e=>{this.setOwnerWindow(e)}),this.getState().catch(()=>{})}';
const oldRendererGate =
  'codex-micro-bridge-test;let s=n||r||i||a||o,c=x(`3207467860`),l;';
const newRendererGate =
  'codex-micro-bridge-test;3207467860;let s=n||r||i||a||o,c=!0,l;';

function fixtureFiles(kind) {
  const patched = kind !== 'pristine';
  const files = {
    'node_modules/@worklouder/node-hid/nodehid.js': patched
      ? '// node-hid replacement — installed by patch-chatgpt.sh'
      : "module.exports=require('./build/Release/HID.node'); class HIDAsync {}",
    '.vite/build/codex-micro-service-fixture.js': patched
      ? newWatcher
      : oldWatcher,
    '.vite/build/main-fixture.js': patched
      ? newConstructor
      : oldConstructor,
    'webview/assets/fixture.js': patched
      ? newRendererGate
      : oldRendererGate,
  };
  if (!patched) return files;

  if (kind === 'current') {
    files['codex-hid-shim.js'] = fs.readFileSync(currentShimPath);
  } else if (kind === 'legacy-name-current-schema') {
    files['codex-hid-shim.js'] =
      "'use strict'; const CODEX_MICRO_SHIM_SCHEMA = 2;";
  } else if (kind === 'legacy-unmarked') {
    files['codex-hid-shim.js'] = "'use strict'; module.exports = {};";
  } else if (kind === 'schema-1') {
    files['codex-hid-shim.js'] =
      "'use strict'; const AGENT_MICRO_SHIM_SCHEMA = 1;";
  } else if (kind === 'schema-3') {
    files['codex-hid-shim.js'] =
      "'use strict'; const AGENT_MICRO_SHIM_SCHEMA = 3;";
  } else {
    throw new Error(`Unknown fixture kind: ${kind}`);
  }
  return files;
}

function writeFixtureAsar(destination, kind) {
  const root = { files: {} };
  const chunks = [];
  let offset = 0;

  for (const [relativePath, source] of Object.entries(fixtureFiles(kind))) {
    const value = Buffer.isBuffer(source) ? source : Buffer.from(source);
    const components = relativePath.split('/');
    let directory = root;
    for (const component of components.slice(0, -1)) {
      directory.files[component] ??= { files: {} };
      directory = directory.files[component];
    }
    directory.files[components.at(-1)] = {
      size: value.length,
      offset: String(offset),
    };
    chunks.push(value);
    offset += value.length;
  }

  const headerJSON = Buffer.from(JSON.stringify(root));
  const paddedHeaderLength = Math.ceil(headerJSON.length / 4) * 4;
  const prefix = Buffer.alloc(16);
  prefix.writeUInt32LE(8 + paddedHeaderLength, 4);
  prefix.writeUInt32LE(headerJSON.length, 12);
  const headerPadding = Buffer.alloc(paddedHeaderLength - headerJSON.length);
  fs.writeFileSync(
    destination,
    Buffer.concat([prefix, headerJSON, headerPadding, ...chunks])
  );
}

function inspectFixture(directory, kind) {
  const asarPath = path.join(directory, `${kind}.asar`);
  writeFixtureAsar(asarPath, kind);
  const result = childProcess.spawnSync(
    process.execPath,
    [inspectorPath, asarPath],
    { encoding: 'utf8' }
  );
  assert(result.stdout, result.stderr);
  return {
    exitCode: result.status,
    value: JSON.parse(result.stdout),
    asarPath,
  };
}

function writeInfoPlist(destination) {
  fs.writeFileSync(
    destination,
    `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.openai.chat</string>
  <key>CFBundleExecutable</key><string>ChatGPT</string>
  <key>CFBundleShortVersionString</key><string>fixture</string>
  <key>CFBundleVersion</key><string>1</string>
</dict>
</plist>
`
  );
}

function patchStatusFixture(directory, kind, environmentOverrides = {}, label = kind) {
  const fixtureRoot = path.join(directory, `status-${label}`);
  const appPath = path.join(fixtureRoot, 'ChatGPT.app');
  const resources = path.join(appPath, 'Contents', 'Resources');
  fs.mkdirSync(path.join(resources, 'app.asar.unpacked'), { recursive: true });
  fs.mkdirSync(path.join(appPath, 'Contents', 'MacOS'), { recursive: true });
  writeInfoPlist(path.join(appPath, 'Contents', 'Info.plist'));
  writeFixtureAsar(path.join(resources, 'app.asar'), kind);

  const result = childProcess.spawnSync(
    '/bin/bash',
    [patchScriptPath, '--status', '--json'],
    {
      encoding: 'utf8',
      env: {
        ...process.env,
        CHATGPT_APP: appPath,
        AGENT_MICRO_NODE: process.execPath,
        AGENT_MICRO_INSPECTOR: inspectorPath,
        AGENT_MICRO_SHIM: currentShimPath,
        AGENT_MICRO_BACKUP_ROOT: path.join(fixtureRoot, 'Backups'),
        AGENT_MICRO_LEGACY_BACKUP_ROOT: path.join(fixtureRoot, 'Legacy'),
        AGENT_MICRO_STATE_ROOT: path.join(fixtureRoot, 'State'),
        AGENT_MICRO_DEVELOPER_FALLBACK: '0',
        ...environmentOverrides,
      },
    }
  );
  assert.equal(result.status, 0, result.stderr);
  return JSON.parse(result.stdout.trim().split(/\r?\n/).at(-1));
}

const temporaryDirectory = fs.mkdtempSync(
  path.join(os.tmpdir(), 'agent-micro-inspector-test-')
);
try {
  const pristine = inspectFixture(temporaryDirectory, 'pristine');
  assert.equal(pristine.exitCode, 0);
  assert.equal(pristine.value.state, 'compatible-pristine');
  assert.equal(pristine.value.patched, false);

  const current = inspectFixture(temporaryDirectory, 'current');
  assert.equal(current.exitCode, 0);
  assert.equal(current.value.state, 'compatible-patched');
  assert.equal(current.value.details.shimSchema, 2);
  assert.equal(current.value.details.expectedShimSchema, 2);

  const legacyNameCurrentSchema = inspectFixture(
    temporaryDirectory,
    'legacy-name-current-schema'
  );
  assert.equal(legacyNameCurrentSchema.exitCode, 0);
  assert.equal(legacyNameCurrentSchema.value.state, 'compatible-patched');
  assert.equal(legacyNameCurrentSchema.value.details.shimSchema, 2);

  for (const kind of ['legacy-unmarked', 'schema-1']) {
    const oldPatch = inspectFixture(temporaryDirectory, kind);
    assert.equal(oldPatch.exitCode, 2);
    assert.equal(oldPatch.value.state, 'integration-update-required');
    assert.equal(oldPatch.value.patched, true);
    assert.equal(oldPatch.value.compatible, false);
    assert.match(oldPatch.value.reason, /Restore ChatGPT, then Patch ChatGPT/);
  }

  const newer = inspectFixture(temporaryDirectory, 'schema-3');
  assert.equal(newer.exitCode, 2);
  assert.equal(newer.value.state, 'incompatible');
  assert.match(newer.value.reason, /newer AgentMicro version/);

  const currentStatus = patchStatusFixture(temporaryDirectory, 'current');
  assert.equal(currentStatus.patchState, 'compatible-patched');
  assert.equal(currentStatus.compatible, true);

  // A pristine, unpatched install has no backup, so Restore is always
  // unavailable. When the patch tooling is also incomplete Patch is disabled
  // too, which used to leave both buttons grey behind a reason that claimed
  // the build was supported and offered no way forward. The state stays
  // accurate; the reason must name the real blocker.
  const brokenRuntimeStatus = patchStatusFixture(
    temporaryDirectory,
    'pristine',
    { AGENT_MICRO_SHIM: path.join(temporaryDirectory, 'missing-shim.js') },
    'pristine-no-shim'
  );
  assert.equal(brokenRuntimeStatus.patchState, 'compatible-pristine');
  assert.equal(brokenRuntimeStatus.canPatch, false);
  assert.equal(brokenRuntimeStatus.canRestore, false);
  assert.match(brokenRuntimeStatus.reason, /Reinstall AgentMicro/);

  const oldStatus = patchStatusFixture(temporaryDirectory, 'schema-1');
  assert.equal(oldStatus.patchState, 'integration-update-required');
  assert.equal(oldStatus.patched, true);
  assert.equal(oldStatus.canPatch, false);
  assert.equal(oldStatus.canRestore, false);
  assert.match(oldStatus.reason, /Reinstall ChatGPT, then choose Patch ChatGPT/);

  process.stdout.write(
    'asar-inspect/status fixture tests: PASS (6 inspector, 3 status cases)\n'
  );
} finally {
  fs.rmSync(temporaryDirectory, { recursive: true, force: true });
}
