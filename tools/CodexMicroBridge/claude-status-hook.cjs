#!/usr/bin/env node
'use strict';

// Codex Micro — Claude Code status feed.
//
// Claude Code fires lifecycle hooks; this tiny hook translates them into the
// SidePulse status file the Codex Micro bridge already reads
// (~/Library/Caches/SidePulse/status.json), so a pinned Claude conversation's
// agent key lights BLUE while it is working, AMBER when it needs input, and
// GREEN when it completes — instead of always white.
//
// It is deliberately minimal and defensive: it never blocks Claude, never
// prints to stdout, and always exits 0 even on error, so it cannot disrupt a
// session. Registered additively for UserPromptSubmit / Stop / Notification in
// ~/.claude/settings.json alongside any other hooks.
//
// Granularity is per workspace (cwd) + provider, because a hook cannot see the
// VS Code webview tab id. The bridge matches a pinned Claude target to the
// most-recently-updated Claude session in the same workspace.

const fs = require('fs');
const path = require('path');
const os = require('os');

function statusForEvent(event) {
  switch (event) {
    case 'UserPromptSubmit':
    case 'PreToolUse':
    case 'PostToolUse':
      return 'working';
    case 'Notification':
      return 'needs_input';
    case 'Stop':
    case 'SubagentStop':
      return 'complete';
    default:
      return null;
  }
}

function main() {
  let raw = '';
  try { raw = fs.readFileSync(0, 'utf8'); } catch (_) { /* no stdin */ }
  let input = {};
  try { input = JSON.parse(raw || '{}') || {}; } catch (_) { input = {}; }

  const event = input.hook_event_name || process.argv[2] || '';
  const status = statusForEvent(event);
  if (!status) return; // event we don't track — leave the file untouched

  const sessionId = String(input.session_id || input.sessionId || 'claude');
  const cwd = input.cwd || process.cwd();

  const dir = path.join(os.homedir(), 'Library', 'Caches', 'SidePulse');
  const file = path.join(dir, 'status.json');
  try { fs.mkdirSync(dir, { recursive: true }); } catch (_) { /* ignore */ }

  let data = { sessions: {} };
  try {
    const parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
    if (parsed && typeof parsed.sessions === 'object' && parsed.sessions) data = parsed;
  } catch (_) { /* first write or unreadable — start fresh */ }
  if (!data.sessions || typeof data.sessions !== 'object') data.sessions = {};

  const now = Date.now() / 1000;
  data.sessions[sessionId] = {
    status,
    cwd,
    provider: 'claude',
    updated: now,
    sessionID: sessionId,
  };

  // Drop stale sessions so the file never grows without bound. A finished chat
  // stays "complete" (green) for a while, then falls back to unlit.
  for (const [id, session] of Object.entries(data.sessions)) {
    const age = now - (session && typeof session.updated === 'number' ? session.updated : 0);
    if (!session || age > 1800) delete data.sessions[id];
  }

  // Atomic, collision-resistant write (several Claude sessions may hook at once).
  try {
    const tmp = `${file}.${process.pid}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(data));
    fs.renameSync(tmp, file);
  } catch (_) { /* best effort */ }
}

try { main(); } catch (_) { /* never disrupt Claude */ }
process.exit(0);
