// AgentMicro — VS Code bridge companion extension.
//
// Opens a local Unix-domain socket that `codexbridge --target vscode` connects
// to. The macropad's key events arrive as small JSON ops; this extension turns
// them into real editor actions:
//
//   • focus a pinned tab / agent terminal          (window.showTextDocument / terminal.show)
//   • approve / reject a Claude proposed diff       (claude-vscode.accept/rejectProposedDiff)
//   • send keys to a Codex / Kimi / aider terminal  (terminal.sendText)
//
// It also streams the current list of pinnable "targets" (the Claude panel,
// every open agent terminal, and open editor tabs) back to the bridge, so the
// iPhone / bridge can pin each of the six agent keys to a specific one.
//
// Nothing here patches Claude or any other extension — it only uses the public
// VS Code command + terminal APIs, so it survives every Claude Code update.
//
// Protocol (newline-delimited JSON, both directions):
//   bridge → ext : {op:"hello"|"list"}
//                  {op:"focus",   id}
//                  {op:"approve", id}          // claude: accept diff · terminal: send terminalApprove
//                  {op:"reject",  id}          // claude: reject diff · terminal: send terminalReject
//                  {op:"submit",  id}          // terminal: send terminalSubmit · claude: focus input
//                  {op:"voice",   id, active}  // exact target's native voice command, when advertised
//                  {op:"send",    id, text}    // raw terminal.sendText
//                  {op:"command", cmd, args?}  // executeCommand escape hatch
//   ext → bridge : {type:"targets", targets:[{id,kind,label,provider,active,nativeVoice}]}
//                  {type:"ack", op, id?, ok, error?}

'use strict';

const vscode = require('vscode');
const net = require('net');
const os = require('os');
const path = require('path');
const fs = require('fs');
const crypto = require('crypto');
const { WindowHub } = require('./windowHub');
const { AgentTabRegistry } = require('./agentTabRegistry');

const CLAUDE_TARGET_ID = 'claude';
const KIMI_TARGET_ID = 'kimi';
const CHATGPT_TARGET_ID = 'chatgpt';

const STATUS_COLORS = {
  idle: 'codexMicro.statusIdle',
  thinking: 'codexMicro.statusWorking',
  working: 'codexMicro.statusWorking',
  running: 'codexMicro.statusWorking',
  complete: 'codexMicro.statusComplete',
  done: 'codexMicro.statusComplete',
  unread: 'codexMicro.statusComplete',
  needs_input: 'codexMicro.statusNeedsInput',
  'awaiting-approval': 'codexMicro.statusNeedsInput',
  'awaiting-response': 'codexMicro.statusNeedsInput',
  approval: 'codexMicro.statusNeedsInput',
  error: 'codexMicro.statusError',
  failed: 'codexMicro.statusError',
};

/** Guess which agent a terminal is running from its title. */
function providerFor(name) {
  const n = (name || '').toLowerCase();
  if (n.includes('codex')) return 'codex';
  if (n.includes('kimi')) return 'kimi';
  if (n.includes('claude')) return 'claude';
  if (n.includes('aider')) return 'aider';
  if (n.includes('gemini')) return 'gemini';
  if (n.includes('opencode')) return 'opencode';
  if (n.includes('cursor')) return 'cursor';
  return 'terminal';
}

