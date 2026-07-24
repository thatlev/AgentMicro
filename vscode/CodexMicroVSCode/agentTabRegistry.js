'use strict';

/**
 * Maintains opaque, window-scoped identities for third-party webview tabs.
 * VS Code exposes no conversation URI for TabInputWebview and may replace Tab
 * objects when focus/pin/title changes. Reconciliation combines exact objects,
 * resource URI, unique title, a native-pin active hint, and stable position.
 * When identity is genuinely ambiguous it expires rather than jumping projects.
 */
class AgentTabRegistry {
  constructor(windowId, createToken) {
    this.windowId = windowId;
    this.createToken = createToken;
    this.records = new Map();
    this.idsByTab = new WeakMap();
  }

  refresh(groups, preferredActiveId = null) {
    const entries = [];
    for (const group of groups || []) {
      for (let index = 0; index < group.tabs.length; index += 1) {
        const tab = group.tabs[index];
        const input = tab && tab.input;
        if (!input || typeof input.viewType !== 'string') continue;
        entries.push({
          tab,
          input,
          viewType: input.viewType,
          uri: input.uri && typeof input.uri.toString === 'function' ? input.uri.toString() : null,
          label: typeof tab.label === 'string' ? tab.label : '',
          group: group.viewColumn,
          index,
          active: Boolean(group.isActive && tab.isActive),
        });
      }
    }

    const previous = Array.from(this.records.entries()).map(([id, record]) => ({ id, ...record }));
    const unusedPrevious = new Set(previous.map((record) => record.id));
    const assigned = new Map();
    const assign = (entry, record) => {
      if (!entry || !record || assigned.has(entry) || !unusedPrevious.has(record.id)) return false;
      assigned.set(entry, record.id);
      unusedPrevious.delete(record.id);
      return true;
    };

    // The API often preserves either Tab or TabInput identity even when the
    // other wrapper changes.
    for (const entry of entries) {
      assign(entry, previous.find((record) => unusedPrevious.has(record.id)
        && (record.tab === entry.tab || record.input === entry.input)));
    }

    // Custom editors with a resource URI are unambiguous.
    for (const entry of entries.filter((item) => !assigned.has(item) && item.uri)) {
      assign(entry, previous.find((record) => unusedPrevious.has(record.id)
        && record.viewType === entry.viewType && record.uri === entry.uri));
    }

    // Conversation titles survive pin reordering/closing siblings in the common
    // case. Only use a title when it is unique on both sides.
    for (const entry of entries.filter((item) => !assigned.has(item))) {
      const currentMatches = entries.filter((candidate) => !assigned.has(candidate)
        && candidate.viewType === entry.viewType && candidate.label === entry.label);
      const oldMatches = previous.filter((record) => unusedPrevious.has(record.id)
        && record.viewType === entry.viewType && record.label === entry.label);
      if (currentMatches.length === 1 && oldMatches.length === 1) assign(entry, oldMatches[0]);
    }

    // Native pin/unpin can move one of several identically titled tabs. The
    // caller supplies the id it just focused; the still-active tab keeps it.
    if (preferredActiveId && unusedPrevious.has(preferredActiveId)) {
      const record = previous.find((candidate) => candidate.id === preferredActiveId);
      const activeMatches = entries.filter((entry) => !assigned.has(entry) && entry.active
        && record && entry.viewType === record.viewType);
      if (activeMatches.length === 1) assign(activeMatches[0], record);
    }

    // A title can change after the first prompt. With no reorder, group/index is
    // the strongest remaining identity and preserves that conversation pin.
    for (const entry of entries.filter((item) => !assigned.has(item))) {
      assign(entry, previous.find((record) => unusedPrevious.has(record.id)
        && record.viewType === entry.viewType && record.group === entry.group && record.index === entry.index));
    }

    // Pair only the final same-view-type remainder in display order. This keeps
    // duplicate default-title tabs stable across wrapper-object churn.
    for (const entry of entries.filter((item) => !assigned.has(item))) {
      assign(entry, previous.find((record) => unusedPrevious.has(record.id)
        && record.viewType === entry.viewType));
    }

    const next = new Map();
    const nextIDsByTab = new WeakMap();
    for (const entry of entries) {
      const id = assigned.get(entry) || `view:${this.windowId}:${this.createToken()}`;
      next.set(id, entry);
      nextIDsByTab.set(entry.tab, id);
    }
    this.records = next;
    this.idsByTab = nextIDsByTab;
  }

  idFor(tab) { return this.idsByTab.get(tab) || null; }
}

module.exports = { AgentTabRegistry };
