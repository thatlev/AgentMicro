#!/usr/bin/env node
'use strict';

// Lightweight, read-only ASAR inspector used by the menu-bar app's patch
// preflight. It intentionally does not depend on @electron/asar, so status
// checks still work when the repacking runtime has not been installed.

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const childProcess = require('child_process');

const cliArguments = process.argv.slice(2);
const archivePath = cliArguments[0];
const fieldIndex = cliArguments.indexOf('--field');
const requestedField = fieldIndex >= 0 ? cliArguments[fieldIndex + 1] : null;
const verifyIntegrity = cliArguments.includes('--verify-integrity');
const openAITeamIdentifier = '2DC432GLL2';

function fail(message) {
  const result = {
    state: 'incompatible',
    patched: false,
    compatible: false,
    reason: message,
    details: {},
  };
  output(result, 2);
}

function output(result, exitCode = 0) {
  if (requestedField) {
    const value = result[requestedField];
    process.stdout.write(value == null ? '' : String(value));
  } else {
    process.stdout.write(`${JSON.stringify(result)}\n`);
  }
  process.exit(exitCode);
}

if (!archivePath) {
  fail('No app.asar path was supplied.');
}

let archive;
let header;
let dataOffset;

try {
  archive = fs.openSync(archivePath, 'r');
  const prefix = Buffer.alloc(16);
  if (fs.readSync(archive, prefix, 0, prefix.length, 0) !== prefix.length) {
    fail('The app.asar header is truncated.');
  }

  const headerBlockSize = prefix.readUInt32LE(4);
  const jsonSize = prefix.readUInt32LE(12);
  if (headerBlockSize < 8 || jsonSize === 0 || jsonSize > headerBlockSize) {
    fail('The app.asar header has an unsupported layout.');
  }

  const json = Buffer.alloc(jsonSize);
  if (fs.readSync(archive, json, 0, json.length, 16) !== json.length) {
    fail('The app.asar file ended inside its header.');
  }
  header = JSON.parse(json.toString('utf8'));
  dataOffset = 8 + headerBlockSize;
} catch (error) {
  fail(`Unable to read app.asar: ${error.message}`);
}

function walk(node, prefix = '', result = []) {
  if (!node || !node.files) return result;
  for (const [name, child] of Object.entries(node.files)) {
    const relativePath = prefix ? `${prefix}/${name}` : name;
    if (child.files) {
      walk(child, relativePath, result);
    } else {
      result.push(relativePath);
    }
  }
  return result;
}

function entryFor(relativePath) {
  let node = header;
  for (const component of relativePath.split('/')) {
    node = node && node.files && node.files[component];
    if (!node) return null;
  }
  return node;
}

function readEntry(relativePath) {
  const entry = entryFor(relativePath);
  if (!entry || entry.files) {
    throw new Error(`ASAR entry is missing: ${relativePath}`);
  }
  if (entry.unpacked) {
    return fs.readFileSync(`${archivePath}.unpacked/${relativePath}`);
  }
  const size = Number(entry.size);
  const offset = Number(entry.offset);
  if (!Number.isSafeInteger(size) || !Number.isSafeInteger(offset)) {
    throw new Error(`ASAR entry has an invalid offset: ${relativePath}`);
  }
  const value = Buffer.alloc(size);
  if (fs.readSync(archive, value, 0, size, dataOffset + offset) !== size) {
    throw new Error(`ASAR entry is truncated: ${relativePath}`);
  }
  return value;
}

function countOccurrences(source, needle) {
  if (!needle) return 0;
  let count = 0;
  let cursor = 0;
  while ((cursor = source.indexOf(needle, cursor)) !== -1) {
    count += 1;
    cursor += needle.length;
  }
  return count;
}

function classifySingle(oldCount, newCount, label) {
  if (oldCount === 1 && newCount === 0) return 'pristine';
  if (oldCount === 0 && newCount === 1) return 'patched';
  return `invalid:${label}:old=${oldCount}:new=${newCount}`;
}

const files = walk(header);
const fileSet = new Set(files);
const nodeHIDFiles = files.filter((value) =>
  /^node_modules\/@worklouder\/.+\/node_modules\/node-hid\/nodehid\.js$/.test(value)
  || /^node_modules\/@worklouder\/node-hid\/nodehid\.js$/.test(value)
);
const serviceFiles = files.filter((value) =>
  /^\.vite\/build\/codex-micro-service-[^/]+\.js$/.test(value)
);
const mainFiles = files.filter((value) =>
  /^\.vite\/build\/main-[^/]+\.js$/.test(value)
);
const webviewFiles = files.filter((value) =>
  /^webview\/assets\/[^/]+\.js$/.test(value)
);

const oldWatcher =
  'function p(){let e=m().find(o.existsSync);if(e==null)throw Error(`HID topology watcher addon not found`);return u(e)}';
const newWatcher =
  'function p(){return u("../../codex-hid-shim.js").native}';
const oldConstructor =
  'unsubscribePrimaryWindowChanges;constructor(e){this.options=e,this.unsubscribePrimaryWindowChanges=e.windowManager.subscribePrimaryWindowChanges(e=>{this.setOwnerWindow(e)})}';
const newConstructor =
  'unsubscribePrimaryWindowChanges;constructor(e){this.options=e,this.unsubscribePrimaryWindowChanges=e.windowManager.subscribePrimaryWindowChanges(e=>{this.setOwnerWindow(e)}),this.getState().catch(()=>{})}';
const newRendererGate = 'let s=n||r||i||a||o,c=!0,l;';
const oldRendererGate =
  /let s=n\|\|r\|\|i\|\|a\|\|o,c=[A-Za-z_$][\w$]*\(`3207467860`\),l;/g;