function activate(context) {
  const out = vscode.window.createOutputChannel('AgentMicro bridge');
  const log = (m) => out.appendLine(`${new Date().toISOString()} ${m}`);

  // Stable ids for terminals across list rebuilds (terminals reorder/close).
  const termIds = new WeakMap();
  const idFor = (term) => {
    let id = termIds.get(term);
    if (!id) { id = `term:${crypto.randomUUID()}`; termIds.set(term, id); }
    return id;
  };
  // Agent-panel webviews expose no public conversation URI and VS Code may
  // replace their Tab wrappers after focus, title, or native-pin changes. Keep
  // opaque per-window identities through a conservative reconciliation registry
  // so pin reordering can never transfer an id to the adjacent conversation.
  const windowIdentitySeed = context && typeof context.__codexMicroTestWindowId === 'string'
    ? context.__codexMicroTestWindowId
    : `${process.pid}`;
  const windowInstanceId = crypto.createHash('sha256')
    .update(windowIdentitySeed)
    .digest('hex')
    .slice(0, 12);
  const agentTabRegistry = new AgentTabRegistry(windowInstanceId, () => crypto.randomUUID());
  // The macOS bundle id of the app hosting this extension (VS Code, Cursor,
  // VSCodium, Insiders …). macOS sets __CFBundleIdentifier for every .app the
  // process was launched from, so this is reliable without any VS Code API.
  // Every target carries it so the bridge can raise the exact owning app to the
  // front (double-tap an agent key) regardless of which editor/window owns it.
  const appBundleId = (typeof process !== 'undefined'
    && process.env && typeof process.env.__CFBundleIdentifier === 'string'
    && process.env.__CFBundleIdentifier) || null;
  let preferredAgentTabIdentity = null;
  const refreshAgentTabIdentities = (preferred = preferredAgentTabIdentity) => {
    agentTabRegistry.refresh(vscode.window.tabGroups.all, preferred);
  };
  const idForAgentTab = (tab) => {
    let id = agentTabRegistry.idFor(tab);
    if (!id) { refreshAgentTabIdentities(); id = agentTabRegistry.idFor(tab); }
    return id;
  };

  const cfg = () => vscode.workspace.getConfiguration('codexMicro');
  let selectedTargetId = null;
  let pinnedTargetIds = Array(6).fill(null);
  let slotStatuses = Array(6).fill('off');
  const nativeVoiceCommands = new Set();
  const nativeVoiceActiveTargets = new Set();
  // AgentMicro pins are a macropad concept: they live in `pinnedTargetIds`
  // (mirrored from the bridge's PinMap) and drive the agent-key LEDs, the tab
  // color decoration, and the status-bar item. They are deliberately NOT
  // mirrored onto VS Code's own native editor pins. Doing so used to fight the
  // user's mouse — clicking a natively pinned webview tab re-triggered a pin,
  // so it "glitched and stayed on" — and relied on VS Code's native pin-state,
  // which miscalculates whenever exactly one tab is unpinned
  // (microsoft/vscode#200305). Every 15s status heartbeat also re-ran a
  // focus-shuffle (reveal → pin → reveal back) that flickered the editor. The
  // macropad pin mapping is fully independent of native tab pinning, so we drop
  // the native mirror entirely for a glitch-free, reliable pin.

  // Capability discovery prevents provider-name guesses. Claude currently
  // registers this hidden extension-host command; Codex and Kimi expose no
  // equivalent VS Code command, so their targets remain on iPhone speech.
  async function refreshNativeVoiceCapabilities() {
    try {
      const commands = await vscode.commands.getCommands(true);
      const command = 'claude-vscode.toggleDictation';
      const wasAvailable = nativeVoiceCommands.has(command);
      const isAvailable = commands.includes(command);
      if (isAvailable) nativeVoiceCommands.add(command);
      else nativeVoiceCommands.delete(command);
      if (wasAvailable !== isAvailable) broadcastTargets();
    } catch (error) {
      log(`voice capability discovery failed: ${error && error.message}`);
    }
  }
  refreshNativeVoiceCapabilities();

  const decorationEmitter = new vscode.EventEmitter();
  const decorationProvider = {
    onDidChangeFileDecorations: decorationEmitter.event,
    provideFileDecoration(uri) {
      if (!cfg().get('decorateTabs', true)) return undefined;
      const id = `tab:${uri.toString()}`;
      if (id === selectedTargetId) return undefined;
      const slot = pinnedTargetIds.indexOf(id);
      if (slot < 0) return undefined;
      const status = slotStatuses[slot] || 'off';
      const colorId = STATUS_COLORS[status];
      if (!colorId) return undefined;
      return {
        badge: '●',
        tooltip: `AgentMicro agent ${slot + 1}: ${status.replace('_', ' ')}`,
        color: new vscode.ThemeColor(colorId),
        propagate: false,
      };
    },
  };
  const statusItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, 90);
  statusItem.name = 'AgentMicro selected agent';
  statusItem.command = 'codexMicro.showStatus';

  function workspaceCwd(uri) {
    const folder = uri && vscode.workspace.getWorkspaceFolder
      ? vscode.workspace.getWorkspaceFolder(uri)
      : null;
    const fallback = Array.isArray(vscode.workspace.workspaceFolders)
      ? vscode.workspace.workspaceFolders[0]
      : null;
    return (folder && folder.uri && folder.uri.fsPath)
      || (fallback && fallback.uri && fallback.uri.fsPath)
      || null;
  }

  function socketPath() {
    const custom = cfg().get('socketPath');
    if (custom && custom.trim()) return custom.trim();
    // os.tmpdir() honors $TMPDIR (per-user on macOS); the bridge resolves the
    // same value so both ends agree without configuration.
    return path.join(os.tmpdir(), 'codexbridge-vscode.sock');
  }

  // ---- target enumeration --------------------------------------------------

  function buildTargets() {
    refreshAgentTabIdentities();
    const targets = [];
    // `selectedTargetId` is the bridge's last logical selection, not proof that
    // the tab is still active. Mixing it into each target's `active` flag could
    // mark both an old first tab and the actually-visible third tab active; the
    // helper then chose the first one. Only VS Code's live tab state is allowed
    // to advertise an active editor.
    let activeEditorId = null;
    for (const group of vscode.window.tabGroups.all) {
      if (!group.isActive) continue;
      const activeTab = group.tabs.find((candidate) => candidate.isActive);
      if (!activeTab || !activeTab.input) break;
      const input = activeTab.input;
      if (input.uri && input.uri.scheme === 'file') activeEditorId = `tab:${input.uri.toString()}`;
      else if (typeof input.viewType === 'string') activeEditorId = idForAgentTab(activeTab);
      break;
    }

    // Only concrete, independently focusable instances are pinnable. Provider
    // singletons such as "Claude" or "Codex" are launchers, not chats: pinning
    // one would make multiple keys point at whichever conversation happened to
    // be open in that provider. A terminal instance or editor tab has its own
    // UUID/URI and therefore cannot silently retarget another chat.
    for (const term of vscode.window.terminals) {
      targets.push({
        id: idFor(term),
        kind: 'terminal',
        label: term.name || 'terminal',
        provider: providerFor(term.name),
        nativeVoice: false,
        cwd: term.shellIntegration && term.shellIntegration.cwd
          ? term.shellIntegration.cwd.fsPath
          : workspaceCwd(null),
        active: false,
        selected: idFor(term) === selectedTargetId,
      });
    }

    // Open editor tabs (text documents) so any tab can be pinned/focused.
    for (const group of vscode.window.tabGroups.all) {
      for (let index = 0; index < group.tabs.length; index += 1) {
        const tab = group.tabs[index];
        const input = tab.input;
        if (input && input.uri && input.uri.scheme === 'file') {
          const uri = input.uri.toString();
          targets.push({
            id: `tab:${uri}`,
            kind: 'editor',
            label: tab.label,
            provider: 'editor',
            nativeVoice: false,
            cwd: workspaceCwd(input.uri),
            active: `tab:${uri}` === activeEditorId,
            selected: `tab:${uri}` === selectedTargetId,
          });
        } else if (input && typeof input.viewType === 'string') {
          const id = idForAgentTab(tab);
          const provider = providerFor(`${tab.label} ${input.viewType}`);
          targets.push({
            id,
            kind: 'agent-editor',
            label: tab.label,
            provider,
            nativeVoice: provider === 'claude'
              && nativeVoiceCommands.has('claude-vscode.toggleDictation'),
            cwd: workspaceCwd(null),
            active: id === activeEditorId,
            selected: id === selectedTargetId,
            group: group.viewColumn,
            index,
          });
        }
      }
    }
    // Tag every target with the owning app's bundle id so the bridge can raise
    // this exact editor app to the front on a double-tap.
    return appBundleId ? targets.map((target) => ({ ...target, appBundleId })) : targets;
  }

  function findTerminalById(id) {
    for (const term of vscode.window.terminals) {
      if (idFor(term) === id) return term;
    }
    return null;
  }

  // ---- op handlers ---------------------------------------------------------

  async function run(cmd, ...args) {
    try {
      await vscode.commands.executeCommand(cmd, ...args);
      return true;
    } catch (err) {
      log(`command ${cmd} failed: ${err && err.message}`);
      return false;
    }
  }

  async function focusClaude() {
    // Reveal the side-bar panel, then move keyboard focus into its input.
    await run('claude-vscode.sidebar.open');
    return run('claude-vscode.focus');
  }

  async function focusLogicalTarget(id) {
    if (id === CLAUDE_TARGET_ID) return focusClaude();
    if (id === KIMI_TARGET_ID) {
      await run('kimi.openInSideBar');
      return run('kimi.focusInput');
    }
    if (id === CHATGPT_TARGET_ID) return run('chatgpt.openSidebar');
    return false;
  }

  async function focusAgentEditor(id) {
    const target = buildTargets().find((item) => item.id === id);
    if (!target || target.kind !== 'agent-editor' || target.index >= 9) return false;
    const groupCommands = [
      null,
      'workbench.action.focusFirstGroup',
      'workbench.action.focusSecondGroup',
      'workbench.action.focusThirdGroup',
      'workbench.action.focusFourthGroup',
      'workbench.action.focusFifthGroup',
      'workbench.action.focusSixthGroup',
      'workbench.action.focusSeventhGroup',
      'workbench.action.focusEighthGroup',
    ];
    const groupCommand = groupCommands[target.group];
    if (groupCommand) await run(groupCommand);
    return run(`workbench.action.openEditorAtIndex${target.index + 1}`);
  }

  function setSelected(id) {
    if (!id) return;
    selectedTargetId = id;
    updateStatusItem();
    decorationEmitter.fire(undefined);
    broadcast({ type: 'selection', id });
    broadcastTargets();
  }

  async function reveal(id) {
    if ([CLAUDE_TARGET_ID, KIMI_TARGET_ID, CHATGPT_TARGET_ID].includes(id)) {
      return focusLogicalTarget(id);
    }
    const term = findTerminalById(id);
    if (term) { term.show(false); return true; }
    if (id && id.startsWith('tab:')) {
      const uri = vscode.Uri.parse(id.slice(4));
      try {
        const doc = await vscode.workspace.openTextDocument(uri);
        await vscode.window.showTextDocument(doc, { preview: false });
        return true;
      } catch (err) {
        log(`focus tab failed: ${err && err.message}`);
        return false;
      }
    }
    if (id && id.startsWith('view:')) {
      return focusAgentEditor(id);
    }
    return false;
  }

  async function focus(id) {
    const ok = await reveal(id);
    if (ok) setSelected(id);
    return ok;
  }

  async function runForAgentTab(id, command) {
    const restoreId = selectedTargetId;
    if (!await reveal(id)) return false;
    const ok = await run(command);
    if (restoreId && restoreId !== id) await reveal(restoreId);
    return ok;
  }

  async function setNativeVoice(id, active) {
    const target = buildTargets().find((item) => item.id === id);
    if (!target || target.kind !== 'agent-editor' || !target.nativeVoice) return false;
    const command = target.provider === 'claude' ? 'claude-vscode.toggleDictation' : null;
    if (!command || !nativeVoiceCommands.has(command)) return false;

    const isActive = nativeVoiceActiveTargets.has(id);
    if (Boolean(active) === isActive) return true;

    // Release can arrive after the user has switched agent keys. Stop the
    // original concrete chat, then restore the newly selected target.
    const restoreId = selectedTargetId;
    if (!await focus(id)) return false;
    const ok = await run(command);
    if (ok) {
      if (active) nativeVoiceActiveTargets.add(id);
      else nativeVoiceActiveTargets.delete(id);
    }
    if (!active && restoreId && restoreId !== id) await focus(restoreId);
    return ok;
  }

  async function approve(id) {
    if (id === CLAUDE_TARGET_ID) {
      // Try both command namespaces the extension has shipped.
      return (await run('claude-vscode.acceptProposedDiff')) ||
             (await run('claude-code.acceptProposedDiff'));
    }
    const term = findTerminalById(id);
    if (term) { term.show(false); term.sendText(cfg().get('terminalApprove'), false); return true; }
    return false;
  }

  async function reject(id) {
    if (id === CLAUDE_TARGET_ID) {
      return (await run('claude-vscode.rejectProposedDiff')) ||
             (await run('claude-code.rejectProposedDiff'));
    }
    const term = findTerminalById(id);
    if (term) { term.show(false); term.sendText(cfg().get('terminalReject'), false); return true; }
    return false;
  }

  async function submit(id) {
    const term = findTerminalById(id);
    if (term) { term.show(false); term.sendText(cfg().get('terminalSubmit'), false); return true; }
    // The Claude webview owns Enter; no public submit command exists, so the
    // best we can do is make sure its input is focused.
    if ([CLAUDE_TARGET_ID, KIMI_TARGET_ID, CHATGPT_TARGET_ID].includes(id) || (id && id.startsWith('view:'))) {
      if (!(await focus(id))) return false;
      return run('type', { text: '\n' });
    }
    return false;
  }

  async function sendText(id, text) {
    const term = findTerminalById(id);
    if (term && typeof text === 'string') { term.show(false); term.sendText(text, false); return true; }
    return false;
  }

  async function insertText(id, text) {
    if (typeof text !== 'string' || !text) return false;
    const targetId = id || selectedTargetId;
    const term = findTerminalById(targetId);
    if (term) { term.show(false); term.sendText(text, false); setSelected(targetId); return true; }
    if (!targetId || !(await focus(targetId))) return false;
    // `type` targets the currently focused control, including extension
    // webviews, without replacing the user's clipboard.
    return run('type', { text });
  }

  // Map a launcher command id back to its provider's logical target, so NEW can
  // still select the agent when it opens in the sidebar instead of as a tab.
  function logicalTargetForCommand(value) {
    const v = (value || '').toLowerCase();
    if (v.includes('claude')) return CLAUDE_TARGET_ID;
    if (v.includes('kimi')) return KIMI_TARGET_ID;
    if (v.includes('chatgpt') || v.includes('codex') || v.includes('openai')) return CHATGPT_TARGET_ID;
    return null;
  }

  async function createSession(kind, value, label) {
    if (kind === 'terminal') {
      const shortName = (label || value || 'Agent').replace(/ terminal$/i, '');
      const term = vscode.window.createTerminal({ name: shortName, iconPath: new vscode.ThemeIcon('terminal') });
      term.show(false);
      term.sendText(value, true);
      const id = idFor(term);
      setSelected(id);
      return id;
    }
    if (!value || !(await run(value))) return null;
    // The contributed command may create an independently pinnable editor tab,
    // or reveal a sidebar conversation. Editor tabs can take a moment to appear,
    // so poll briefly (up to ~1s) for a NEW agent-editor tab before deciding,
    // rather than checking a single 180 ms snapshot that races the command.
    const priorEditorIds = new Set(
      buildTargets().filter((t) => t.kind === 'agent-editor').map((t) => t.id)
    );
    let opened = null;
    for (let attempt = 0; attempt < 8 && !opened; attempt += 1) {
      await new Promise((resolve) => setTimeout(resolve, 120));
      const editors = buildTargets().filter((t) => t.kind === 'agent-editor');
      opened = editors.find((t) => t.active && !priorEditorIds.has(t.id))
        || editors.find((t) => !priorEditorIds.has(t.id))
        || null;
    }
    if (opened) {
      setSelected(opened.id);
      return opened.id;
    }
    // No new editor tab — the agent opened in the sidebar (Claude Code's default
    // conversation panel, ChatGPT sidebar, etc.). The command already opened it;
    // select the provider's logical target so NEW reports success and the agent
    // keys drive it, instead of returning failure for a conversation that is in
    // fact open.
    const logicalId = logicalTargetForCommand(value);
    if (logicalId) {
      await focusLogicalTarget(logicalId);
      setSelected(logicalId);
      broadcastTargets();
      return logicalId;
    }
    log(`new command ${value} opened no independently pinnable editor tab`);
    broadcastTargets();
    return null;
  }

  function applyPins(msg) {
    pinnedTargetIds = Array.from({ length: 6 }, (_, index) =>
      Array.isArray(msg.pins) && typeof msg.pins[index] === 'string' ? msg.pins[index] : null);
    // The hub broadcasts one pin/status snapshot to every VS Code window. Only
    // the window that owns the selected id may adopt it as its local selection;
    // peers must not replace their active tab with another project's id.
    if (typeof msg.selected === 'string'
        && buildTargets().some((target) => target.id === msg.selected)) {
      selectedTargetId = msg.selected;
    }
    updateStatusItem();
    // Fire decorations so pinned FILE tabs get their status color. Webview
    // (agent) tabs cannot be decorated by a third-party extension and are
    // intentionally left untouched — their live state shows on the agent-key
    // LED and in the status-bar item instead. We never call pinEditor here.
    decorationEmitter.fire(undefined);
  }

  async function applyStatus(msg) {
    await applyPins(msg);
    slotStatuses = Array.from({ length: 6 }, (_, index) => {
      const entry = Array.isArray(msg.slots) ? msg.slots.find((slot) => slot && slot.id === index) : null;
      return entry && typeof entry.status === 'string' ? entry.status : 'off';
    });
    updateStatusItem();
    decorationEmitter.fire(undefined);
  }

  function updateStatusItem() {
    const targets = buildTargets();
    const selected = targets.find((target) => target.id === selectedTargetId);
    if (!selected) { statusItem.hide(); return; }
    const slot = pinnedTargetIds.indexOf(selectedTargetId);
    const status = slot >= 0 ? slotStatuses[slot] : 'off';
    statusItem.text = `$(remote) ${selected.label}${slot >= 0 ? ` · ${slot + 1}` : ''}`;
    statusItem.tooltip = `AgentMicro selected target${slot >= 0 ? `, pinned to agent key ${slot + 1}` : ''}`;
    statusItem.color = STATUS_COLORS[status] ? new vscode.ThemeColor(STATUS_COLORS[status]) : undefined;
    statusItem.show();
  }

  async function handleOp(msg, reply) {
    switch (msg.op) {
      case 'hello':
      case 'list':
        await refreshNativeVoiceCapabilities();
        reply({ type: 'targets', targets: buildTargets() });
        return;
      case 'focus':
        reply({ type: 'ack', op: msg.op, id: msg.id, ok: await focus(msg.id) });
        return;
      case 'approve':
        reply({ type: 'ack', op: msg.op, id: msg.id, ok: await approve(msg.id) });
        return;
      case 'reject':
        reply({ type: 'ack', op: msg.op, id: msg.id, ok: await reject(msg.id) });
        return;
      case 'submit':
        reply({ type: 'ack', op: msg.op, id: msg.id, ok: await submit(msg.id) });
        return;
      case 'send':
        reply({ type: 'ack', op: msg.op, id: msg.id, ok: await sendText(msg.id, msg.text) });
        return;
      case 'insert':
      {
        // Keep dictation bound to the target captured on touch-down. If the
        // user moved to another agent while recognition finished, briefly
        // focus the recorded target for webview typing, submit in order, then
        // restore the agent they are currently using.
        const targetId = msg.id || selectedTargetId;
        const restoreId = selectedTargetId;
        const inserted = await insertText(targetId, msg.text);
        const submitted = inserted && (!msg.submit || await submit(targetId));
        if (restoreId && restoreId !== targetId) await focus(restoreId);
        reply({
          type: 'ack', op: msg.op, id: targetId, ok: submitted,
          submitted: Boolean(msg.submit),
        });
        return;
      }
      case 'voice':
        reply({
          type: 'ack', op: msg.op, id: msg.id,
          ok: await setNativeVoice(msg.id, Boolean(msg.active)),
          active: Boolean(msg.active),
        });
        return;
      case 'new': {
        const id = await createSession(msg.kind, msg.value, msg.label);
        reply({ type: 'ack', op: msg.op, id, ok: Boolean(id) });
        return;
      }
      case 'pins':
        await applyPins(msg);
        reply({ type: 'ack', op: msg.op, ok: true });
        return;
      case 'status':
        await applyStatus(msg);
        reply({ type: 'ack', op: msg.op, ok: true });
        return;
      case 'command':
        reply({ type: 'ack', op: msg.op, ok: await run(msg.cmd, ...(msg.args || [])) });
        return;
      default:
        reply({ type: 'ack', op: msg.op, ok: false, error: 'unknown op' });
    }
  }

  // ---- multi-window socket hub ---------------------------------------------

  // Exactly one extension host owns the helper-facing path. Every other VS Code
  // window stays connected to it as a peer instead of stealing the path. The
  // owner aggregates all concrete targets and routes each id back to its owning
  // project, so pins remain valid while the user moves between windows.
  const clients = new Set();
  const clientRoles = new Map();
  const peerSocketsByWindow = new Map();
  const pendingPeerRoutes = new Map();
  let server = null;
  let ownsSocket = false;
  let hub = null;
  let peerSocket = null;
  let peerConnected = false;
  let recoveryTimer = null;

  const bridgeClientCount = () => Array.from(clientRoles.values())
    .filter((entry) => entry && entry.role === 'bridge').length;
  const peerWindowCount = () => peerSocketsByWindow.size;
  const writeObject = (sock, object) => {
    try { sock.write(`${JSON.stringify(object)}\n`); return true; } catch (_) { return false; }
  };
  const bridgeSockets = () => Array.from(clients).filter((sock) => {
    const info = clientRoles.get(sock);
    return info && info.role === 'bridge';
  });

  function updateLocalHubState(focused = Boolean(vscode.window.state && vscode.window.state.focused)) {
    if (!hub) return;
    hub.updateWindow(windowInstanceId, { targets: buildTargets(), focused });
  }

  function broadcastToBridges(object) {
    for (const sock of bridgeSockets()) writeObject(sock, object);
  }

  function publishAggregateTargets() {
    if (!ownsSocket || !hub) return;
    updateLocalHubState();
    broadcastToBridges({ type: 'targets', targets: hub.targets() });
  }

  function sendPeerState(extra = {}, focused = Boolean(vscode.window.state && vscode.window.state.focused)) {
    if (!peerConnected || !peerSocket) return;
    writeObject(peerSocket, {
      op: 'window-state',
      windowId: windowInstanceId,
      focused,
      targets: buildTargets(),
      ...extra,
    });
  }

  function broadcast(object) {
    if (ownsSocket) {
      updateLocalHubState();
      broadcastToBridges(object);
    } else {
      sendPeerState({ event: object });
    }
  }

  function broadcastTargets() {
    if (ownsSocket) publishAggregateTargets();
    else sendPeerState();
  }

  function dispatchToPeer(windowId, message, bridgeSock, reply) {
    const sock = peerSocketsByWindow.get(windowId);
    if (!sock) {
      reply({ type: 'ack', op: message.op, id: message.id, ok: false, error: 'target window disconnected' });
      return;
    }
    const requestId = crypto.randomUUID();
    const timeout = setTimeout(() => {
      const pending = pendingPeerRoutes.get(requestId);
      if (!pending) return;
      pendingPeerRoutes.delete(requestId);
      pending.reply({
        type: 'ack', op: message.op, id: message.id, ok: false,
        error: 'target window did not acknowledge operation',
      });
    }, 3000);
    pendingPeerRoutes.set(requestId, { bridgeSock, reply, timeout });
    if (!writeObject(sock, { op: 'window-dispatch', requestId, message })) {
      clearTimeout(timeout);
      pendingPeerRoutes.delete(requestId);
      reply({ type: 'ack', op: message.op, id: message.id, ok: false, error: 'target window write failed' });
    }
  }

  async function routeBridgeMessage(message, bridgeSock, reply) {
    if (!hub) {
      reply({ type: 'ack', op: message.op, ok: false, error: 'window hub unavailable' });
      return;
    }
    updateLocalHubState();
    if (message.op === 'hello' || message.op === 'list') {
      await refreshNativeVoiceCapabilities();
      for (const sock of peerSocketsByWindow.values()) writeObject(sock, { op: 'window-state-request' });
      reply({ type: 'targets', targets: hub.targets() });
      return;
    }

    const route = hub.routeFor(message);
    if (route === '*') {
      // Pins and status contain assignments for several projects. Apply the
      // same snapshot in every window; each window touches only ids it owns.
      await handleOp(message, () => {});
      for (const sock of peerSocketsByWindow.values()) {
        writeObject(sock, { op: 'window-dispatch', message });
      }
      reply({ type: 'ack', op: message.op, ok: true });
      return;
    }
    if (!route || route === windowInstanceId) {
      await handleOp(message, reply);
      return;
    }
    dispatchToPeer(route, message, bridgeSock, reply);
  }

  function acceptHubClient(sock) {
    clients.add(sock);
    clientRoles.set(sock, { role: 'pending', windowId: null });
    writeObject(sock, { type: 'targets', targets: hub ? hub.targets() : buildTargets() });

    let buffer = '';
    sock.on('data', (chunk) => {
      buffer += chunk.toString('utf8');
      let newline;
      while ((newline = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, newline).trim();
        buffer = buffer.slice(newline + 1);
        if (!line) continue;
        let message;
        try { message = JSON.parse(line); } catch (_) { continue; }
        if (!message || typeof message.op !== 'string') continue;
        const reply = (object) => writeObject(sock, object);

        if (message.op === 'register-window' || message.op === 'window-state') {
          const windowId = message.windowId;
          if (typeof windowId !== 'string' || !windowId) continue;
          const old = peerSocketsByWindow.get(windowId);
          if (old && old !== sock) { try { old.destroy(); } catch (_) {} }
          peerSocketsByWindow.set(windowId, sock);
          clientRoles.set(sock, { role: 'peer', windowId });
          hub.updateWindow(windowId, {
            targets: message.targets,
            focused: Boolean(message.focused),
          });
          if (message.event) broadcastToBridges(message.event);
          if (message.op === 'register-window') reply({ type: 'ack', op: message.op, ok: true });
          publishAggregateTargets();
          continue;
        }
        if (message.op === 'unregister-window') {
          const info = clientRoles.get(sock);
          if (info && info.role === 'peer') hub.removeWindow(info.windowId);
          try { sock.end(); } catch (_) {}
          publishAggregateTargets();
          continue;
        }
        if (message.op === 'window-reply') {
          const pending = pendingPeerRoutes.get(message.requestId);
          if (!pending) continue;
          clearTimeout(pending.timeout);
          pendingPeerRoutes.delete(message.requestId);
          pending.reply(message.payload || { type: 'ack', op: 'unknown', ok: false });
          continue;
        }

        const info = clientRoles.get(sock);
        if (!info || info.role !== 'bridge') {
          clientRoles.set(sock, { role: 'bridge', windowId: null });
          log(`bridge connected (${bridgeClientCount()})`);
        }
        routeBridgeMessage(message, sock, reply).catch((error) => {
          log(`op error: ${error && error.message}`);
          reply({ type: 'ack', op: message.op, ok: false, error: error && error.message });
        });
      }
    });

    let dropped = false;
    const drop = () => {
      if (dropped) return;
      dropped = true;
      const info = clientRoles.get(sock);
      clients.delete(sock);
      clientRoles.delete(sock);
      if (info && info.role === 'peer' && peerSocketsByWindow.get(info.windowId) === sock) {
        peerSocketsByWindow.delete(info.windowId);
        if (hub) hub.removeWindow(info.windowId);
        publishAggregateTargets();
        log(`VS Code peer disconnected (${peerWindowCount()} remaining)`);
      } else if (info && info.role === 'bridge') {
        log(`bridge disconnected (${bridgeClientCount()})`);
      }
    };
    sock.on('error', drop);
    sock.on('close', drop);
  }

  function scheduleRecovery() {
    if (recoveryTimer || ownsSocket || server || peerSocket) return;
    // Stable per-window jitter prevents every surviving extension host from
    // winning the orphaned socket at once after the owner window closes.
    const jitter = parseInt(windowInstanceId.slice(0, 4), 16) % 140;
    recoveryTimer = setTimeout(() => {
      recoveryTimer = null;
      startServer();
    }, 80 + jitter);
  }

  function connectToHub() {
    if (ownsSocket || server || peerSocket) return;
    const candidate = net.createConnection(socketPath());
    peerSocket = candidate;
    let buffer = '';
    let failedWith = null;
    candidate.on('connect', () => {
      peerConnected = true;
      writeObject(candidate, {
        op: 'register-window',
        windowId: windowInstanceId,
        focused: Boolean(vscode.window.state && vscode.window.state.focused),
        targets: buildTargets(),
      });
      log(`registered this project with the VS Code window hub at ${socketPath()}`);
    });
    candidate.on('data', (chunk) => {
      buffer += chunk.toString('utf8');
      let newline;
      while ((newline = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, newline).trim();
        buffer = buffer.slice(newline + 1);
        if (!line) continue;
        let message;
        try { message = JSON.parse(line); } catch (_) { continue; }
        if (!message || typeof message.op !== 'string') continue;
        if (message.op === 'window-state-request') {
          sendPeerState();
          continue;
        }
        if (message.op === 'window-dispatch' && message.message) {
          handleOp(message.message, (payload) => {
            if (message.requestId) {
              writeObject(candidate, { op: 'window-reply', requestId: message.requestId, payload });
            }
          }).catch((error) => {
            if (message.requestId) {
              writeObject(candidate, {
                op: 'window-reply', requestId: message.requestId,
                payload: { type: 'ack', op: message.message.op, ok: false, error: error && error.message },
              });
            }
          });
        }
      }
    });
    candidate.on('error', (error) => { failedWith = error; });
    candidate.on('close', () => {
      if (peerSocket === candidate) peerSocket = null;
      peerConnected = false;
      if (failedWith && failedWith.code === 'ECONNREFUSED') {
        try { fs.unlinkSync(socketPath()); } catch (_) {}
      }
      scheduleRecovery();
    });
  }

  function startServer() {
    if (server || ownsSocket || peerSocket) return;
    const sockPath = socketPath();
    const candidate = net.createServer(acceptHubClient);
    server = candidate;
    candidate.on('error', (error) => {
      if (server === candidate) server = null;
      ownsSocket = false;
      hub = null;
      try { candidate.close(); } catch (_) {}
      if (error && error.code === 'EADDRINUSE') {
        connectToHub();
      } else {
        log(`window hub server error: ${error && error.message}`);
        scheduleRecovery();
      }
    });
    candidate.listen(sockPath, () => {
      if (server !== candidate) return;
      ownsSocket = true;
      hub = new WindowHub(windowInstanceId);
      updateLocalHubState();
      log(`listening on ${sockPath} (multi-window hub)`);
    });
  }

  startServer();
  const ownershipWatchdog = setInterval(() => {
    if (!ownsSocket && !server && !peerSocket) scheduleRecovery();
  }, 3000);

  // The id of the agent/webview tab that is genuinely active right now, found by
  // scanning tab state directly rather than via buildTargets()' `active` flag
  // (which also reports the previously-selected tab as active and would resolve
  // to the stale selection). Returns null when the active tab is not an agent
  // webview.
  function activeAgentEditorId() {
    refreshAgentTabIdentities();
    for (const group of vscode.window.tabGroups.all) {
      if (!group.isActive) continue;
      const tab = group.tabs.find((t) => t.isActive);
      if (tab && tab.input && typeof tab.input.viewType === 'string') return idForAgentTab(tab);
      return null;
    }
    return null;
  }

  // Rebroadcast the target list whenever the pinnable set changes.
  const subs = [
    vscode.window.onDidOpenTerminal(broadcastTargets),
    vscode.window.onDidCloseTerminal(broadcastTargets),
    vscode.window.onDidChangeActiveTerminal((terminal) => {
      if (terminal) setSelected(idFor(terminal));
      else broadcastTargets();
    }),
    vscode.window.onDidChangeActiveTextEditor((editor) => {
      if (editor && editor.document.uri.scheme === 'file') { setSelected(`tab:${editor.document.uri.toString()}`); return; }
      // Left a file editor — usually onto an agent/webview tab (a Claude
      // conversation, etc.), which raises no active-text-editor event. Move the
      // selection onto that tab so PIN and the agent keys act on the tab the
      // user is actually viewing instead of the previously-open file tab.
      const agentId = activeAgentEditorId();
      if (agentId && agentId !== selectedTargetId) setSelected(agentId);
      else broadcastTargets();
    }),
    vscode.window.tabGroups.onDidChangeTabs(() => {
      refreshNativeVoiceCapabilities();
      const agentId = activeAgentEditorId();
      if (agentId && agentId !== selectedTargetId) setSelected(agentId);
      else broadcastTargets();
    }),
    vscode.window.onDidChangeWindowState((state) => {
      if (ownsSocket && hub) {
        hub.updateWindow(windowInstanceId, { targets: buildTargets(), focused: state.focused });
        broadcastToBridges({ type: 'targets', targets: hub.targets() });
      } else {
        sendPeerState({}, state.focused);
      }
    }),
    vscode.commands.registerCommand('codexMicro.showStatus', () => {
      out.show(true);
      const count = bridgeClientCount();
      const windowCount = ownsSocket && hub ? hub.windows.size : 1;
      const targetCount = ownsSocket && hub ? hub.targets().length : buildTargets().length;
      log(`socket=${socketPath()} hubOwner=${ownsSocket} clients=${count} windows=${windowCount} targets=${targetCount}`);
      vscode.window.showInformationMessage(
        ownsSocket
          ? `AgentMicro bridge: ${count} helper client(s), ${windowCount} VS Code window(s), ${targetCount} concrete targets.`
          : `AgentMicro bridge: this project is registered with the multi-window hub. Socket ${socketPath()}`);
    }),
  ];
  subs.push(vscode.window.registerFileDecorationProvider(decorationProvider));
  context.subscriptions.push(...subs, {
    dispose() {
      if (recoveryTimer) clearTimeout(recoveryTimer);
      clearInterval(ownershipWatchdog);
      for (const pending of pendingPeerRoutes.values()) clearTimeout(pending.timeout);
      pendingPeerRoutes.clear();
      if (peerSocket) {
        if (peerConnected) writeObject(peerSocket, { op: 'unregister-window', windowId: windowInstanceId });
        try { peerSocket.destroy(); } catch (_) {}
      }
      for (const sock of clients) { try { sock.destroy(); } catch (_) {} }
      if (server) { try { server.close(); } catch (_) {} }
      if (ownsSocket) { try { fs.unlinkSync(socketPath()); } catch (_) {} }
      decorationEmitter.dispose();
      statusItem.dispose();
      out.dispose();
    },
  });

  log('activated');
}

function deactivate() {}

module.exports = { activate, deactivate };
