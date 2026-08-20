// codex-hid-shim.js — injected into the ChatGPT desktop app by patch-chatgpt.sh.
//
// The app detects a AgentMicro through a native IOKit watcher
// (findAgentMicroInterfaces / watch) and then talks to it through node-hid.
// This shim replaces BOTH: it reports a virtual AgentMicro as present and
// pipes its HID reports over a local Unix socket to the AgentMicroBridge
// helper, which is linked either to the iPhone app (BLE) or to its own
// built-in emulator (--emulate). No OS-level HID device, so no Apple
// virtual-HID entitlement and no AMFI/SIP changes are required.
//
// Exposes `globalThis.__CODEX_BRIDGE__ = { native, nodehid }` and also
// returns that object from require().

'use strict';

const net = require('net');
const os = require('os');
const path = require('path');
const { EventEmitter } = require('events');
const { TextDecoder } = require('util');

const SOCKET_PATH = process.env.CODEX_BRIDGE_SOCKET
  || path.join(os.tmpdir(), 'CodexMicro', 'codexbridge.sock');
// Read by the menu app's ASAR inspector. Bump this whenever the injected shim
// protocol or safety semantics change in a way that requires re-patching.
const AGENT_MICRO_SHIM_SCHEMA = 2;
const REPORT_ID = 6;
const VID = 12346;   // 0x303A
const PID = 33632;   // 0x8360
const USAGE_PAGE = 65280; // 0xFF00
const FAKE_PATH = 'codex-bridge://virtual/codex-micro';

// AgentMicro-only control channel (device→shim). Not part of the AgentMicro
// wire protocol — mirrors the bridge's channel-3 layout sync but flows the
// other way: the phone/emulator asks the shim to run a host-side action the
// device protocol has no command for (e.g. clearing the composer). The shim
// consumes these frames and never forwards them to node-hid, so ChatGPT's
// device layer never sees channel 4.
const CONTROL_CHANNEL = 4;

// Frame types on the socket (1 byte tag + payload), each prefixed by a
// 4-byte big-endian length covering tag+payload.
const T_PRESENCE = 0x50; // 'P' helper->shim, payload[0] = 0|1
const T_INPUT = 0x49;    // 'I' helper->shim, device->host HID report bytes
const T_OUTPUT = 0x4f;   // 'O' shim->helper, host->device HID report bytes

if (require.main === module && process.argv.includes('--self-test')) {
  runSelfTests();
} else if (globalThis.__CODEX_BRIDGE__) {
  module.exports = globalThis.__CODEX_BRIDGE__;
} else {
  module.exports = createBridge();
  globalThis.__CODEX_BRIDGE__ = module.exports;
}

