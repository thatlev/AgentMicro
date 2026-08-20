# AgentMicro — VS Code bridge

Companion VS Code extension that lets AgentMicro (an iPhone
running AgentMicroRemote, or the `--emulate` keypad) drive your editor through
the default hybrid `codexbridge` mode.

It opens a local Unix socket the bridge connects to and turns small JSON "ops"
into real editor actions:

- **focus** a pinned tab or agent terminal (`terminal.show` / `showTextDocument`)
- **approve / reject** a Claude proposed diff (`claude-vscode.accept/rejectProposedDiff`)
- **send keys** to a Codex / Kimi / aider terminal (`terminal.sendText`)
- **create sessions** in Claude, Codex, ChatGPT, Kimi, or a configured terminal
- **use Claude's native dictation** for a concrete Claude editor chat when available
- **insert or auto-send iPhone dictation** for Codex, Kimi, terminals, and reliable auto-send
- **pin/unpin** the selected target to the first free agent key
- **decorate pinned file tabs** with live AgentMicro status colors
- **show VS Code's native pin glyph** on pinned Claude/agent editor tabs

It also streams the list of pinnable *targets* (each concrete terminal instance
and editor tab) back to the bridge so each agent key can be pinned to a
specific chat/tab UUID rather than a provider such as "Claude".

Nothing here patches Claude Code or any other extension. It discovers the
commands registered in the extension host and only advertises native voice
when the concrete target and installed provider actually support it.

## Install

```bash
code --install-extension agent-micro-vscode-0.6.0.vsix --force
```

Then **Developer: Reload Window** (or restart VS Code). Run **AgentMicro: Show
bridge status** from the command palette to confirm it is listening.

## Settings

- `codexMicro.socketPath` — override the socket (default `$TMPDIR/codexbridge-vscode.sock`).
- `codexMicro.terminalApprove` / `terminalReject` / `terminalSubmit` — the text
  sent to an *agent terminal* target on Approve / Reject / Submit (default
  `y\n` / `n\n` / `\n`). Tune these to whatever Codex/Kimi expect.
- `codexMicro.decorateTabs` — show semantic status colors on pinned file tabs.

## Notes / limits

- VS Code exposes file-tab decorations, but no public API to recolor an
  individual terminal or third-party webview tab after creation. File tabs get
  the requested label color; all target kinds also get the same live color in
  the AgentMicro status item. Pinned third-party editor tabs receive VS Code's
  native editor-pin glyph; pre-existing manual editor pins are left untouched.
  The selected target keeps VS Code's normal gray.
- Text insertion/submission into third-party webviews uses VS Code's public
  focused-control `type` command. Terminals use `terminal.sendText` directly.
- Claude editor chats use `claude-vscode.toggleDictation` while the microphone
  key is held. Codex and Kimi currently expose no callable VS Code dictation
  command, so they use the iPhone. Auto-send also uses the iPhone because
  Claude does not expose a transcript-complete event that can be submitted
  reliably.
- Provider commands under **NEW** remain launchers. A launched conversation is
  pinnable only when VS Code exposes it as its own editor tab; sidebar-only
  provider surfaces do not expose per-chat IDs, so the extension will not
  pretend the provider itself is a chat. Terminal launchers always create a
  concrete UUID target.
- One VS Code extension host owns the helper-facing socket and acts as a
  **multi-window hub**. Every other VS Code project stays registered as a peer;
  their concrete targets remain pinnable together, id-bearing operations route
  back to the project that owns the tab, and **NEW** follows the most recently
  focused project. If the hub window closes, a surviving peer takes over and
  the helper reconnects automatically without reassigning tab ids.
