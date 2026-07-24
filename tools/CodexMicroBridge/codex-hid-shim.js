// codex-hid-shim.js — injected into the ChatGPT desktop app by patch-chatgpt.sh.
//
// The app detects a Codex Micro through a native IOKit watcher
// (findCodexMicroInterfaces / watch) and then talks to it through node-hid.
// This shim replaces BOTH: it reports a virtual Codex Micro as present and
// pipes its HID reports over a local Unix socket to the CodexMicroBridge
// helper, which is linked either to the iPhone app (BLE) or to its own
// built-in emulator (--emulate). No OS-level HID device, so no Apple
// virtual-HID entitlement and no AMFI/SIP changes are required.
//
// Exposes `globalThis.__CODEX_BRIDGE__ = { native, nodehid }` and also
// returns that object from require().

'use strict';

const net = require('net');
const { EventEmitter } = require('events');

const SOCKET_PATH = process.env.CODEX_BRIDGE_SOCKET || '/tmp/codexbridge.sock';
const REPORT_ID = 6;
const VID = 12346;   // 0x303A
const PID = 33632;   // 0x8360
const USAGE_PAGE = 65280; // 0xFF00
const FAKE_PATH = 'codex-bridge://virtual/codex-micro';

// SidePulse-only control channel (device→shim). Not part of the Codex Micro
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

if (globalThis.__CODEX_BRIDGE__) {
  module.exports = globalThis.__CODEX_BRIDGE__;
} else {
  module.exports = createBridge();
  globalThis.__CODEX_BRIDGE__ = module.exports;
}

function createBridge() {
  const events = new EventEmitter();
  events.setMaxListeners(0);

  let present = false;
  let socket = null;
  let rxBuffer = Buffer.alloc(0);
  let openDevice = null; // the single active HIDAsync device, if any
  let helperDropTimer = null;

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
      // Intercept SidePulse control frames before they reach the app.
      if (handleControlFrame(payload)) return;
      if (openDevice) openDevice._deliver(Buffer.from(payload));
    }
  }

  // A device→host report is [reportId=6][channel][len][payload…]. Channel 4 is
  // the SidePulse control channel: parse the JSON body and run the requested
  // host-side action, then swallow the frame so node-hid never sees it. Returns
  // true when the frame was a control frame (handled or malformed — either way
  // it must not be forwarded).
  function handleControlFrame(payload) {
    if (payload.length < 3 || payload[1] !== CONTROL_CHANNEL) return false;
    const len = Math.min(payload[2], payload.length - 3);
    const body = payload.subarray(3, 3 + len);
    let msg = null;
    try { msg = JSON.parse(body.toString('utf8')); } catch (_) { return true; }
    if (msg && msg.cmd === 'clearComposer') clearComposer();
    else if (msg && msg.cmd === 'insertText') insertComposerText(msg.text);
    else log(`ignored unknown control frame: ${body.toString('utf8')}`);
    return true;
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
      if (!present) throw new Error('Codex Micro bridge: no device present');
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

  return { native, nodehid };
}