// Channel 4 is a byte stream fragmented across 61-byte HID report bodies. A
// newline terminates each logical JSON message. Keeping framing at the byte
// level is important: a multi-byte UTF-8 scalar may be split between reports.
// The parser also bounds one unterminated frame and discards only that frame,
// resynchronising at its next newline.
function createControlChannelParser({
  onMessage,
  log = () => {},
  maximumMessageBytes = 64 * 1024,
} = {}) {
  let frame = Buffer.alloc(0);
  let discardingUntilNewline = false;
  const decoder = new TextDecoder('utf-8', { fatal: true });

  function reset() {
    frame = Buffer.alloc(0);
    discardingUntilNewline = false;
  }

  function discardMalformedReport(payload) {
    frame = Buffer.alloc(0);
    const body = payload.length > 3 ? payload.subarray(3) : Buffer.alloc(0);
    // If this corrupt report contains a delimiter, it already supplies a safe
    // resynchronisation point. Otherwise ignore the remainder of this logical
    // frame until a later fragment terminates it.
    discardingUntilNewline = !body.includes(0x0A);
    log('discarded malformed control report');
  }

  function dispatchLine(line) {
    if (line.length === 0) return;
    let message;
    try {
      message = JSON.parse(decoder.decode(line));
    } catch (_) {
      log('discarded malformed control message');
      return;
    }
    if (!message || typeof message !== 'object' || Array.isArray(message)) {
      log('discarded non-object control message');
      return;
    }
    onMessage(message);
  }

  function acceptFragment(fragment) {
    let cursor = 0;
    while (cursor < fragment.length) {
      const newline = fragment.indexOf(0x0A, cursor);
      const end = newline === -1 ? fragment.length : newline;
      const segment = fragment.subarray(cursor, end);

      if (!discardingUntilNewline && segment.length > 0) {
        if (frame.length + segment.length > maximumMessageBytes) {
          frame = Buffer.alloc(0);
          discardingUntilNewline = true;
          log('discarded oversized control message');
        } else {
          frame = frame.length === 0
            ? Buffer.from(segment)
            : Buffer.concat([frame, segment]);
        }
      }

      if (newline === -1) return;
      if (discardingUntilNewline) {
        discardingUntilNewline = false;
      } else {
        dispatchLine(frame);
      }
      frame = Buffer.alloc(0);
      cursor = newline + 1;
    }
  }

  // Returns true for every channel-4 report, including corrupt reports, so a
  // private control fragment can never leak into ChatGPT's node-hid handlers.
  function handleReport(payload) {
    if (payload.length < 2 || payload[1] !== CONTROL_CHANNEL) return false;
    if (payload.length < 3 || payload[0] !== REPORT_ID) {
      discardMalformedReport(payload);
      return true;
    }
    const declaredLength = payload[2];
    if (declaredLength > 61 || payload.length < 3 + declaredLength) {
      discardMalformedReport(payload);
      return true;
    }
    acceptFragment(payload.subarray(3, 3 + declaredLength));
    return true;
  }

  return {
    handleReport,
    reset,
    snapshot() {
      return {
        bufferedBytes: frame.length,
        discardingUntilNewline,
      };
    },
  };
}

