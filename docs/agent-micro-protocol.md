# AgentMicro: behavior, protocol, and compatibility research

Research date: **2026-07-20**. Installed ChatGPT build examined: **26.715.52143 (5591)**,
bundle ID `com.openai.codex`. This document separates public product behavior from a
build-specific, private wire protocol. The wire protocol is not a supported OpenAI API and may
change without notice.

## Confidence labels

- **[OFFICIAL]** Published by OpenAI, Work Louder, Apple, or the Bluetooth SIG.
- **[LOCAL—26.715.52143]** Read from the installed ChatGPT.app bundle named above. This is exact
  for that build, not a promise about future builds.
- **[THIRD-PARTY—PHYSICALLY VALIDATED]** Demonstrated on an M5Stack Core2 by the independent
  `imliubo/agent-micro-4-core2` project. It is strong compatibility evidence, but not a dump of
  the shipping keyboard firmware.
- **[INFERENCE]** Best explanation obtained by combining the sources; not directly stated by a
  vendor.
- **[LOCAL TEST]** Observed in this workspace or on the local Mac.

## Bottom line

| Goal | Finding | Confidence |
|---|---|---|
| Reproduce the physical control layout and ChatGPT-visible behavior | Yes. The public manual and current app bundle define the controls, mappings, gestures, statuses, and exact current-build event IDs. | **High** |
| Build a compatible external BLE/USB HID controller | Yes in principle; a BLE M5Stack Core2 implementation has been physically validated with ChatGPT Desktop. | **High, third-party** |
| Make a normal iPhone app impersonate AgentMicro directly over Bluetooth | **No. Public iOS CoreBluetooth cannot publish the complete HID-over-GATT profile required by macOS.** | **High** |
| Use the current iOS target as the requested direct Bluetooth product | No. It is a visually useful prototype and a protocol reference, but it cannot complete the advertised pairing flow with public iOS APIs. | **High** |

The viable hardware path is a real AgentMicro or an external BLE-HID peripheral such as an
ESP32/M5Stack/nRF52. Another viable architecture is to use the iPhone as a remote UI that sends
commands to a small Mac helper or external peripheral; that is a different transport and needs
companion software.

## 1. Product and physical controls

**[OFFICIAL]** AgentMicro is the `kbd-1.0-agent-micro`, a limited-run OpenAI/Work Louder
controller for the ChatGPT desktop app. It supports Bluetooth and USB-C on Mac and Windows.
Published hardware specifications are:

- 13 mechanical switches;
- six frosted RGB Agent Keys;
- six default logical Command actions and an included 2U keycap;
- one capacitive touch sensor at bottom left;
- one clickable rotary encoder/dial at top left;
- one planar joystick at top right;
- RGB key and ambient lighting; and
- no built-in microphone—the Mic key uses the computer microphone.

**[INFERENCE, HIGH]** The switch count reconciles as six Agent Key switches plus seven Command
Key switches: five 1U Command Keys and one 2U Mic key over two switches. The current app treats
those two Mic positions as one logical control.

The rear control is power. Pairing is initiated with the bottom-left touch control, not the rear
control. Codex-specific behavior lives on layer 1; Work Louder Input can configure up to five
additional layers, for six total.

## 2. Complete official behavior matrix

The physical positions in this table follow the published product and setup material. Raw event
IDs and host interpretation are from the current installed build.