try {
  if (nodeHIDFiles.length !== 1 || serviceFiles.length !== 1 || mainFiles.length === 0) {
    fail(
      `Unsupported ChatGPT bundle structure (node-hid=${nodeHIDFiles.length}, service=${serviceFiles.length}, main=${mainFiles.length}).`
    );
  }

  const nodeHIDSource = readEntry(nodeHIDFiles[0]).toString('utf8');
  const nodeHIDState = nodeHIDSource.includes(
    'node-hid replacement — installed by patch-chatgpt.sh'
  )
    ? 'patched'
    : nodeHIDSource.includes("require('./build/Release/HID.node')")
      || nodeHIDSource.includes('HIDAsync')
      ? 'pristine'
      : 'invalid:node-hid';

  const serviceSource = readEntry(serviceFiles[0]).toString('utf8');
  const serviceState = classifySingle(
    countOccurrences(serviceSource, oldWatcher),
    countOccurrences(serviceSource, newWatcher),
    'watcher'
  );

  let oldConstructorCount = 0;
  let newConstructorCount = 0;
  for (const file of mainFiles) {
    const source = readEntry(file).toString('utf8');
    oldConstructorCount += countOccurrences(source, oldConstructor);
    newConstructorCount += countOccurrences(source, newConstructor);
  }
  const constructorState = classifySingle(
    oldConstructorCount,
    newConstructorCount,
    'service-constructor'
  );

  let oldRendererCount = 0;
  let newRendererCount = 0;
  let rendererBridgeBundles = 0;
  for (const file of webviewFiles) {
    const source = readEntry(file).toString('utf8');
    if (!source.includes('codex-micro-bridge-') || !source.includes('3207467860')) {
      continue;
    }
    rendererBridgeBundles += 1;
    oldRendererCount += (source.match(oldRendererGate) || []).length;
    newRendererCount += countOccurrences(source, newRendererGate);
  }
  const rendererState = classifySingle(
    oldRendererCount,
    newRendererCount,
    'renderer-gate'
  );

  const shimPresent = fileSet.has('codex-hid-shim.js');
  const states = [nodeHIDState, serviceState, constructorState, rendererState];
  const allPristine = states.every((value) => value === 'pristine') && !shimPresent;
  const allPatched = states.every((value) => value === 'patched') && shimPresent;

  let verifiedFileCount = 0;
  let signedNativeExceptionCount = 0;
  if (verifyIntegrity) {
    for (const file of files) {
      const entry = entryFor(file);
      if (entry.link) continue;
      if (!entry.integrity || entry.integrity.algorithm !== 'SHA256') {
        fail(`ASAR entry has no supported integrity record: ${file}`);
      }
      const value = readEntry(file);
      const hash = crypto.createHash('sha256').update(value).digest('hex');
      if (hash !== entry.integrity.hash) {
        // Electron packs native modules before the outer application-signing
        // pass. Signing appends an embedded Mach-O signature, so the ASAR
        // record legitimately describes the pre-signing bytes. Require both
        // an unpacked entry and a structurally readable embedded signature;
        // every ordinary unpacked or packed file must still hash exactly.
        const unpackedPath = `${archivePath}.unpacked/${file}`;
        const signature = entry.unpacked
          ? childProcess.spawnSync(
              '/usr/bin/codesign',
              ['-d', '--verbose=4', unpackedPath],
              { encoding: 'utf8' }
            )
          : null;
        const signatureMetadata = signature
          ? `${signature.stdout || ''}\n${signature.stderr || ''}`
          : '';
        const signedByOpenAI =
          signature
          && signature.status === 0
          && signatureMetadata
            .split(/\r?\n/)
            .some((line) => line === `TeamIdentifier=${openAITeamIdentifier}`);
        if (!signedByOpenAI) {
          fail(`ASAR entry failed SHA-256 verification: ${file}`);
        }
        signedNativeExceptionCount += 1;
      }
      if (entry.unpacked && entry.executable) {
        const mode = fs.statSync(`${archivePath}.unpacked/${file}`).mode;
        if ((mode & 0o111) === 0) {
          fail(`Unpacked executable has lost its executable mode: ${file}`);
        }
      }
      verifiedFileCount += 1;
    }
  }

  const details = {
    nodeHIDPath: nodeHIDFiles[0],
    serviceBundlePath: serviceFiles[0],
    mainBundleCount: mainFiles.length,
    rendererBridgeBundles,
    nodeHIDState,
    serviceState,
    constructorState,
    rendererState,
    shimPresent,
    integrityVerified: verifyIntegrity,
    verifiedFileCount,
    signedNativeExceptionCount,
  };

  if (allPristine) {
    output({
      state: 'compatible-pristine',
      patched: false,
      compatible: true,
      reason: 'This ChatGPT build matches the supported pristine bundle structure.',
      details,
    });
  }
  if (allPatched) {
    output({
      state: 'compatible-patched',
      patched: true,
      compatible: true,
      reason: 'The Codex Micro patch is installed and matches this ChatGPT build.',
      details,
    });
  }

  output({
    state: 'incompatible',
    patched: shimPresent || states.some((value) => value === 'patched'),
    compatible: false,
    reason:
      'ChatGPT is partially patched or its bundle structure has changed. No files will be modified.',
    details,
  }, 2);
} catch (error) {
  fail(`Unable to validate the ChatGPT bundle: ${error.message}`);
} finally {
  if (archive != null) {
    try {
      fs.closeSync(archive);
    } catch (_) {
      // Process exit closes the descriptor; this is only defensive.
    }
  }
}
