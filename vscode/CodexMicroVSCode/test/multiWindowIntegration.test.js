'use strict';

const assert = require('node:assert/strict');
const { EventEmitter: NodeEventEmitter } = require('node:events');
const Module = require('node:module');
const test = require('node:test');

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
        queueMicrotask(() => this.emit('error', Object.assign(new Error('in use'), { code: 'EADDRINUSE' })));
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
        client.emit('error', Object.assign(new Error('missing'), { code: 'ENOENT' }));
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

function createVSCodeWindow(socketPath, label, initiallyFocused) {
  const listeners = { windowState: [] };
  const commands = [];
  const terminals = [];
  const tab = {
    label,
    input: { viewType: 'claudeVSCodePanel' },
    isActive: true,
    isPinned: false,
  };
  const group = { viewColumn: 1, isActive: true, tabs: [tab] };
  const event = (bucket) => (listener) => {
    if (bucket) listeners[bucket].push(listener);
    return { dispose() {} };
  };
  class EventEmitter {
    constructor() { this.event = event(); }
    fire() {}
    dispose() {}
  }
  class ThemeColor { constructor(id) { this.id = id; } }
  class ThemeIcon { constructor(id) { this.id = id; } }
  const state = { focused: initiallyFocused };
  const vscode = {
    EventEmitter,
    ThemeColor,
    ThemeIcon,
    StatusBarAlignment: { Right: 2 },
    Uri: { parse: (value) => ({ toString: () => value }) },
    workspace: {
      workspaceFolders: [{ uri: { fsPath: `/workspace/${label}`, toString: () => `file:///workspace/${label}` } }],
      getWorkspaceFolder: () => null,
      getConfiguration: () => ({
        get(key, fallback) {
          const values = {
            socketPath,
            terminalApprove: 'y\n', terminalReject: 'n\n', terminalSubmit: '\n', decorateTabs: true,
          };
          return key in values ? values[key] : fallback;
        },
      }),
      openTextDocument: async () => { throw new Error('not a file target'); },
    },
    commands: {
      getCommands: async () => [],
      executeCommand: async (command, ...args) => {
        commands.push([command, ...args]);
        if (command === 'workbench.action.pinEditor') tab.isPinned = true;
        if (command === 'workbench.action.unpinEditor') tab.isPinned = false;
      },
      registerCommand: () => ({ dispose() {} }),
    },
    window: {
      state,
      terminals,
      activeTerminal: null,
      activeTextEditor: null,
      tabGroups: { all: [group], onDidChangeTabs: event() },
      createOutputChannel: () => ({ appendLine() {}, show() {}, dispose() {} }),
      createStatusBarItem: () => ({ show() {}, hide() {}, dispose() {} }),
      registerFileDecorationProvider: () => ({ dispose() {} }),
      onDidOpenTerminal: event(),
      onDidCloseTerminal: event(),
      onDidChangeActiveTerminal: event(),
      onDidChangeActiveTextEditor: event(),
      onDidChangeWindowState: event('windowState'),
      showInformationMessage: async () => {},
      showTextDocument: async () => {},
      createTerminal(options) {
        const terminal = {
          name: options.name, show() {}, sent: [],
          sendText(text, addNewLine) { this.sent.push([text, addNewLine]); },
        };
        terminals.push(terminal);
        return terminal;
      },
    },
  };
  return {
    vscode, tab, commands, terminals,
    focus(value) {
      state.focused = value;
      for (const listener of listeners.windowState) listener({ focused: value });
    },
  };
}