| Control | Official behavior and default | Gesture | Current-build raw event | Confidence |
|---|---|---|---|---|
| Agent Keys 1–6 | Follow six chats and display live status | Single press switches chat without focusing ChatGPT; double press within 350 ms switches and focuses ChatGPT | `v.oai.hid`, `k=AG00…AG05`, `ag=0…5`, press/release | **Official behavior; local IDs** |
| Dial rotation | Navigate composer controls, with Reasoning targeted initially | Turn to move/change; in Reasoning-only mode it opens and adjusts reasoning | `ENC_CW` or `ENC_CC`, `act=2` | **Official behavior; local IDs** |
| Dial press | Open/select the focused composer control | Press/release; hold 500 ms opens AgentMicro settings | `ENC`, `act=1/0` | **Official behavior; local ID** |
| Joystick up | Toggle Plan mode | Push far enough from center | `v.oai.rad`, angle near `0.75` | **Official mapping; local encoding** |
| Joystick right | Navigate forward | Push far enough from center | angle near `0.0` | **Official mapping; local encoding** |
| Joystick down | Show/hide sidebar | Push far enough from center | angle near `0.25` | **Official mapping; local encoding** |
| Joystick left | Navigate back | Push far enough from center | angle near `0.5` | **Official mapping; local encoding** |
| `FAST` | Toggle Fast mode | Command fires on press | `ACT06` | **Official behavior; local ID** |
| `APPR` | Approve current request | Command fires on press | `ACT07` | **Official behavior; local ID** |
| `REJ` | Decline current request | Command fires on press | `ACT08` | **Official behavior; local ID** |
| `SPLIT` | Continue current chat in a new chat | Command fires on press | `ACT09` | **Official behavior; local ID** |
| 2U `MIC` | Push-to-talk using the computer microphone | Hold and release, or double press within 350 ms to latch; press again to stop | Logical slot `ACT10_ACT11`; the bridge consumes `ACT10` and ignores duplicate `ACT11` input | **Official behavior; local ID/handling** |
| `CODEX` | Send composer message | Command fires on press | `ACT12` | **Official behavior; local ID** |
| Bottom-left touch | Change layer; enter/select/re-pair communication channel | Tap cycles layers; hold 3 s enters communication mode; tap selects a channel; hold 3 s re-pairs it | No Codex vendor-RPC event established; handled in device firmware | **Official behavior; no raw host event found** |
| Rear control | Power | Not used to enter pairing | No Codex vendor-RPC event established | **Official behavior** |

### Current-build dial direction

**[LOCAL—26.715.52143]** This corrects the earlier reversed mapping:

- `ENC_CW` maps to `ArrowUp`; in composer navigation that moves to the previous target, and on
  the Reasoning target it decreases reasoning effort.
- `ENC_CC` maps to `ArrowDown`; in composer navigation that moves to the next target, and on the
  Reasoning target it increases reasoning effort.

OpenAI's public manual explains what the dial does but does not promise which physical turn
direction corresponds to increase/decrease. Treat the mapping above as build-specific.

### Host-side gesture state machines

**[LOCAL—26.715.52143]** The device emits raw events; ChatGPT implements these gestures:

- Agent key: a single press is deferred until the 350 ms double-press window resolves. A second
  press for the same slot/thread switches and brings ChatGPT forward.
- Command key: the action fires on `act=1`; release does not fire another command.
- Mic: recording starts on the first press. A quick release waits through the 350 ms second-press
  window. A second press latches hands-free recording. Releasing a hold of at least 350 ms stops;
  pressing while latched also stops.
- Dial button: normal press/release selects; a 500 ms hold opens settings.
- Joystick: an action fires when the derived cardinal direction changes. Displacement greater
  than `0.1` also counts as activity for lighting wake behavior.

When a composer control or menu is open, **[OFFICIAL]** the Agent Key immediately to the right of
the dial lights red; pressing it cancels.

## 3. Agent assignment and exact status lighting

### Agent sources

**[OFFICIAL]** The default source is the six most recently updated chats, pinned or unpinned.
Users can select:

- **Most recent:** six most recently updated chats;
- **Pinned:** first six chats in Pinned;
- **Priority:** waiting-for-input, unread, and active chats first; or
- **Custom:** one chosen chat per key. Pressing an unassigned custom key opens a new chat and the
  new chat is assigned to that key when started.

Agent Keys cannot be converted into extra Command Keys.

### Status matrix

| Meaning | Official appearance | Current packed RGB | Current host state |
|---|---:|---:|---|
| Idle | White | `#FFFFFF` / `16777215` | `idle` |
| Thinking/running | Blue | `#304FFE` / `3166206` | `working` |
| Complete with unread update | Green | `#00FF4C` / `65356` | `unread` |
| Approval or response needed | Amber | `#FF8F00` / `16739584` | `awaiting-approval` or `awaiting-response` |
| Error | Red | `#FF0033` / `16711731` | `error` |
| Unassigned | Off | `0` | `off` |

The selected chat's Agent Key pulses in its status color. **[LOCAL—26.715.52143]** A selected
slot uses effect `breath` with speed `0.4`; an unselected lit slot uses `solid` with speed `0`.
When a selected and focused chat has an unread update, the display is normalized to idle rather
than green because it is no longer meaningfully unread.

Local thread status precedence is waiting for approval/response, error, loading, unread, then
idle. Remote task status maps failed to error; pending/in-progress to working; unread to unread;
otherwise idle.

### Voice and global lighting

**[OFFICIAL]** A moving sea-green light indicates recording, moving white indicates speech
processing, and solid white means the prompt is ready. Press `CODEX` to send it.

