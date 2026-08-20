'use strict';

const assert = require('node:assert/strict');
const { EventEmitter: NodeEventEmitter } = require('node:events');
const fs = require('node:fs');
const Module = require('node:module');
const path = require('node:path');
const test = require('node:test');

function event() { return () => ({ dispose() {} }); }

// Deterministic in-memory Unix-socket model. The managed test sandbox forbids
// AF_UNIX listen(), and protocol tests should not depend on host IPC anyway.
function createFakeNet() {
  const servers = new Map();
  class Socket extends NodeEventEmitter {
    constructor() { super(); this.peer = null; this.closed = false; }
    write(value) {
      if (this.closed || !this.peer || this.peer.closed) return false;
      const target = this.peer;
      queueMicrotask(() => { if (!target.closed) target.emit('data', Buffer.from(value)); });
      return true;
    }
    destroy() {
      if (this.closed) return;
      this.closed = true;
      const peer = this.peer;
      queueMicrotask(() => this.emit('close'));
      if (peer && !peer.closed) {
        peer.closed = true;
        queueMicrotask(() => peer.emit('close'));
      }
    }
    end() { this.destroy(); }
  }
  class Server extends NodeEventEmitter {
    constructor(listener) { super(); this.listener = listener; this.path = null; }
    listen(socketPath, callback) {
      if (servers.has(socketPath)) {
        queueMicrotask(() => {
          const error = Object.assign(new Error(`listen EADDRINUSE ${socketPath}`), { code: 'EADDRINUSE' });
          this.emit('error', error);
        });
        return this;
      }
      this.path = socketPath;
      servers.set(socketPath, this);
      queueMicrotask(() => callback?.());
      return this;
    }
    close(callback) {
      if (this.path && servers.get(this.path) === this) servers.delete(this.path);
      this.path = null;
      queueMicrotask(() => { this.emit('close'); callback?.(); });
    }
  }
  const createConnection = (options) => {
    const socketPath = typeof options === 'string' ? options : options.path;
    const client = new Socket();
    queueMicrotask(() => {
      const server = servers.get(socketPath);
      if (!server) {
        const error = Object.assign(new Error(`connect ENOENT ${socketPath}`), { code: 'ENOENT' });
        client.emit('error', error);
        client.destroy();
        return;
      }
      const accepted = new Socket();
      client.peer = accepted;
      accepted.peer = client;
      server.listener(accepted);
      client.emit('connect');
    });
    return client;
  };
  return { createServer: (listener) => new Server(listener), createConnection };
}