function createBridge() {
  const events = new EventEmitter();
  events.setMaxListeners(0);

  let present = false;
  let socket = null;
  let rxBuffer = Buffer.alloc(0);
  let openDevice = null; // the single active HIDAsync device, if any
  let helperDropTimer = null;
  const controlParser = createControlChannelParser({
    onMessage: dispatchControlMessage,
    log,
  });

  function log(msg) {
    // Surfaces in the app's stdout/Console; harmless if nobody reads it.
    try { process.stdout.write(`[codex-shim] ${msg}\n`); } catch (_) {}
  }

  function setPresent(next) {
    if (next && helperDropTimer) {
      clearTimeout(helperDropTimer);
      helperDropTimer = null;
    }
    if (present === next) return;
    present = next;
    log(`device ${present ? 'present' : 'absent'}`);
    events.emit('presence', present);
    if (!present && openDevice) openDevice._remoteClosed();
  }

  function connect() {
    socket = net.connect(SOCKET_PATH);
    socket.on('connect', () => log(`connected to helper at ${SOCKET_PATH}`));
    socket.on('data', (chunk) => {
      rxBuffer = Buffer.concat([rxBuffer, chunk]);
      for (;;) {
        if (rxBuffer.length < 4) return;
        const len = rxBuffer.readUInt32BE(0);
        if (rxBuffer.length < 4 + len) return;
        const frame = rxBuffer.subarray(4, 4 + len);
        rxBuffer = rxBuffer.subarray(4 + len);
        if (frame.length >= 1) handleFrame(frame[0], frame.subarray(1));
      }
    });
    const drop = () => {
      if (!socket) return; // 'error' then 'close' both fire — only reconnect once
      socket.removeAllListeners(); socket.destroy(); socket = null;
      rxBuffer = Buffer.alloc(0);
      controlParser.reset();
      // A helper rebuild/restart is normally back within a second. Keep the
      // virtual HID handle alive briefly so the desktop service can continue
      // across that transport blip; an explicit helper presence=0 frame (the
      // phone actually disconnected) still closes it immediately.
      if (!helperDropTimer) {
        helperDropTimer = setTimeout(() => {
          helperDropTimer = null;
          setPresent(false);
        }, 5000);
      }
      setTimeout(connect, 1000); // helper may not be running yet; keep retrying
    };
    socket.on('error', drop);
    socket.on('close', drop);
  }

  function handleFrame(tag, payload) {
    if (tag === T_PRESENCE) {
      setPresent(payload.length >= 1 && payload[0] === 1);
    } else if (tag === T_INPUT) {
      // Intercept AgentMicro control frames before they reach the app.
      if (handleControlFrame(payload)) return;
      if (openDevice) openDevice._deliver(Buffer.from(payload));
    }
  }

  // A device→host report is [reportId=6][channel][len][payload…]. Channel 4 is
  // the AgentMicro control channel: parse the JSON body and run the requested
  // host-side action, then swallow the frame so node-hid never sees it. Returns
  // true when the frame was a control frame (handled or malformed — either way
  // it must not be forwarded).
  function handleControlFrame(payload) {
    return controlParser.handleReport(payload);
  }

  function dispatchControlMessage(msg) {
    if (msg && msg.cmd === 'clearComposer') clearComposer();
    else if (msg && msg.cmd === 'insertText') insertComposerText(msg.text);
    else log('ignored unknown control command');
  }

  // Clear ChatGPT's message composer using stable Electron editing commands, so
  // no fragile patching of the minified renderer is needed. selectAll targets
  // the focused editable element; if the composer isn't focused, delete acts on
  // a non-editable selection and is a harmless no-op — it can never wipe a
  // conversation, only the composer text.
  function clearComposer() {
    let electron;
    try { electron = require('electron'); } catch (_) { return; }
    const BrowserWindow = electron && electron.BrowserWindow;
    if (!BrowserWindow) return;
    const wins = BrowserWindow.getAllWindows();
    const win = BrowserWindow.getFocusedWindow()
      || wins.find((w) => w.isVisible())
      || wins[0];
    if (!win || win.isDestroyed()) return;
    try {
      const wc = win.webContents;
      wc.focus();
      wc.selectAll();
      wc.delete();
      log('cleared composer');
    } catch (err) {
      log(`clearComposer failed: ${err && err.message}`);
    }
  }

  // Insert dictated/typed text into ChatGPT's composer using the stable Electron
  // `webContents.insertText`, symmetric to clearComposer. Runs inside ChatGPT's
  // own renderer against the focused editable element, so it needs no macOS
  // Accessibility permission and never simulates keystrokes. Used when the Codex
  // microphone is set to "This iPhone": the phone transcribes on-device and
  // delivers the text here instead of driving the Mac's push-to-talk.
  function insertComposerText(text) {
    if (typeof text !== 'string' || text.length === 0) return;
    let electron;
    try { electron = require('electron'); } catch (_) { return; }
    const BrowserWindow = electron && electron.BrowserWindow;
    if (!BrowserWindow) return;
    const wins = BrowserWindow.getAllWindows();
    const win = BrowserWindow.getFocusedWindow()
      || wins.find((w) => w.isVisible())
      || wins[0];
    if (!win || win.isDestroyed()) return;
    try {
      const wc = win.webContents;
      wc.focus();
      wc.insertText(text);
      log(`inserted ${text.length} chars into composer`);
    } catch (err) {
      log(`insertText failed: ${err && err.message}`);
    }
  }

  function sendOutput(reportBytes) {
    if (!socket || socket.destroyed) throw new Error('bridge helper not connected');
    const body = Buffer.concat([Buffer.from([T_OUTPUT]), reportBytes]);
    const header = Buffer.alloc(4);
    header.writeUInt32BE(body.length, 0);
    socket.write(Buffer.concat([header, body]));
  }

  connect();

  // ---- node-hid replacement -------------------------------------------------

  function descriptor() {
    return {
      vendorId: VID,
      productId: PID,
      path: FAKE_PATH,
      serialNumber: 'CODEXBRIDGE0001',
      manufacturer: 'Work Louder',
      product: 'Codex Micro',
      release: 0,          // even => isUsbConnection true (release % 4 === 0)
      interface: -1,
      usagePage: USAGE_PAGE,
      usage: 1,
    };
  }

  function devices() {
    return present ? [descriptor()] : [];
  }
  function devicesAsync() {
    return Promise.resolve(devices());
  }

  class BridgeHIDAsync extends EventEmitter {
    constructor() {
      super();
      this.setMaxListeners(0);
      this._closed = false;
      openDevice = this;
    }
    _deliver(buf) {
      if (!this._closed) this.emit('data', buf);
    }
    _remoteClosed() {
      if (this._closed) return;
      this._closed = true;
      if (openDevice === this) openDevice = null;
      this.emit('close');
    }
    write(data) {
      const buf = Buffer.isBuffer(data) ? data : Buffer.from(data);
      try {
        sendOutput(buf);
        return Promise.resolve(buf.length);
      } catch (err) {
        this.emit('error', err);
        return Promise.reject(err);
      }
    }
    async read() { return Buffer.alloc(0); }
    async getFeatureReport(id, len) { return Buffer.alloc(len || 0); }
    async sendFeatureReport(data) { return (data && data.length) || 0; }
    async getDeviceInfo() { return descriptor(); }
    pause() {}
    resume() {}
    async setNonBlocking() {}
    async close() {
      if (this._closed) return;
      this._closed = true;
      if (openDevice === this) openDevice = null;
      this.emit('close');
    }
  }

  const HIDAsync = {
    async open() {
      if (!present) throw new Error('AgentMicro bridge: no device present');
      return new BridgeHIDAsync();
    },
  };

  // Synchronous HID class — unused on macOS (the app uses HIDAsync) but
  // provided so the module shape matches node-hid.
  class HID extends BridgeHIDAsync {
    constructor() { super(); }
  }

  const nodehid = {
    devices,
    devicesAsync,
    HID,
    HIDAsync,
    setDriverType() {},
    default: undefined,
  };
  nodehid.default = nodehid;

  // ---- native hid-topology-watcher replacement ------------------------------

  const native = {
    // Returns raw interface descriptors; the app maps these to portPaths and
    // filters on usagePage === 0xFF00.
    //
    // The name is ChatGPT's, not ours: its service calls
    // `findCodexMicroInterfaces()` on this object. Renaming it makes discovery
    // throw, which the UI reports as "couldn't check for your device".
    findCodexMicroInterfaces() {
      return present
        ? [{ path: FAKE_PATH, usagePage: USAGE_PAGE, release: 0, vendorId: VID, productId: PID }]
        : [];
    },
    // watch(cb): invoke cb on every topology change; return a disposable.
    watch(cb) {
      const handler = () => { try { cb(); } catch (_) {} };
      events.on('presence', handler);
      return { dispose() { events.removeListener('presence', handler); } };
    },
  };

  return { native, nodehid, shimSchema: AGENT_MICRO_SHIM_SCHEMA };
}