**[LOCAL—iPhone remote]** If push-to-talk begins while the selected Agent Key is blue and
breathing (the thread is running), releasing the microphone arms immediate steering. The phone
does not press `CODEX` on release, because transcription is not ready then; it waits for the
host's solid-white ready state and emits the normal `ACT12` press/release automatically. Voice
used on an idle thread keeps the official review-then-send behavior.

**[LOCAL—26.715.52143]** The exact recording color is `#2E8B57` (`3050327`). Current effect IDs
are:

| Effect | Numeric ID |
|---|---:|
| off | `0` |
| solid | `1` |
| snake | `2` |
| rainbow | `3` |
| breath | `4` |
| gradient | `5` |
| shallow breath | `6` |

Lighting brightness is configurable from 0–100 in the ChatGPT/AgentMicro settings, defaults to
100, and is sent normalized to 0–1. The iPhone remote displays the reported value read-only and
uses it for both the agent-key LEDs and body glow; it has no independent brightness controls.
Auto-off choices in the current settings schema are never, 30 seconds, 1, 3, 10, or 30 minutes,
or 1 hour; **[OFFICIAL]** the default is 3 minutes. That power-saving timer applies to physical
hardware. While the iPhone control surface is visible, it keeps the semantic key colours lit at
the configured brightness so status remains glanceable; backgrounding still suspends the display
and its lighting heartbeat normally. Battery level appears in AgentMicro settings and the
sidebar tooltip when the device reports it.

Current host lighting writes are de-duplicated and wait for a 100 ms input-quiet window. A
selected working chat uses a snake ambient animation in its status color. Special voice and
onboarding states can temporarily control ambient lighting.

The iPhone remote treats Agent Key lighting as durable semantic state rather than a transient
hardware frame. It persists the last complete Mac-reported slot state, rebuilds composited LED
layers whenever iOS returns to the foreground, and asks `AgentMicroBridge` to replay its latest
cached `thstatus`/`rgbcfg` values over the private channel 5 → channel 3 refresh path. The request
does not synthesize a key press and does not alter ChatGPT's physical-light auto-off timer.

## 4. Default mappings and included keycap catalog

### Default settings schema

**[LOCAL—26.715.52143, consistent with the official manual]**

| Logical slot | Keycap | Command identifier |
|---|---|---|
| `ACT06` | `FAST` | `composer.toggleFastMode` |
| `ACT07` | `APPR` | `approval.approve` |
| `ACT08` | `REJ` | `approval.decline` |
| `ACT09` | `SPLIT` | `forkThread` |
| `ACT10_ACT11` | `MIC` | push-to-talk behavior |
| `ACT12` | `CODEX` | `composer.submit` |
| stick up | — | `composer.togglePlanMode` |
| stick right | — | `navigateForward` |
| stick down | — | `toggleSidebar` |
| stick left | — | `navigateBack` |

Default Agent source is `recent`; default dial mode is `composer-navigation`, targeting
Reasoning first. Other Agent source values are `pinned`, `priority`, and `custom`. The other dial
mode is `reasoning` (shown as Reasoning only).

### Keycap/action definitions in the current bundle

These are built-in current-build defaults for the cap picker, not a claim that the following is
every command available anywhere in ChatGPT. Directions can additionally map to an enabled Skill.
Choosing an already-used keycap swaps the two assignments rather than duplicating it.

| Keycap(s) | Built-in action |
|---|---|
| `FAST`, `APPR`, `REJ`, `SPLIT`, `MIC`, `CODEX` | Toggle Fast; approve; decline; fork chat; push-to-talk; submit |
| `BUG`, `OAI` | Send feedback; open `developers.openai.com` |
| `TERM`, `NAV` | Toggle terminal; open browser tab |
| `DWN`, `DEL`, `NEW` | Copy conversation as Markdown; archive thread; new task |
| `MAGIC` | Pin/unpin thread |
| `DIFF`, `BRCH`, `MRG` | Open/toggle review changes tab (three visual cap choices) |
| `PLAY` | Environment action 1 |
| `GIT`, `PR` | Commit; create pull request |
| `PAINT`, `UPL` | Add photos; add files |
| `LAB`, `SETUP` | Open settings |
| `PARTY`, `TIME` | Open side chat; manage scheduled tasks |
| `MIND+`, `MIND-` | Increase/decrease reasoning effort |
| `FOLD`, `APPS` | Open folder; open Skills |
| `YOLO`, `YEET` | Insert `:yolo:` / `:yeet:` into the composer |
| `EMPT1`–`EMPT4` | Custom keyboard shortcut, 1U |
| `EMPT5` | Custom keyboard shortcut, 2U |

