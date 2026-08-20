'use strict';

/**
 * Pure state/routing core for the extension-owned multi-window hub.
 *
 * One extension host owns the public Unix socket. Every other VS Code window
 * registers as a persistent peer. The helper still sees its original protocol:
 * one target list and one place to send operations. This class makes that list
 * an aggregate and maps concrete target ids back to the window that owns them.
 */
class WindowHub {
  constructor(localWindowId) {
    this.localWindowId = localWindowId;
    this.windows = new Map();
    this.focusedWindowId = localWindowId;
    this.updateWindow(localWindowId, { targets: [], focused: true });
  }

  updateWindow(windowId, update = {}) {
    if (typeof windowId !== 'string' || !windowId) return;
    const previous = this.windows.get(windowId) || { targets: [], focused: false };
    const next = {
      targets: Array.isArray(update.targets) ? update.targets : previous.targets,
      focused: typeof update.focused === 'boolean' ? update.focused : previous.focused,
    };
    this.windows.set(windowId, next);
    // Keep the most recently focused VS Code project authoritative even while
    // focus temporarily leaves VS Code for the iPhone or another Mac app.
    if (next.focused) this.focusedWindowId = windowId;
  }

  removeWindow(windowId) {
    this.windows.delete(windowId);
    if (this.focusedWindowId === windowId) {
      this.focusedWindowId = this.windows.has(this.localWindowId)
        ? this.localWindowId
        : (this.windows.keys().next().value || null);
    }
  }

  targets() {
    const result = [];
    for (const [windowId, state] of this.windows) {
      for (const target of state.targets) {
        if (!target || typeof target.id !== 'string') continue;
        result.push({
          ...target,
          windowId,
          // Several windows each have an active editor. The helper must see one
          // active target: the editor in the most recently focused project.
          active: windowId === this.focusedWindowId && target.active === true,
        });
      }
    }
    return result;
  }

  ownerOf(targetId) {
    if (typeof targetId !== 'string' || !targetId) return null;
    for (const [windowId, state] of this.windows) {
      if (state.targets.some((target) => target && target.id === targetId)) return windowId;
    }
    return null;
  }

  /**
   * Returns a window id, '*' for every window, or null for hub-local ops.
   */
  routeFor(message) {
    if (!message || typeof message.op !== 'string') return null;
    if (message.op === 'hello' || message.op === 'list') return null;
    if (message.op === 'pins' || message.op === 'status') return '*';
    if (typeof message.id === 'string') {
      return this.ownerOf(message.id) || this.focusedWindowId || this.localWindowId;
    }
    return this.focusedWindowId || this.localWindowId;
  }
}

module.exports = { WindowHub };