function runSelfTests() {
  const assert = require('assert');

  function report(fragment, options = {}) {
    const body = Buffer.isBuffer(fragment) ? fragment : Buffer.from(fragment);
    const declaredLength = options.declaredLength == null
      ? body.length
      : options.declaredLength;
    return Buffer.concat([
      Buffer.from([
        options.reportID == null ? REPORT_ID : options.reportID,
        options.channel == null ? CONTROL_CHANNEL : options.channel,
        declaredLength,
      ]),
      body,
    ]);
  }

  {
    const messages = [];
    const parser = createControlChannelParser({ onMessage: (value) => messages.push(value) });
    const encoded = Buffer.from(
      `${JSON.stringify({ cmd: 'insertText', text: 'Hello 🌍 café 中文' })}\n`,
      'utf8'
    );
    const emojiStart = encoded.indexOf(Buffer.from('🌍', 'utf8'));
    const cuts = [emojiStart + 1, emojiStart + 3, encoded.length - 2];
    let start = 0;
    for (const end of cuts.concat(encoded.length)) {
      assert.equal(parser.handleReport(report(encoded.subarray(start, end))), true);
      start = end;
    }
    assert.deepEqual(messages, [
      { cmd: 'insertText', text: 'Hello 🌍 café 中文' },
    ]);
    assert.deepEqual(parser.snapshot(), {
      bufferedBytes: 0,
      discardingUntilNewline: false,
    });
  }

  {
    const messages = [];
    const logs = [];
    const parser = createControlChannelParser({
      onMessage: (value) => messages.push(value),
      log: (value) => logs.push(value),
    });
    assert.equal(parser.handleReport(report('not-json\n')), true);
    assert.equal(
      parser.handleReport(
        report(
          `${JSON.stringify({ cmd: 'clearComposer' })}\n`
          + `${JSON.stringify({ cmd: 'insertText', text: 'safe' })}\n`
        )
      ),
      true
    );
    assert.deepEqual(messages, [
      { cmd: 'clearComposer' },
      { cmd: 'insertText', text: 'safe' },
    ]);
    assert(logs.includes('discarded malformed control message'));
    assert.equal(
      parser.handleReport(report('ignored', { channel: 2 })),
      false
    );
  }

  {
    const messages = [];
    const parser = createControlChannelParser({ onMessage: (value) => messages.push(value) });
    assert.equal(
      parser.handleReport(report('corrupt', { declaredLength: 62 })),
      true
    );
    assert.deepEqual(parser.snapshot(), {
      bufferedBytes: 0,
      discardingUntilNewline: true,
    });
    // The next complete line is the tail of the damaged logical frame.
    parser.handleReport(report(`${JSON.stringify({ cmd: 'clearComposer' })}\n`));
    assert.equal(messages.length, 0);
    parser.handleReport(report(`${JSON.stringify({ cmd: 'clearComposer' })}\n`));
    assert.deepEqual(messages, [{ cmd: 'clearComposer' }]);
  }

  {
    const messages = [];
    const logs = [];
    const parser = createControlChannelParser({
      maximumMessageBytes: 24,
      onMessage: (value) => messages.push(value),
      log: (value) => logs.push(value),
    });
    parser.handleReport(report('x'.repeat(25)));
    assert.deepEqual(parser.snapshot(), {
      bufferedBytes: 0,
      discardingUntilNewline: true,
    });
    parser.handleReport(
      report(`tail\n${JSON.stringify({ cmd: 'ok' })}\n`)
    );
    assert.deepEqual(messages, [{ cmd: 'ok' }]);
    assert(logs.includes('discarded oversized control message'));
    parser.handleReport(report('partial'));
    parser.reset();
    assert.deepEqual(parser.snapshot(), {
      bufferedBytes: 0,
      discardingUntilNewline: false,
    });
  }

  {
    const messages = [];
    const parser = createControlChannelParser({ onMessage: (value) => messages.push(value) });
    const invalidUTF8 = Buffer.from([
      ...Buffer.from('{"cmd":"insertText","text":"', 'utf8'),
      0xC3,
      0x28,
      ...Buffer.from('"}\n', 'utf8'),
    ]);
    parser.handleReport(report(invalidUTF8));
    assert.equal(messages.length, 0);
    assert.equal(
      parser.handleReport(
        report(`${JSON.stringify({ cmd: 'insertText', text: 'valid' })}\n`)
      ),
      true
    );
    assert.deepEqual(messages, [{ cmd: 'insertText', text: 'valid' }]);
  }

  process.stdout.write('codex-hid-shim self-test: PASS (5 cases)\n');
}