**[OFFICIAL]** Remapping also exposes desktop actions such as opening browser/terminal, reviewing
changes, committing, creating a pull request, attaching files/photos, managing scheduled tasks,
changing reasoning effort, and opening Skills. Work Louder Input supports six programmable
layers for broader per-app mappings.

The marketing copy says “32 extra keycaps,” while the included-item specification says
`30x1U + 1x2U` (31 physical extras). The local picker contains 31 extra definitions in addition
to the six installed defaults. This small public count discrepancy should not be silently
resolved as fact.

## 5. Pairing, connection mode, and layers

### Official Codex re-pairing

1. Hold the bottom-left touch control for 3 seconds to enter communication mode.
2. Tap it to choose Bluetooth channel 1, 2, or 3.
3. Hold it for 3 seconds on that channel. The channel light flashes during pairing and becomes
   solid when paired.

The rear button controls power and does not initiate pairing.

### Additional Work Louder setup behavior

**[OFFICIAL—WORK LOUDER]** A normal touch tap cycles the configured layers, up to six. In
communication mode, successive taps cycle Bluetooth channels 1–3 and wired mode (shown white).
Fast flashing means discoverable/pairing and solid means connected. Communication mode times out
after about 5 seconds. Plugging in USB-C while a Bluetooth channel remains selected charges the
device but does not automatically switch the active connection to wired mode.

On macOS, ChatGPT requires Input Monitoring permission. The user connects via USB-C or the macOS
Bluetooth UI. **[LOCAL—26.715.52143]** ChatGPT itself does not perform a CoreBluetooth scan.

## 6. Current desktop discovery path

**[LOCAL—26.715.52143]** The installed app uses an OS-level HID path:

- a native `hid-topology-watcher.node` addon exposes `findAgentMicroInterfaces()` and watches
  topology changes;
- the service opens the returned path through async `node-hid`, non-exclusive on macOS;
- the Codex interface must have vendor ID `0x303A` (`12346`), product ID `0x8360` (`33632`),
  usage page `0xFF00` (`65280`), and a usable HID path;
- `release % 4 == 0` is classified as USB; other low-bit values are classified as BLE;
- reconnect delays are 1, 2, 5, and 10 seconds, with topology settle retries at 250 ms, 1 s,
  and 3 s; a 30-second full scan is a fallback only when topology watching fails; and
- battery is polled every 60 seconds.

The service labels this device type `Project2077`. A separate **[LOCAL—26.715.52143]** firmware
update path uses an Espressif USB serial interface at 115200 baud and bundled `esptool-js`; it is
not part of the vendor-HID event path described below.

The active AgentMicro service does **not** call the generic SDK's
`WLDeviceDiscovery.filterWLDevices`. That generic helper prefers manufacturer strings containing
`Work Louder`/`Work_Louder` and then has a VID-only fallback, but it is not the current JS
service's matching rule. Therefore a manufacturer string is useful compatibility metadata, not
a proven current-build requirement.

The native addon's implementation is binary, so do not claim more precise matching rules than
the behavior exposed to the JavaScript service. There is no CoreBluetooth scan in ChatGPT.app
and no Bluetooth usage description in its `Info.plist`; Bluetooth hardware must first appear to
the OS as HID.

## 7. Working vendor-HID shape

### Evidence boundary

The descriptor below is **[THIRD-PARTY—PHYSICALLY VALIDATED]** and matches the installed host
transport assumptions. It is sufficient for the Core2 project to enumerate and connect, but it
has not been captured byte-for-byte from a shipping AgentMicro. Labeling it “the confirmed real
device descriptor” would overstate the evidence.

```text
06 00 FF   Usage Page (Vendor Defined 0xFF00)
09 01      Usage (1)
A1 01      Collection (Application)
85 06        Report ID (6)
15 00        Logical Minimum (0)
26 FF 00     Logical Maximum (255)
75 08        Report Size (8)
95 3F        Report Count (63)
09 01        Usage (1)
81 02        Input (Data,Var,Abs)
95 3F        Report Count (63)
09 02        Usage (2)
91 02        Output (Data,Var,Abs)
C0         End Collection
```

HIDAPI host writes contain 64 bytes: `[reportId=6][channel][length][payload…padding]`.
BLE report characteristic values omit the implicit report-ID byte and therefore contain the
63-byte body `[channel][length][payload…padding]`.

### Framing

**[LOCAL—26.715.52143]** The official traffic uses channels 1–2; the iPhone
bridge adds private channels 3–5:

