# AgentMicro → VS Code setup

Use AgentMicro (the iPhone app or built-in emulator) to drive the
**Claude Code VS Code extension** — and Codex / Kimi CLIs running in terminals —
with live agent-status lighting on the six agent keys. No patching of Claude,
VS Code, or any extension: a small additive companion extension + the bridge
helper do it entirely through public APIs.

```

## Prerequisites

- Install whichever agent integrations the NEW picker will use: Anthropic
  Claude Code, OpenAI Codex/ChatGPT, or Moonshot Kimi Code.
- Terminal launchers require their executable (`claude`, `codex`, or `kimi`) on
  the shell PATH inherited by VS Code.
- Live blue/green/amber/red states come from AgentMicro's lifecycle
  hooks in `~/Library/Caches/CodexMicro/status.json`. No extra daemon is needed
  if the AgentMicro status feed already tracks those sessions.
- Claude editor-chat targets use Claude's own dictation while the key is held.
  Codex, Kimi, terminals, normal editor tabs, and auto-send use iPhone speech.
  The first iPhone-capture press asks for Microphone and Speech Recognition
  permission; it does not require the Siri/keyboard Dictation switch.
iPhone (BLE) ─▶ codexbridge (auto) ─▶ $TMPDIR/codexbridge-vscode.sock ─▶ AgentMicro VS Code extension ─▶ executeCommand / terminal.sendText
             ◀── agent-key LEDs ◀── AgentMicro status.json ◀── Claude/Codex/Kimi lifecycle hooks
```

## One-time install

1. **Companion extension** (drives the editor):
   ```bash
   code --install-extension "vscode/AgentMicroVSCode/agent-micro-vscode-0.5.1.vsix" --force
   ```
   Then run **Developer: Reload Window**. Confirm with the palette command
   **AgentMicro: Show bridge status** — it should say it is listening.

2. **Build the bridge helper** (once, or after editing it):
   ```bash
   swiftc -O tools/AgentMicroBridge/main.swift tools/AgentMicroBridge/T3Backend.swift -o tools/AgentMicroBridge/codexbridge
   ```

3. **iPhone app** — already built and installed on iPhone L
   (`io.github.thislev.codexmicroremote`). To rebuild:
   ```bash
   cd ios/AgentMicroRemote && xcodegen generate
   xcodebuild -scheme AgentMicroRemote -configuration Debug \
     -destination 'id=00008150-000A1C860CDA401C' -allowProvisioningUpdates build
   xcrun devicectl device install app --device iPhone-L.coredevice.local \
     "$(xcodebuild -scheme AgentMicroRemote -showBuildSettings | awk '/BUILT_PRODUCTS_DIR/{d=$3}/FULL_PRODUCT_NAME/{n=$3}END{print d"/"n}')"
   ```

## Run it

1. In VS Code, open the workspace you want to control (Claude sidebar + any
   Codex/Kimi terminals). Keep that window frontmost.
2. Start the bridge in its default auto mode:
   ```bash
   ./tools/AgentMicroBridge/codexbridge
   ```
   Auto mode follows the page selected on the iPhone: the first page keeps the
   existing ChatGPT/Codex behavior; the second routes to VS Code. `--target
   vscode` is still available for a fixed VS Code-only helper.
3. Open **AgentMicroRemote** on iPhone L (keep it foreground) — or, with no
   phone, add `--emulate` and type events at the terminal.

### No-phone quick test

```bash
./tools/AgentMicroBridge/codexbridge --target vscode --emulate
# then type:  ag0    (focus the target pinned to agent key 1)
#             approve / reject / send / fork
```

## Create and pin agents

1. Swipe left to the **VS CODE MICRO** page (or tap the second dot).
2. In the app's gear sheet, choose what **NEW** launches: Claude/Kimi/Codex or
   ChatGPT extension commands, Claude/Codex/Kimi terminals, or a custom VS Code
   command/terminal command. Terminals and editor-tab conversations receive a
   concrete target UUID. A sidebar-only provider is a launcher, not a target,
   because VS Code does not expose separate chat IDs for that surface.
3. Press **NEW**, dictate or type the prompt, and press **SEND**.
4. Press **PIN**. The selected target takes the first free key: no pins → key 1,
   two pins → key 3, four pins → key 5. Press **PIN** again to unpin it.
5. Press a pinned agent key to switch back to that target.

Pins are concrete target IDs stored in `~/.codexbridge/pins.json` (version 2).
File-tab URIs remain stable; runtime terminal/editor UUIDs are released when
that exact target closes. Provider names are launch choices only and can never
occupy an agent key. The old provider/tab-name matching and orange editor-pins
screen are retired.

## VS Code page controls

| Macropad | Action |
|---|---|
| Agent key 1–6 | Focus the pinned tab / terminal (and select it for the keys below) |
| **NEW** | Create the agent/session chosen under gear › VS Code |
| **APPR** | Approve — Claude: accept diff · terminal: send `terminalApprove` |
| **REJ** | Reject — Claude: reject diff · terminal: send `terminalReject` |
| **PIN / UNPIN** | Toggle the selected target on the first free agent key |
| **CLAUDE VOICE / HOLD TO TALK** | Claude native dictation for a concrete Claude editor chat when available; otherwise transcribe on iPhone |
| **SEND** | Submit — direct Enter in terminals; focused-control Enter in agent webviews |

When **Auto-send voice prompts** is enabled, the microphone always uses iPhone
transcription—even for Claude—so recognition completion and submission remain
one ordered operation bound to the chat selected at touch-down.

## Agent-key lighting

The bridge reads AgentMicro's legacy-compatible `~/Library/Caches/CodexMicro/status.json` (fed by the
Claude/Codex/Kimi lifecycle hooks already in `~/.claude/settings.json`) and
lights only explicitly pinned targets. It matches target ID first, then the
concrete provider/workspace; unrelated global strip-slot numbers
never allocate a VS Code agent key:

| Status | Color |
|---|---|
| selected | white (breathing) |
| idle | white |
| thinking / working | blue |
| complete | green |
| needs input / approval | amber |
| error | red |

The lights **self-heal**: the bridge re-emits every 15 s, and the iPhone
re-requests the latest state every 8 s while foreground, so a dropped BLE frame
or an idle period never leaves the LEDs frozen. (In ChatGPT mode the same
heartbeat re-syncs from ChatGPT's cache; if its hardware lights still go dark,
raise **Auto-off** in ChatGPT's AgentMicro settings.)

Pinned file-resource editor tabs receive the same solid semantic label colors;
the selected tab stays VS Code's normal gray. VS Code does not expose a public
per-tab color setter for terminal or third-party webview tabs, so those targets
show the live color in the AgentMicro status-bar item instead.