test('socket protocol creates, selects, pins, decorates, inserts, and submits', async () => {
  const socketPath = path.join('/tmp', `agent-micro-test-${process.pid}.sock`);
  const net = createFakeNet();
  const commands = [];
  const terminals = [];
  const shownDocuments = [];
  let decorationProvider;

  class EventEmitter {
    constructor() { this.event = event(); }
    fire() {}
    dispose() {}
  }
  class ThemeColor { constructor(id) { this.id = id; } }
  class ThemeIcon { constructor(id) { this.id = id; } }

  const fileUri = { scheme: 'file', toString: () => 'file:///workspace/app.js' };
  const tab = { label: 'app.js', input: { uri: fileUri }, isActive: false };
  const claudeTab = {
    label: 'Claude Code',
    input: { viewType: 'claudeVSCodePanel' },
    isActive: false,
    isPinned: false,
  };
  const tabGroup = { viewColumn: 1, isActive: true, tabs: [tab, claudeTab] };
  const setActiveTab = (activeTab) => {
    for (const candidate of tabGroup.tabs) candidate.isActive = candidate === activeTab;
  };
  const currentActiveTab = () => tabGroup.tabs.find((candidate) => candidate.isActive);
  const vscode = {
    EventEmitter,
    ThemeColor,
    ThemeIcon,
    StatusBarAlignment: { Right: 2 },
    extensions: { getExtension: () => ({}) },
    env: { clipboard: { writeText: async () => {} } },
    Uri: { parse: (value) => ({ toString: () => value }) },
    workspace: {
      getConfiguration: () => ({
        get(key, fallback) {
          const values = { socketPath, terminalApprove: 'y\n', terminalReject: 'n\n', terminalSubmit: '\n', decorateTabs: true };
          return key in values ? values[key] : fallback;
        },
      }),
      openTextDocument: async () => ({ uri: fileUri }),
    },
    commands: {
      getCommands: async () => ['claude-vscode.toggleDictation'],
      executeCommand: async (command, ...args) => {
        commands.push([command, ...args]);
        const editorIndex = /^workbench\.action\.openEditorAtIndex(\d+)$/.exec(command);
        if (editorIndex) setActiveTab(tabGroup.tabs[Number(editorIndex[1]) - 1]);
        if (command === 'workbench.action.pinEditor') {
          const active = currentActiveTab();
          if (active) {
            active.isPinned = true;
            // Model VS Code's native pinned-editor section moving a newly pinned
            // webview. Its AgentMicro id must continue naming this exact tab.
            if (active.simulatePinReorder) {
              tabGroup.tabs.splice(tabGroup.tabs.indexOf(active), 1);
              tabGroup.tabs.unshift(active);
            }
          }
        }
        if (command === 'workbench.action.unpinEditor') {
          const active = currentActiveTab();
          if (active) active.isPinned = false;
        }
      },
      registerCommand: () => ({ dispose() {} }),
    },
    window: {
      state: { focused: true },
      terminals,
      activeTerminal: null,
      activeTextEditor: null,
      tabGroups: { all: [tabGroup], onDidChangeTabs: event() },
      createOutputChannel: () => ({ appendLine(message) { if (process.env.CODEX_MICRO_TEST_LOG) console.error(message); }, show() {}, dispose() {} }),
      createStatusBarItem: () => ({ show() {}, hide() {}, dispose() {} }),
      registerFileDecorationProvider(provider) { decorationProvider = provider; return { dispose() {} }; },
      onDidOpenTerminal: event(),
      onDidCloseTerminal: event(),
      onDidChangeActiveTerminal: event(),
      onDidChangeActiveTextEditor: event(),
      onDidChangeWindowState: event(),
      showInformationMessage: async () => {},
      showTextDocument: async (document) => {
        shownDocuments.push(document.uri.toString());
        const matching = tabGroup.tabs.find((candidate) => candidate.input
          && candidate.input.uri
          && candidate.input.uri.toString() === document.uri.toString());
        if (matching) setActiveTab(matching);
      },
      createTerminal(options) {
        const terminal = {
          name: options.name,
          sent: [],
          show() {},
          sendText(text, addNewLine) { this.sent.push([text, addNewLine]); },
        };
        terminals.push(terminal);
        return terminal;
      },
    },
  };

  const originalLoad = Module._load;
  Module._load = function mockLoad(request, parent, isMain) {
    if (request === 'vscode') return vscode;
    if (request === 'net') return net;
    return originalLoad.call(this, request, parent, isMain);
  };

  const extension = require('../extension');
  const subscriptions = [];
  extension.activate({ subscriptions });

  const socket = await new Promise((resolve, reject) => {
    const deadline = Date.now() + 2000;
    const connect = () => {
      const candidate = net.createConnection(socketPath);
      candidate.once('connect', () => resolve(candidate));
      candidate.once('error', (error) => {
        candidate.destroy();
        if (Date.now() >= deadline) reject(error);
        else setTimeout(connect, 20);
      });
    };
    connect();
  });

  let buffer = '';
  const received = [];
  socket.on('data', (chunk) => {
    buffer += chunk.toString();
    let newline;
    while ((newline = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, newline);
      buffer = buffer.slice(newline + 1);
      if (line) received.push(JSON.parse(line));
    }
  });
  const send = (message) => socket.write(`${JSON.stringify(message)}\n`);
  const waitFor = async (predicate) => {
    const deadline = Date.now() + 2000;
    while (Date.now() < deadline) {
      const match = received.find(predicate);
      if (match) return match;
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    throw new Error(`message not received: ${JSON.stringify(received)}`);
  };
  const waitUntil = async (predicate) => {
    const deadline = Date.now() + 2000;
    while (Date.now() < deadline) {
      if (predicate()) return;
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    throw new Error('condition not reached');
  };

  send({ op: 'new', kind: 'terminal', value: 'codex', label: 'Codex terminal' });
  const created = await waitFor((msg) => msg.type === 'ack' && msg.op === 'new');
  assert.equal(created.ok, true);
  assert.equal(terminals[0].sent[0][0], 'codex');

  send({ op: 'insert', id: created.id, text: 'fix the tests' });
  await waitFor((msg) => msg.type === 'ack' && msg.op === 'insert');
  assert.deepEqual(terminals[0].sent.at(-1), ['fix the tests', false]);

  send({ op: 'submit', id: created.id });
  await waitFor((msg) => msg.type === 'ack' && msg.op === 'submit');
  assert.deepEqual(terminals[0].sent.at(-1), ['\n', false]);

  const editorId = 'tab:file:///workspace/app.js';
  send({ op: 'focus', id: editorId });
  await waitFor((msg) => msg.type === 'ack' && msg.op === 'focus' && msg.id === editorId);
  const documentsBeforeAutoSend = shownDocuments.length;

  const beforeAutoSend = terminals[0].sent.length;
  send({ op: 'insert', id: created.id, text: 'ship reliably', submit: true });
  const autoSent = await waitFor((msg) => msg.type === 'ack' && msg.op === 'insert'
    && msg.id === created.id && msg.ok && msg.submitted);
  assert.equal(autoSent.ok, true);
  assert.deepEqual(terminals[0].sent.slice(beforeAutoSend), [
    ['ship reliably', false],
    ['\n', false],
  ]);
  assert.equal(shownDocuments.length, documentsBeforeAutoSend + 1,
    'the agent selected during transcription is restored after targeted auto-send');

  send({ op: 'status', pins: ['tab:file:///workspace/app.js'], selected: created.id,
    slots: [{ id: 0, status: 'thinking' }] });
  await waitFor((msg) => msg.type === 'ack' && msg.op === 'status');
  const decoration = decorationProvider.provideFileDecoration(fileUri);
  assert.equal(decoration.color.id, 'codexMicro.statusWorking');
  assert.equal(decoration.badge, '●');

  send({ op: 'list' });
  const nativeTargets = await waitFor((msg) => msg.type === 'targets'
    && msg.targets.some((target) => target.kind === 'agent-editor' && target.nativeVoice));
  const claude = nativeTargets.targets.find((target) => target.kind === 'agent-editor');
  assert.equal(claude.provider, 'claude');
  assert.equal(claude.nativeVoice, true);

  send({ op: 'voice', id: claude.id, active: true });
  const voiceStarted = await waitFor((msg) => msg.type === 'ack' && msg.op === 'voice' && msg.active);
  assert.equal(voiceStarted.ok, true);

  // Switching while dictating must not redirect the release to a different
  // chat. The extension stops the captured Claude tab, then restores app.js.
  send({ op: 'focus', id: editorId });
  await waitFor((msg) => msg.type === 'ack' && msg.op === 'focus' && msg.id === editorId);
  send({ op: 'voice', id: claude.id, active: false });
  const voiceStopped = await waitFor((msg) => msg.type === 'ack' && msg.op === 'voice' && !msg.active);
  assert.equal(voiceStopped.ok, true);
  assert.equal(commands.filter(([command]) => command === 'claude-vscode.toggleDictation').length, 2);
  assert.equal(commands.filter(([command]) => command === 'workbench.action.openEditorAtIndex2').length, 2);

  // AgentMicro pins are a macropad concept only (agent-key LEDs + tab color +
  // status bar). Applying or removing a pin snapshot must NEVER drive VS Code's
  // own native editor pins: doing so fought the user's mouse (clicking a pinned
  // webview tab re-pinned it, so it "glitched and stayed on") and relied on VS
  // Code's native pin-state, which miscalculates when exactly one tab is
  // unpinned (microsoft/vscode#200305).
  const pinCommandsBaseline = commands.filter(([command]) =>
    command === 'workbench.action.pinEditor' || command === 'workbench.action.unpinEditor').length;
  send({ op: 'pins', pins: [claude.id], selected: editorId });
  await waitFor((msg) => msg.type === 'ack' && msg.op === 'pins');
  send({ op: 'status', pins: [claude.id], selected: editorId, slots: [{ id: 0, status: 'thinking' }] });
  await waitFor((msg) => msg.type === 'ack' && msg.op === 'status');
  send({ op: 'pins', pins: [], selected: editorId });
  await waitFor((msg) => msg.type === 'ack' && msg.op === 'pins');
  const pinCommandsAfter = commands.filter(([command]) =>
    command === 'workbench.action.pinEditor' || command === 'workbench.action.unpinEditor').length;
  assert.equal(pinCommandsAfter, pinCommandsBaseline,
    'applying or removing AgentMicro pins never issues a native pin/unpin command');
  assert.equal(claudeTab.isPinned, false, 'a webview tab is never natively pinned by AgentMicro');

  // Regression: a stale bridge selection on the first Claude chat must not make
  // both it and the genuinely active third chat report `active`. Only VS Code's
  // live active tab may be advertised as active.
  const secondClaudeTab = {
    label: 'Second conversation',
    input: { viewType: 'claudeVSCodePanel' },
    isActive: false,
  };
  const thirdClaudeTab = {
    label: 'Third conversation',
    input: { viewType: 'claudeVSCodePanel' },
    isActive: false,
  };
  tabGroup.tabs.push(secondClaudeTab, thirdClaudeTab);
  setActiveTab(claudeTab);
  received.length = 0;
  send({ op: 'list' });
  const beforeThirdSelection = await waitFor((msg) => msg.type === 'targets'
    && msg.targets.some((target) => target.label === 'Third conversation'));
  const firstClaudeId = beforeThirdSelection.targets.find((target) => target.label === 'Claude Code').id;
  const thirdClaudeId = beforeThirdSelection.targets.find((target) => target.label === 'Third conversation').id;
  send({ op: 'focus', id: firstClaudeId });
  await waitFor((msg) => msg.type === 'ack' && msg.op === 'focus' && msg.id === firstClaudeId);

  // Simulate clicking the third tab without allowing the extension's cached
  // logical selection to catch up before the helper asks for a list.
  setActiveTab(thirdClaudeTab);
  received.length = 0;
  send({ op: 'list' });
  const thirdActiveList = await waitFor((msg) => msg.type === 'targets'
    && msg.targets.some((target) => target.label === 'Third conversation'));
  assert.deepEqual(
    thirdActiveList.targets.filter((target) => target.active).map((target) => target.label),
    ['Third conversation'],
    'only VS Code\'s genuinely active third tab is advertised as active'
  );

  // The opaque agent-tab identity must survive VS Code reordering tabs on its
  // own (a manual drag/pin by the user) without transferring an id to a sibling
  // conversation.
  tabGroup.tabs.splice(tabGroup.tabs.indexOf(thirdClaudeTab), 1);
  tabGroup.tabs.unshift(thirdClaudeTab);
  received.length = 0;
  send({ op: 'list' });
  const afterReorder = await waitFor((msg) => msg.type === 'targets'
    && msg.targets.some((target) => target.label === 'Third conversation'));
  assert.equal(
    afterReorder.targets.find((target) => target.label === 'Third conversation').id,
    thirdClaudeId,
    'tab reordering cannot transfer the agent-tab id to a sibling tab'
  );

  socket.destroy();
  for (const disposable of subscriptions.reverse()) disposable.dispose?.();
  Module._load = originalLoad;
  try { fs.unlinkSync(socketPath); } catch (_) {}
});