| Channel | Direction | Meaning |
|---:|---|---|
| `1` | device → host | Debug log text |
| `2` | both | JSON-RPC-like messages |
| `3` | bridge → phone | **AgentMicro-only** settings sync, not real device protocol (see below) |
| `4` | phone/emu → shim | **AgentMicro-only** host-action control channel (see below) |
| `5` | phone → bridge | **AgentMicro-only** bridge control: page routing, refresh, VS Code new/pin/dictation |

**[LOCAL TEST — AgentMicro addition]** Channel `3` is not part of the AgentMicro
wire protocol. `tools/AgentMicroBridge` uses it to relay ChatGPT's key-binding
layout and durable lighting-brightness setting from `~/.codex/config.toml` to
the AgentMicroRemote iPhone app, so its command-key legends and read-only
brightness display follow the desktop settings. It is chunked exactly like
channel 2 (`[6][3][len][payload…]`) but carries a bare-JSON
`agent-micro-layout` settings snapshot and flows bridge→phone only — it is
never written toward the ChatGPT shim, so the host never sees it.
In auto mode the same channel also carries `vscode-state` snapshots (targets,
direct v2 pins, selected target, extension connection state).

**[LOCAL TEST — AgentMicro addition]** Channel `4` is likewise not part of the
AgentMicro wire protocol. It is a control channel flowing phone/emulator →
`codex-hid-shim.js` for host-side actions the device protocol has no command
for. The composer has no clear command in any ChatGPT build examined (the
keycap catalog exposes submit, fork, approve/decline, reasoning effort,
navigation, insert-text, open-URL, and custom keyboard shortcuts — never a
clear), so the phone's "clear message box" button sends `{"cmd":"clearComposer"}`
on channel 4; the shim runs Electron's `webContents.selectAll()` +
`delete()` on the focused window and swallows the frame (it is never forwarded
to node-hid). Framed like channels 2/3 (`[6][4][len][payload…]`).

**[LOCAL TEST — AgentMicro addition]** Channel `5` terminates in
`AgentMicroBridge`; neither ChatGPT nor the shim receives it. `setControlTarget`
switches auto routing between ChatGPT and VS Code. `vscodeNew`,
`vscodeTogglePin`, `vscodeInsert`, and target-bound `vscodeVoice` drive the companion extension, while
`refreshState` asks the active integration to replay its cached semantic state.

Payload chunks are at most 61 bytes. The host writes a fixed 64-byte HIDAPI buffer with report ID
6; it sends chunks without an inter-chunk delay.

The message boundary is **directional**, which is an important correction:

- **Host → device:** bare JSON, **no newline appended**. Accumulate chunks and process the buffer
  as soon as a complete JSON object parses.
- **Device → host:** append `\n`. The host buffers each channel and splits on `\r?\n`; without
  the newline, it does not dispatch the JSON message.

The host serializes requests one at a time, waits for the matching response, then observes a
50 ms queue cooldown. Request timeout is 10 seconds. Host-generated request IDs use
`crypto.randomInt(0, 999)`, so the actual range is **0 through 998**, not 0 through 999.
Host-generated non-ASCII text is escaped as Unicode before transmission.

Request form is `{method, params, id}`. A notification has a method and no ID. A response has an
ID plus `result` or `error`. The host receive parser accepts `id`/`i`, `method`/`m`, and
`params`/`p` aliases.

The “reset a stale buffer when a fragment starts with `{"method"`” behavior exists in the Core2
firmware and workspace emulators. It is a defensive device-side strategy, **not** behavior found
in the installed host parser.

## 8. RPC and raw events

### Methods used by the current AgentMicro runtime

| Direction | Method | Shape and required behavior | Confidence |
|---|---|---|---|
| host → device | `v.oai.rgbcfg` | Params `{ambient:{e,b,s,m,c}, keys:{e,b,s,m,c}}`; update global zones and respond to the request | **Local current build** |
| host → device | `v.oai.thstatus` | Params array of changed slot-light objects; apply changes and respond | **Local current build** |
| host → device | `device.status` | Return optional typed fields including `version`, `profile_index`, `layer_index`, `battery`, `is_charging`; current service uses battery state | **Local current build** |
| device → host | `v.oai.hid` | Params `{k, act, ag?}` | **Local current build + physical third party** |
| device → host | `v.oai.rad` | Params `{a, d}` | **Local current build + physical third party** |

On connection the current service sends lighting state and requests status. A compatible device
must answer request IDs; otherwise the one-at-a-time RPC queue stalls until timeout. The exact
success payload for lighting acknowledgements is not consumed, so `{result:{ok:true}}` is a
convenient compatible response, not an official mandated schema.

### Raw input schemas

`v.oai.hid`:

```json
{"method":"v.oai.hid","params":{"k":"AG00","act":1,"ag":0}}
```