test('socket hub retains two projects and routes focus, pins, and NEW to the owning window', async (t) => {
  const socketPath = `/tmp/codex-micro-multi-window-${process.pid}.sock`;
  const fakeNet = createFakeNet();
  const projectA = createVSCodeWindow(socketPath, 'Project A chat', true);
  const projectB = createVSCodeWindow(socketPath, 'Project B chat', false);
  const originalLoad = Module._load;
  const extensionPath = require.resolve('../extension');
  let activeVSCode = projectA.vscode;
  Module._load = function mockLoad(request, parent, isMain) {
    if (request === 'vscode') return activeVSCode;
    if (request === 'net') return fakeNet;
    return originalLoad.call(this, request, parent, isMain);
  };
  delete require.cache[extensionPath];
  const extensionA = require('../extension');
  activeVSCode = projectB.vscode;
  delete require.cache[extensionPath];
  const extensionB = require('../extension');
  Module._load = originalLoad;

  const subscriptionsA = [];
  const subscriptionsB = [];
  extensionA.activate({ subscriptions: subscriptionsA, __codexMicroTestWindowId: 'project-a' });
  extensionB.activate({ subscriptions: subscriptionsB, __codexMicroTestWindowId: 'project-b' });
  t.after(() => {
    for (const disposable of subscriptionsB.reverse()) disposable.dispose?.();
    for (const disposable of subscriptionsA.reverse()) disposable.dispose?.();
    delete require.cache[extensionPath];
  });

  const helper = fakeNet.createConnection(socketPath);
  await new Promise((resolve, reject) => {
    helper.once('connect', resolve);
    helper.once('error', reject);
  });
  const received = [];
  let buffer = '';
  helper.on('data', (chunk) => {
    buffer += chunk.toString();
    let newline;
    while ((newline = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, newline);
      buffer = buffer.slice(newline + 1);
      if (line) received.push(JSON.parse(line));
    }
  });
  const send = (message) => helper.write(`${JSON.stringify(message)}\n`);
  const waitFor = async (predicate) => {
    const deadline = Date.now() + 2000;
    while (Date.now() < deadline) {
      const found = received.find(predicate);
      if (found) return found;
      await new Promise((resolve) => setTimeout(resolve, 5));
    }
    throw new Error(`hub message not received: ${JSON.stringify(received)}`);
  };
  const waitUntil = async (predicate) => {
    const deadline = Date.now() + 2000;
    while (Date.now() < deadline) {
      if (predicate()) return;
      await new Promise((resolve) => setTimeout(resolve, 5));
    }
    throw new Error('hub condition not reached');
  };

  // Allow the second extension host to receive EADDRINUSE and register as peer.
  await new Promise((resolve) => setTimeout(resolve, 20));
  send({ op: 'list' });
  const list = await waitFor((message) => message.type === 'targets'
    && message.targets.some((target) => target.label === 'Project A chat')
    && message.targets.some((target) => target.label === 'Project B chat'));
  const idA = list.targets.find((target) => target.label === 'Project A chat').id;
  const idB = list.targets.find((target) => target.label === 'Project B chat').id;
  assert.notEqual(idA, idB);

  received.length = 0;
  send({ op: 'focus', id: idB });
  const focusAck = await waitFor((message) => message.type === 'ack' && message.op === 'focus');
  assert.equal(focusAck.ok, true);
  assert.ok(projectB.commands.some(([command]) => command === 'workbench.action.openEditorAtIndex1'));
  assert.equal(projectA.commands.some(([command]) => command === 'workbench.action.openEditorAtIndex1'), false);

  received.length = 0;
  send({ op: 'pins', pins: [idA, idB], selected: idB });
  await waitFor((message) => message.type === 'ack' && message.op === 'pins');
  // The shared pin snapshot is broadcast to every window (routing covered by
  // windowHub.test.js), but applying it must NOT natively pin tabs in any
  // window. Native mirroring fought the user's mouse and relied on VS Code's
  // buggy native pin-state (microsoft/vscode#200305); pins now drive only the
  // agent-key LEDs and decorations.
  await new Promise((resolve) => setTimeout(resolve, 40));
  assert.equal(projectA.tab.isPinned, false, 'project A tab is never natively pinned');
  assert.equal(projectB.tab.isPinned, false, 'project B tab is never natively pinned');
  assert.equal(projectA.commands.filter(([command]) => command === 'workbench.action.pinEditor').length, 0);
  assert.equal(projectB.commands.filter(([command]) => command === 'workbench.action.pinEditor').length, 0);

  projectA.focus(false);
  projectB.focus(true);
  await new Promise((resolve) => setTimeout(resolve, 10));
  received.length = 0;
  send({ op: 'new', kind: 'terminal', value: 'claude', label: 'Claude terminal' });
  const newAck = await waitFor((message) => message.type === 'ack' && message.op === 'new');
  assert.equal(newAck.ok, true);
  assert.equal(projectA.terminals.length, 0);
  assert.equal(projectB.terminals.length, 1, 'untargeted NEW is routed to the focused project');

  received.length = 0;
  send({ op: 'list' });
  const afterRouting = await waitFor((message) => message.type === 'targets'
    && message.targets.some((target) => target.id === idA)
    && message.targets.some((target) => target.id === idB));
  assert.ok(afterRouting.targets.some((target) => target.id === idA), 'project A target remains registered');
  assert.ok(afterRouting.targets.some((target) => target.id === idB), 'project B target remains registered');
  helper.destroy();
});
