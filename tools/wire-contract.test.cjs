#!/usr/bin/env node
'use strict';

// Locks the identifiers that cross a process boundary.
//
// These strings are contracts, not names. ChatGPT recognises the virtual
// device by its HID product string; shims already written into patched
// ChatGPT copies open a socket at a fixed path; the desktop app persists its
// layout under fixed settings keys. A product rename that sweeps them breaks
// every existing install, and the failure is silent: the bridge connects, the
// phone links, and the end-to-end check simply never completes.
//
// If a value here has to change, it needs a migration, not an edit.

const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const repositoryRoot = path.join(__dirname, '..');
const read = (relativePath) =>
  fs.readFileSync(path.join(repositoryRoot, relativePath), 'utf8');

const shim = read('tools/AgentMicroBridge/codex-hid-shim.js');
const bridge = read('tools/AgentMicroBridge/main.swift');
const engine = read('macos/AgentMicro/Sources/AgentMicroBridgeEngine.swift');

// The product string ChatGPT matches when it enumerates HID devices.
assert.match(
  shim,
  /product: 'Codex Micro',/,
  'the virtual HID product string must stay "Codex Micro"'
);

// The device path the shim reports for that virtual device.
assert.match(
  shim,
  /const FAKE_PATH = 'codex-bridge:\/\/virtual\/codex-micro';/,
  'the virtual device path must stay codex-bridge://virtual/codex-micro'
);

// Both ends of the local socket must name the same directory.
assert.match(
  shim,
  /path\.join\(os\.tmpdir\(\), 'CodexMicro', 'codexbridge\.sock'\)/,
  'the shim socket directory must stay CodexMicro'
);
assert.match(
  bridge,
  /appendingPathComponent\("CodexMicro"\)/,
  'the bridge socket directory must stay CodexMicro'
);
assert.match(
  engine,
  /"\/tmp\/codexbridge\.sock"/,
  'the legacy socket alias must stay /tmp/codexbridge.sock'
);

// Message types exchanged with the phone and with ChatGPT.
for (const type of ['codex-micro-state', 'codex-micro-layout']) {
  assert.ok(
    bridge.includes(`"${type}"`),
    `the bridge must still send and receive "${type}"`
  );
}

// Settings keys ChatGPT persists on the user's behalf.
assert.ok(
  bridge.includes('"codex-micro-lighting-brightness"'),
  'the lighting brightness settings key must not be renamed'
);
assert.ok(
  bridge.includes('"desktop.codex-micro-layout"'),
  'the layout settings table must not be renamed'
);

// The bundle identifiers installed copies already own.
for (const identifier of [
  'io.github.thislev.codexmicro',
  'io.github.thislev.codexmicroremote',
]) {
  const found = ['macos/AgentMicro/project.yml', 'ios/AgentMicroRemote/project.yml']
    .map(read)
    .some((contents) => contents.includes(identifier));
  assert.ok(found, `${identifier} must not be renamed`);
}

process.stdout.write('wire-contract tests: PASS (11 cross-process identifiers)\n');