- `act=0`: release
- `act=1`: press
- `act=2`: encoder step
- keys: `AG00`–`AG05`, `ACT06`–`ACT12`, `ENC_CW`, `ENC_CC`, `ENC`
- `ACT11` is the second physical Mic switch. The logical slot is `ACT10_ACT11`; current input
  handling intentionally consumes `ACT10` so the 2U cap acts once.

`v.oai.rad`:

```json
{"method":"v.oai.rad","params":{"a":0.75,"d":1.0}}
```

`a` is normalized turns: right `0`, down `0.25`, left `0.5`, up `0.75`. `d` is normalized
displacement; release is represented with `d=0`.

### Lighting request fields

`v.oai.thstatus` receives an array whose minimized fields are:

- `id`: slot 0–5; the only required field;
- `c`: packed `0xRRGGBB` integer;
- `b`: brightness 0–1;
- `e`: numeric effect ID;
- `s`: effect speed 0–1;
- `sk`: synchronize key backlight, 1/0; and
- `sa`: synchronize ambient lighting, 1/0.

Omitted fields mean leave the corresponding setting unchanged. A full off update is
`{c:0,b:0,e:0,s:0,sk:0,sa:0}` plus its `id`.

### Other APIs bundled in the generic Work Louder SDK

**[LOCAL—26.715.52143, SDK surface only]** The app bundle also contains these generic SDK calls:

| Method | Parameters / result represented by the bundled client |
|---|---|
| `sys.version` | No params; result includes `{version}` |
| `sys.bootloader` | No params; request reboot into bootloader |
| `sys.selftest` | No params; request diagnostic mode |
| `lights.preview` | Backlight/underglow configuration for a live preview |
| `host.focused_app` | Host application identity/context |
| `fs.list` | `{checksum:true}`; returns file metadata |
| `fs.read` | `{file}`; whole JSON/text file read |
| `fs.write` | `{file,data}`; small file write |
| `fs.writebin` | `{file,data,append,completed,offset}`; Base64 binary chunks |
| `fs.readbin` | `{file,offset,len}`; result includes `{total_size,data}` |
| `fs.delete` | `{file}` |
| `mp.write_info` | `{song_title,artist,elapsed,total_duration,is_playing}` |
| `mp.write_artwork` | `{data,offset,size}` |
| `ui.active_screen` | No params; result includes `{screen_name}` |
| `ui.home_accent_color` | `{color}` |
| `wlsdk.<method>` | Extension-defined payload |

Legacy `#version#`, `#bootloader#`, `#selftest#`, and `#dfu#` strings belong to the serial/DFU
path, not this HID transport. The current AgentMicro service does not invoke most of the generic
methods above during normal operation. They must not be presented as the minimum emulation
surface or proof that the shipping device implements every generic feature.

The independent Core2 firmware handles `sys.version`, `device.status`, Codex lighting, preview,
focused-app, and unknown requests. Its conventional `-32601 Method not found` reply is a sensible
fallback, but it is third-party behavior rather than an OpenAI requirement.

## 9. Third-party physical validation and known discrepancy

**[THIRD-PARTY—PHYSICALLY VALIDATED]** Commit
[`2ee23a4`](https://github.com/imliubo/agent-micro-4-core2/tree/2ee23a4ab696f94bb78d250f28cc4a9b879ba079)
reports a physical M5Stack Core2 test on macOS with ChatGPT Desktop on 2026-07-16. It validates:

- BLE HID enumeration using VID `0x303A`, PID `0x8360`, usage page `0xFF00`, and report ID 6;
- ChatGPT detection and reconnect;
- the chunked channel-2 JSON transport;
- status/config requests and device input events; and
- external hardware as a feasible reproduction route.

The repository does not record the exact ChatGPT build used and is not affiliated with OpenAI or
Work Louder. It is evidence of compatibility, not a specification.

One current-build discrepancy matters: its `ThreadLight.effect` is modeled as a string and its UI
recognizes `"breath"`, whereas build 26.715.52143 sends numeric effect `4`. A new implementation
should accept current numeric effects; accepting the historical string names as a compatibility
fallback is harmless.

## 10. Why direct iPhone BLE impersonation cannot ship

The earlier plan to publish a standard BLE HID-over-GATT peripheral from a normal iPhone app is
not feasible with public iOS APIs.

1. **[APPLE API + REPRODUCIBLE PLATFORM BEHAVIOR]** Adding the required standard HID service
   `0x1812` through `CBPeripheralManager` is rejected with `CBErrorDomain` code 8,
   `uuidNotAllowed`. Apple's error definition means the specified UUID is not permitted.
2. **[OFFICIAL APPLE API]** `CBMutableDescriptor` supports only Characteristic User Description
   (`0x2901`) and Characteristic Presentation Format (`0x2904`) for a local peripheral.
3. **[OFFICIAL BLUETOOTH SIG]** HID-over-GATT input/output Report characteristics require the
   Report Reference descriptor `0x2908` to identify report ID and report type. Public iOS cannot
   create it.
4. **[LOCAL—26.715.52143]** ChatGPT discovers OS HID interfaces, not arbitrary CoreBluetooth
   services. Replacing HOGP with a custom BLE service would therefore not be detected.

Either blocker is fatal to direct iPhone → macOS AgentMicro emulation. Removing `0x2908` may
allow a diagnostic partial service in some environments, but it is not a valid HOGP device and
macOS cannot reliably bind two `0x2A4D` characteristics to report ID 6 and their input/output
types. There is no honest “pair and then ChatGPT prompts setup” path for the current iOS-only
architecture.

The current Swift target now reflects the protocol accurately but remains non-viable as direct
hardware:

- it attempts `0x1812` and required `0x2908` descriptors;
- on descriptor publication failure it retries only to diagnose whether `0x1812` itself is also
  rejected, and then stops rather than advertising an incomplete success;
- it displays a blocking explanation instead of falsely claiming pairing success;
- it sends correct device→host newline-terminated messages and accepts the host's bare JSON;
- it uses the correct key IDs, joystick angles, status colors, and numeric lighting effects.

**[LOCAL TEST]** A same-Mac CoreBluetooth peripheral does not become an IOKit HID interface.
`IOHIDUserDevice` can create a suitable virtual device only with Apple's restricted
`com.apple.developer.hid.virtual.device` entitlement; ad-hoc and unprovisioned development
signatures were terminated on the tested Mac. Those are not deployable substitutes for an
ordinary iPhone app.

## 11. Correct implementation routes

### Patched desktop app via in-process shim (implemented here)

**[LOCAL TEST — working on build 26.715.52143]** The route that needs no hardware, no AMFI
change, and no HID entitlement: patch ChatGPT itself so its device layer talks to a local
helper over a Unix socket instead of to an OS HID device.

1. `tools/patch-chatgpt.sh` extracts `app.asar`, injects `codex-hid-shim.js`, points the
   nested `node-hid` entry at the shim, redirects the native `hid-topology-watcher` loader in
   `codex-micro-service-*.js` to the same shim, repacks (preserving the unpacked-file set),
   refreshes `ElectronAsarIntegrity` (SHA256 of the asar header JSON), and re-signs ad-hoc.
2. The shim impersonates the watcher (`findAgentMicroInterfaces`, `watch`) and `node-hid`
   (`HIDAsync.open`, 64-byte framed reports) and relays bytes to
   `$TMPDIR/AgentMicro/codexbridge.sock`. The menu app temporarily exposes the
   former `/tmp/codexbridge.sock` path as a migration alias for older patches.
3. The AgentMicro menu app serves that socket. Its embedded bridge relays the iPhone bridge GATT
   service; `--emulate` is a standalone virtual AgentMicro (answers `device.status`,
   lighting acks; stdin injects key/dial/joystick events). No root needed in either mode.

Verified end-to-end: app detects the emulated device, runs the "Welcome to AgentMicro"
onboarding, polls `device.status`, streams `v.oai.thstatus`/`v.oai.rgbcfg` lighting, and
consumes injected `v.oai.hid`/`v.oai.rad` events; hot-plug and reconnect behave like real
hardware. Caveats: ad-hoc re-signing requires stripping the restricted team entitlements
(keychain access is lost → one re-login; the app keeps an `embedded.provisionprofile` that
becomes inert), macOS re-prompts TCC permissions for the re-signed app, and any ChatGPT
update reverts the patch. Fresh menu-app patches retain a full, versioned
backup under `~/Library/Application Support/AgentMicro/Backups/`.

### External BLE-HID hardware

Use the physical Core2 project as the strongest public baseline, then harden it for the current
app build:

1. expose a real HOGP device that the OS enumerates as VID `303A`, PID `8360`, usage page `FF00`;
2. implement report ID 6 and 63-byte input/output bodies;
3. parse bare host JSON and newline-terminate every device message;
4. acknowledge `v.oai.rgbcfg`, `v.oai.thstatus`, and `device.status`;
5. emit the exact `v.oai.hid` and `v.oai.rad` events above; and
6. accept numeric lighting effects, optionally retaining string compatibility.

### iPhone remote plus bridge

Keep the polished touch UI, but connect it to a Mac helper or an external BLE-HID board over a
custom authenticated transport. The helper/peripheral, not iOS CoreBluetooth, must expose the
OS-level HID interface. This changes the product promise: it requires companion software or
hardware and must say so during onboarding.

## 12. Audit corrections from the previous revision

| Previous claim | Corrected finding |
|---|---|
| All technical details were “fully confirmed” | Official behavior, local build internals, third-party behavior, and inference now have separate confidence labels. |
| iPhone can publish the identical HOGP profile | Public iOS blocks HID service `0x1812` and cannot create required descriptor `0x2908`; direct impersonation is not feasible. |
| JSON is newline-delimited in both directions | Host requests are bare JSON; only device→host messages require newline termination. |
| IDs are random in `[0,999]` | `crypto.randomInt(0,999)` produces `0…998`. |
| `ENC_CW` means ArrowDown and `ENC_CC` ArrowUp | Current build maps CW to ArrowUp and CCW to ArrowDown. |
| Manufacturer matching is part of the active service rule | That filter is in generic SDK code; the active AgentMicro JS service bypasses it. |
| Every generic SDK method is required | Normal current runtime uses only Codex lighting/status methods plus the two device event methods. |
| Host receiver performs `{"method"` resynchronization | That is a third-party/workspace device-parser tactic, not installed host behavior. |
| Descriptor shown is a byte-exact real-device dump | It is a physically validated compatible descriptor, not a shipping-device capture. |
| Core2 string lighting effects exactly match current host | Current host sends numeric effect IDs; Core2's published parser is stale on that detail. |
| Keycap catalog was complete | Added omitted `BRCH` and `MRG` definitions and documented the public 32-vs-31 count discrepancy. |

## 13. Workspace consistency check

Checked against:

- `ios/AgentMicroRemote/Sources/AgentMicroPeripheral.swift`
- `ios/AgentMicroRemote/Sources/ContentView.swift`
- `tools/AgentMicroEmu/main.swift`
- `tools/AgentMicroVHid/main.m`
- `tools/AgentMicroBridge/main.swift` (BLE-to-socket relay + `--emulate`)
- `tools/AgentMicroBridge/codex-hid-shim.js` and `tools/patch-chatgpt.sh` (in-app shim route)

The iOS code's transport direction, report sizes, report ID, raw key IDs, joystick encoding,
active RPC handlers, color parsing, numeric/string effect compatibility, and visible feasibility
warning agree with this document. `tools/AgentMicroEmu` is retained only as a GATT reference:
same-Mac CoreBluetooth advertising is not discoverable as HID. The virtual-HID tool remains
entitlement-blocked outside an Apple-authorized deployment. The working local route is the
patched-app shim above: `patch-chatgpt.sh` plus `codexbridge` (with `--emulate` when no
iPhone is available).

## 14. Sources

Primary product and behavior sources:

- [OpenAI AgentMicro manual](https://learn.chatgpt.com/docs/features/agent-micro)
- [OpenAI Supply Co. × Work Louder](https://openai.com/supply/co-lab/work-louder/)
- [Work Louder AgentMicro product page](https://worklouder.cc/agent-micro)
- [Work Louder Creator Micro setup guide](https://worklouder.cc/micro-setup)

Platform feasibility sources:

- [Apple: `CBMutableDescriptor` supported descriptor types](https://developer.apple.com/documentation/corebluetooth/cbmutabledescriptor/init(type:value:))
- [Apple: `CBError.Code.uuidNotAllowed`](https://developer.apple.com/documentation/corebluetooth/cberror/code/uuidnotallowed)
- [Apple Developer Forums: HID service `0x1812` rejected with error code 8](https://developer.apple.com/forums/thread/725238)
- [Bluetooth SIG Assigned Numbers](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/Assigned_Numbers/out/en/index-en.html)

Compatibility evidence:

- [M5Stack Core2 AgentMicro emulator, validated commit](https://github.com/imliubo/agent-micro-4-core2/tree/2ee23a4ab696f94bb78d250f28cc4a9b879ba079)

Local build evidence:

- `/Applications/ChatGPT.app/Contents/Resources/app.asar`
- bundled `@worklouder/device-kit-oai` version `0.1.10` and nested
  `@worklouder/wl-device-kit`
- current main-process `codex-micro-service-*.js` and webview chunks
  `agent-micro-bridge`, `agent-micro-layout`, `agent-micro-slot-signals`, and
  `agent-micro-settings`
- `/Applications/ChatGPT.app/Contents/Info.plist`
