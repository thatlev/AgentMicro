//
//  CodexMicroPeripheral.swift
//  Experimental BLE HOGP peripheral for the Work Louder Codex Micro protocol.
//
//  A compatible host requires a real OS-level HID device. Public iOS
//  CoreBluetooth rejects app-published HID services (0x1812), so when that
//  happens this peripheral falls back to a custom GATT "bridge" service
//  carrying the same 63-byte reports. The Mac-side helper
//  (tools/CodexMicroBridge, run with sudo) subscribes to the bridge and
//  re-exposes the stream locally as a virtual Codex Micro HID device.
//  Unrecoverable failures are surfaced through `blockingIssue`; an
//  incomplete profile is never advertised as ready.
//
//  Reverse-engineered protocol notes: ../../../docs/codex-micro-protocol.md
//

import CoreBluetooth
import OSLog
import UIKit

// MARK: - Protocol model

/// One agent-slot lighting state pushed by the host via `v.oai.thstatus`.
struct SlotLight: Equatable, Codable {
    var color: UInt32 = 0
    // Brightness is a 0–1 level (UI 0–100, defaults to 100), not an on/off flag.
    // A `v.oai.thstatus` update may change only `c`/`e` and omit `b` — "omitted
    // fields mean leave unchanged" — so it must default to full, otherwise a
    // colour+effect status change with no brightness would render a lit slot dark.
    var brightness: Double = 1
    var effect: Int = 0 // OAILightingEffect: off 0, solid 1, snake 2, rainbow 3, breath 4, gradient 5, shallowBreath 6
    var speed: Double = 0

    // On/off is defined by effect + colour: the canonical "off" update sends
    // `e:0`/`c:0`. Brightness must not gate visibility, or a working-status update
    // that omits `b` would leave the Agent Key empty until the slot is selected.
    var isOn: Bool { effect != 0 && color != 0 }
}

/// Global ambient/keys zone config pushed via `v.oai.rgbcfg`.
struct ZoneLight: Equatable {
    var color: UInt32 = 0
    var brightness: Double = 0
    var effect: Int = 0
    var speed: Double = 0
}

/// The host's real voice-capture state, decoded from the ambient lighting the
/// Codex desktop app drives during dictation (docs/codex-micro-protocol.md
/// §Voice and global lighting). This is ground truth for the microphone snake:
/// unlike a locally guessed state it cannot disagree with what the Mac is
/// actually doing, which is what keeps the snake from claiming to record when
/// nothing is being captured.
enum HostVoiceLighting: Equatable {
    case none        // ambient is not a voice pattern (idle underglow, a working chat's snake, off)
    case recording   // moving sea-green
    case processing  // moving white
    case ready       // solid white — the transcript is sitting in the composer, awaiting CODEX
}

/// One command-key binding as configured in the desktop app's Codex Micro
/// settings: the keycap on the slot plus an optional command override.
struct KeyBinding: Equatable {
    var keycapId: String
    var commandId: String?
}

/// One analog-stick direction action (a command or a Skill).
struct StickAction: Equatable {
    var type: String = "command" // "command" | "skill"
    var commandId: String?
    var skillName: String?
    var skillPath: String?
}

/// A focusable surface reported by the VS Code companion extension. IDs are
/// stable for the lifetime of the editor/terminal and are what pins store.
struct VSCodeTarget: Identifiable, Equatable {
    var id: String
    var kind: String
    var label: String
    var provider: String
    var active: Bool
    /// True only when this concrete target exposes a safe provider-native
    /// push-to-talk command. It is intentionally per target, not per model.
    var nativeVoice: Bool
}

/// One completely isolated non-Codex control surface. The bridge uses the
/// surface key (`vscode`, `t3code`, or `claude-desktop`) on every request and
/// response, so a delayed transcription can never land on whichever page the
/// user happened to swipe to in the meantime.
struct WorkspaceBridgeState: Equatable {
    var targets: [VSCodeTarget] = []
    var pins = Array<String?>(repeating: nil, count: 6)
    var selectedTargetID: String?
    var connected = false
    /// Provider-confirmed native dictation state. Claude Desktop publishes
    /// this after Command-D succeeds so the phone never claims to be listening
    /// when macOS denied Accessibility control.
    var nativeVoiceActive = false
    var slots = Array(repeating: SlotLight(), count: 6)
    var issue: String?
}

/// The host's `codex-micro-layout` setting. ChatGPT persists it to
/// ~/.codex/config.toml but never sends it over the device protocol, so
/// tools/CodexMicroBridge watches that file and relays the layout as
/// channel-3 config reports on the bridge output characteristic. Until the
/// first sync arrives this holds the desktop app's defaults.
struct CodexMicroLayout: Equatable {
    var slots: [String: KeyBinding]
    var analogStick: [String: StickAction]
    var encoderMode: String

    static let slotOrder = ["ACT06", "ACT07", "ACT08", "ACT09", "ACT10_ACT11", "ACT12"]
    static let stickOrder = ["up", "right", "down", "left"]

    static let defaults = CodexMicroLayout(
        slots: [
            "ACT06": KeyBinding(keycapId: "FAST", commandId: nil),
            "ACT07": KeyBinding(keycapId: "APPR", commandId: nil),
            "ACT08": KeyBinding(keycapId: "REJ", commandId: nil),
            "ACT09": KeyBinding(keycapId: "SPLIT", commandId: nil),
            "ACT10_ACT11": KeyBinding(keycapId: "MIC", commandId: nil),
            "ACT12": KeyBinding(keycapId: "CODEX", commandId: nil),
        ],
        analogStick: [
            "up": StickAction(type: "command", commandId: "composer.togglePlanMode"),
            "right": StickAction(type: "command", commandId: "navigateForward"),
            "down": StickAction(type: "command", commandId: "toggleSidebar"),
            "left": StickAction(type: "command", commandId: "navigateBack"),
        ],
        encoderMode: "composer-navigation"
    )

    /// The binding for a slot, tolerating unknown/partial sync payloads.
    func binding(forSlot slot: String) -> KeyBinding {
        slots[slot] ?? CodexMicroLayout.defaults.slots[slot] ?? KeyBinding(keycapId: slot, commandId: nil)
    }

    /// The action for a stick direction, defaulting like the desktop app.
    func action(forDirection direction: String) -> StickAction? {
        analogStick[direction] ?? CodexMicroLayout.defaults.analogStick[direction]
    }
}

enum MacConnectionState: String {
    case starting
    case waitingForMac
    case transportConnected
    case waitingForChatGPT
    case handshaking
    case operational
    case recovering
    case error

    var isOperational: Bool { self == .operational }
}

@MainActor
final class CodexMicroPeripheral: NSObject, ObservableObject {
    // MARK: Published state
    @Published var managerState: CBManagerState = .unknown
    @Published var isAdvertising = false
    @Published var hostConnected = false
    /// End-to-end health, not just CoreBluetooth subscription state. The UI is
    /// green only after a real ChatGPT request completes a round trip through
    /// the helper and this iPhone.
    @Published private(set) var macConnectionState: MacConnectionState = .starting
    @Published private(set) var macConnectionDetail = "Starting Bluetooth"
    @Published private(set) var publishedServicesReady = false
    @Published private(set) var blockingIssue: String?
    /// True when iOS refused the HID service and the app is exposing the
    /// custom bridge service for the Mac helper instead.
    @Published private(set) var bridgeMode = false
    @Published var slots = Array(repeating: SlotLight(), count: 6)
    @Published var ambient = ZoneLight()
    @Published var keysZone = ZoneLight()
    /// Increments whenever the host drives the underglow/backlight zones. The
    /// mic snake now reads the decoded voice state directly (`hostVoiceLighting`)
    /// rather than this raw tick, but it is kept as a lightweight "host touched
    /// the lighting" signal for diagnostics and future consumers.
    @Published private(set) var hostLightingTick = 0
    /// Key bindings synced from ChatGPT's ~/.codex/config.toml by the Mac
    /// bridge (channel-3 settings reports). Desktop defaults until first sync.
    @Published private(set) var layout: CodexMicroLayout = .defaults
    @Published var focusedApp: String?
    /// Live VS Code state is sent by CodexMicroBridge on private channel 3.
    /// It is deliberately separate from the Codex layout/status protocol so
    /// swiping between pages never changes ChatGPT's own configuration.
    @Published private(set) var workspaceStates: [String: WorkspaceBridgeState] = [
        "vscode": WorkspaceBridgeState(),
        "t3code": WorkspaceBridgeState(),
        "claude-desktop": WorkspaceBridgeState(),
    ]
    @Published var logEntries: [String] = []
    @Published var batteryPercent = 100
    /// Bumped whenever the app becomes active. The view uses this to rebuild
    /// the LED surfaces because iOS can preserve a stale GPU snapshot for
    /// animated/composited layers across suspension until the next touch.
    @Published private(set) var foregroundRenderGeneration = 0
    /// The single lighting-brightness value (0–1) reported by ChatGPT through
    /// `v.oai.rgbcfg`. Nil means the host has not reported its setting yet.
    /// Brightness is configured only in ChatGPT's Codex Micro settings.
    @Published private(set) var lightingBrightness: Double?
    private var hasSyncedDesktopBrightness = false

    var canControlChatGPT: Bool {
        hostConnected && macConnectionState.isOperational
    }

    /// Ground truth for the microphone snake, decoded from the ambient zone the
    /// host drives during dictation. Sea-green snake means recording, white
    /// snake means speech processing, solid white means the prompt is ready;
    /// every other colour/effect (idle underglow, a working chat's
    /// status-coloured snake, off) is not a voice state. Because `ambient` and
    /// `hostConnected` are `@Published`, SwiftUI re-reads this whenever the Mac
    /// changes the lighting.
    var hostVoiceLighting: HostVoiceLighting {
        guard hostConnected else { return .none }
        switch ambient.effect {
        case 2: // snake
            if Self.isRecordingGreen(ambient.color) { return .recording }
            if ambient.color == 0xFFFFFF { return .processing }
            return .none
        case 1: // solid
            return ambient.color == 0xFFFFFF ? .ready : .none
        default:
            return .none
        }
    }

    /// The sea-green recording colour is `#2E8B57` (docs §Voice and global
    /// lighting). Matched with a small per-channel tolerance so brightness
    /// rounding or a slightly different host build can't drop the recording
    /// state. The tolerance stays well clear of every agent status colour
    /// (complete `#00FF4C`, thinking `#304FFE`, …), so it never false-positives.
    nonisolated static func isRecordingGreen(_ color: UInt32) -> Bool {
        let r = Int((color >> 16) & 0xFF)
        let g = Int((color >> 8) & 0xFF)
        let b = Int(color & 0xFF)
        return abs(r - 0x2E) <= 32 && abs(g - 0x8B) <= 32 && abs(b - 0x57) <= 32
    }

    // MARK: BLE
    private var pm: CBPeripheralManager!
    private var inputChar: CBMutableCharacteristic!
    private var outputChar: CBMutableCharacteristic!
    private var batteryChar: CBMutableCharacteristic!
    private var protocolModeChar: CBMutableCharacteristic!
    private var controlPointChar: CBMutableCharacteristic!
    private var servicesToPublish: [CBMutableService] = []
    private var servicePublishIndex = 0
    private var inputSubscribers: [UUID: CBCentral] = [:]
    private var pendingReports: [Data] = []
    private var rpcBuffer = Data()
    private var configBuffer = Data()
    private var lastInputReport = Data(count: 63)
    private var lastOutputReport = Data(count: 63)
    private var protocolMode: UInt8 = 0x01
    private var isSuspended = false
    private var foregroundHeartbeat: Timer?
    private let foregroundHeartbeatInterval: TimeInterval = 8
    /// The page the user intends to control. This survives transport loss so a
    /// fresh Mac subscription cannot silently fall back to the wrong backend.
    private var desiredControlTarget = "chatgpt"
    /// Keep Codex lighting independent from all workspace pages. `slots` is the
    /// currently visible six-key snapshot retained for compatibility with the
    /// physical Codex rendering; page-specific UI reads `workspaceStates`.
    private var chatgptSlots = Array(repeating: SlotLight(), count: 6)

    /// The T3 Code page does NOT ride the Mac bridge. It talks straight to the
    /// open-source T3 server over the LAN through this in-app client, which
    /// republishes its snapshots into `workspaceStates["t3code"]` exactly like a
    /// bridge `workspace-state` frame would. Fully isolated from every other
    /// surface — no BLE, no channel 5, no ChatGPT wire.
    let t3 = T3DirectController()

    private let fwVersion = "0.1.0-ios-remote"
    private let maxPendingReports = 512
    private let maxRPCBufferBytes = 64 * 1024
    private let cachedSlotsKey = "codexMicro.lastKnownAgentLights.v1"
    /// Distinguishes a newly launched GATT server from cached advertisements
    /// for the previous process, so the Mac helper can refresh only stale links.
    private let advertisingSession = UInt16.random(in: UInt16.min...UInt16.max)

    /// Custom GATT bridge published when iOS refuses the real HID service.
    /// tools/CodexMicroBridge on the Mac subscribes to these characteristics
    /// and re-exposes the report stream as a local virtual HID device.
    static let bridgeServiceUUID = CBUUID(string: "C0DE0001-6E10-4C0D-A5A5-C0DEB1D6E001")
    static let bridgeInputUUID = CBUUID(string: "C0DE0002-6E10-4C0D-A5A5-C0DEB1D6E001")
    static let bridgeOutputUUID = CBUUID(string: "C0DE0003-6E10-4C0D-A5A5-C0DEB1D6E001")
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.sidepulse.codexmicroremote",
        category: "BLEPeripheral"
    )

    // HID report map: vendor-defined page 0xFF00, report ID 6, 63-byte in/out.
    private let reportMap: [UInt8] = [
        0x06, 0x00, 0xFF, 0x09, 0x01, 0xA1, 0x01, 0x85, 0x06,
        0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08, 0x95, 0x3F,
        0x09, 0x01, 0x81, 0x02, 0x95, 0x3F, 0x09, 0x02, 0x91,
        0x02, 0xC0,
    ]

    override init() {
        super.init()
        restoreCachedSlots()
        chatgptSlots = slots
        pm = CBPeripheralManager(delegate: self, queue: nil)
        UIDevice.current.isBatteryMonitoringEnabled = true
        refreshBattery()
        // Route the in-app T3 client's snapshots into the same isolated
        // per-surface state the board already renders. The closure runs on the
        // main thread (the backend's callback queue is `.main`).
        t3.onWorkspaceState = { [weak self] dict in
            MainActor.assumeIsolated { self?.applyWorkspaceState(dict, surface: "t3code") }
        }
        t3.onLog = { [weak self] message in
            MainActor.assumeIsolated { self?.log(message) }
        }
    }

    func log(_ message: String) {
        Self.logger.info("\(message, privacy: .public)")
#if DEBUG
        print("[CodexMicroBLE] \(message)")
#endif
        let stamp = Date().formatted(date: .omitted, time: .standard)
        logEntries.insert("\(stamp)  \(message)", at: 0)
        if logEntries.count > 300 { logEntries.removeLast(logEntries.count - 300) }
    }

    private func setMacConnection(_ state: MacConnectionState, detail: String) {
        guard macConnectionState != state || macConnectionDetail != detail else { return }
        macConnectionState = state
        macConnectionDetail = detail
        log("connection state: \(state.rawValue) — \(detail)")
    }

    // MARK: GATT

    private func buildServices() {
        let encRead: CBAttributePermissions = [.readable, .readEncryptionRequired]
        let encWrite: CBAttributePermissions = [.writeable, .writeEncryptionRequired]
        let encReadWrite: CBAttributePermissions = [
            .readable, .readEncryptionRequired, .writeable, .writeEncryptionRequired,
        ]

        pm.stopAdvertising()
        isAdvertising = false
        publishedServicesReady = false
        blockingIssue = nil
        inputSubscribers.removeAll()
        hostConnected = false
        setMacConnection(.starting, detail: "Publishing Bluetooth services")
        pendingReports.removeAll()
        rpcBuffer.removeAll()
        servicePublishIndex = 0
        bridgeMode = false

        let hidInfo = CBMutableCharacteristic(type: CBUUID(string: "2A4A"), properties: .read,
                                              value: Data([0x11, 0x01, 0x00, 0x01]), permissions: encRead)
        let mapChar = CBMutableCharacteristic(type: CBUUID(string: "2A4B"), properties: .read,
                                              value: Data(reportMap), permissions: encRead)
        controlPointChar = CBMutableCharacteristic(
            type: CBUUID(string: "2A4C"), properties: .writeWithoutResponse,
            value: nil, permissions: encWrite
        )
        protocolModeChar = CBMutableCharacteristic(
            type: CBUUID(string: "2A4E"), properties: [.read, .writeWithoutResponse],
            value: nil, permissions: encReadWrite
        )

        inputChar = CBMutableCharacteristic(type: CBUUID(string: "2A4D"),
                                            properties: [.read, .notify, .notifyEncryptionRequired], value: nil,
                                            permissions: encRead)
        outputChar = CBMutableCharacteristic(type: CBUUID(string: "2A4D"),
                                             properties: [.read, .write, .writeWithoutResponse], value: nil,
                                             permissions: encReadWrite)
        inputChar.descriptors = [CBMutableDescriptor(type: CBUUID(string: "2908"), value: Data([6, 0x01]))]
        outputChar.descriptors = [CBMutableDescriptor(type: CBUUID(string: "2908"), value: Data([6, 0x02]))]

        let hid = CBMutableService(type: CBUUID(string: "1812"), primary: true)
        hid.characteristics = [hidInfo, mapChar, controlPointChar, protocolModeChar, inputChar, outputChar]

        batteryChar = CBMutableCharacteristic(type: CBUUID(string: "2A19"),
                                              properties: [.read, .notify], value: nil, permissions: .readable)
        let battery = CBMutableService(type: CBUUID(string: "180F"), primary: true)
        battery.characteristics = [batteryChar]

        let manufacturer = CBMutableCharacteristic(type: CBUUID(string: "2A29"), properties: .read,
                                                   value: "Work Louder".data(using: .utf8), permissions: .readable)
        // PnP ID: source 0x02, VID 0x303A, PID 0x8360, release 0x0101 (all little-endian)
        let pnp = CBMutableCharacteristic(type: CBUUID(string: "2A50"), properties: .read,
                                          value: Data([0x02, 0x3A, 0x30, 0x60, 0x83, 0x01, 0x01]),
                                          permissions: .readable)
        let dis = CBMutableService(type: CBUUID(string: "180A"), primary: true)
        dis.characteristics = [manufacturer, pnp]

        // Publish serially. Advertising before every required service has completed
        // registration can make the UI claim success with an incomplete GATT table.
        servicesToPublish = [hid, battery, dis]
        publishNextService()
    }

    /// Fallback transport: a custom GATT service iOS will accept. The Mac
    /// helper (tools/CodexMicroBridge, run with sudo) subscribes to it and
    /// republishes the reports as a local virtual Codex Micro HID device.
    private func buildBridgeServices() {
        pm.stopAdvertising()
        isAdvertising = false
        publishedServicesReady = false
        blockingIssue = nil
        inputSubscribers.removeAll()
        hostConnected = false
        setMacConnection(.starting, detail: "Starting the Mac helper bridge")
        pendingReports.removeAll()
        rpcBuffer.removeAll()
        servicePublishIndex = 0
        bridgeMode = true

        inputChar = CBMutableCharacteristic(type: Self.bridgeInputUUID,
                                            properties: [.read, .notify], value: nil,
                                            permissions: .readable)
        outputChar = CBMutableCharacteristic(type: Self.bridgeOutputUUID,
                                             properties: [.read, .write, .writeWithoutResponse], value: nil,
                                             permissions: [.readable, .writeable])
        let bridge = CBMutableService(type: Self.bridgeServiceUUID, primary: true)
        bridge.characteristics = [inputChar, outputChar]

        // No Battery (0x180F) or Device Information service here: iOS reserves
        // those UUIDs for the system (CBErrorDomain 8, "UUID is not allowed").
        // The host reads battery through the device.status RPC instead, and
        // the Mac helper supplies the HID identity itself.
        servicesToPublish = [bridge]
        publishNextService()
    }

    private func publishNextService() {
        guard pm.state == .poweredOn else { return }
        guard servicePublishIndex < servicesToPublish.count else {
            publishedServicesReady = true
            blockingIssue = nil
            log("all required GATT services published")
            startAdvertising()
            return
        }
        let service = servicesToPublish[servicePublishIndex]
        log("publishing service \(service.uuid)")
        pm.add(service)
    }

    private func startAdvertising() {
        guard publishedServicesReady, !pm.isAdvertising else { return }
        setMacConnection(.waitingForMac, detail: "Waiting for the Mac helper")
        let sessionData = Data([
            0x43, 0x4D, // "CM"
            UInt8(advertisingSession & 0x00FF),
            UInt8(advertisingSession >> 8),
        ])
        pm.startAdvertising([
            CBAdvertisementDataLocalNameKey: "Codex Micro",
            CBAdvertisementDataServiceUUIDsKey: [
                bridgeMode ? Self.bridgeServiceUUID : CBUUID(string: "1812")
            ],
            CBAdvertisementDataManufacturerDataKey: sessionData,
        ])
    }

    private func isInputReportCharacteristic(_ characteristic: CBCharacteristic) -> Bool {
        characteristic === inputChar
            || characteristic.uuid == Self.bridgeInputUUID
            || (characteristic.uuid == CBUUID(string: "2A4D")
                && characteristic.properties.contains(.notify)
                && !characteristic.properties.contains(.write))
    }

    private func isOutputReportCharacteristic(_ characteristic: CBCharacteristic) -> Bool {
        characteristic === outputChar
            || characteristic.uuid == Self.bridgeOutputUUID
            || (characteristic.uuid == CBUUID(string: "2A4D")
                && characteristic.properties.contains(.write))
    }

    func stop() {
        pm.stopAdvertising()
        pm.removeAllServices()
        servicesToPublish.removeAll()
        servicePublishIndex = 0
        inputSubscribers.removeAll()
        pendingReports.removeAll()
        rpcBuffer.removeAll()
        isAdvertising = false
        publishedServicesReady = false
        hostConnected = false
        setMacConnection(.waitingForMac, detail: "Connection stopped")
    }

    // MARK: Battery

    private func refreshBattery() {
        let level = UIDevice.current.batteryLevel
        batteryPercent = level < 0 ? 100 : Int((level * 100).rounded())
    }

    // MARK: Device -> host events

    /// Send a `v.oai.hid` key event. act: 0 release, 1 press, 2 encoder step.
    func sendKey(_ key: String, action: Int, agent: Int? = nil) {
        guard hostConnected else {
            log("ignored \(key): no HID host subscribed")
            return
        }
        guard canControlChatGPT else {
            log("ignored \(key): ChatGPT connection is not operational")
            return
        }
        guard !isSuspended else {
            log("ignored \(key): HID host is suspended")
            return
        }
        var params: [String: Any] = ["k": key, "act": action]
        if let agent { params["ag"] = agent }
        sendJson(["method": "v.oai.hid", "params": params])
    }

    /// Clear the ChatGPT composer. The Codex Micro protocol has no composer-clear
    /// command, so this rides a SidePulse-only control channel (4) that the Mac
    /// shim consumes to run a host-side action; it is never forwarded to ChatGPT's
    /// device layer. See docs/codex-micro-protocol.md §7.
    func clearComposer() {
        sendControl(["cmd": "clearComposer"])
    }

    /// Inserts dictated/typed text straight into ChatGPT's composer. Like
    /// `clearComposer`, the Codex Micro protocol has no insert command, so this
    /// rides the SidePulse-only shim control channel (4): the Mac shim runs
    /// `webContents.insertText` inside ChatGPT's own renderer — no macOS
    /// Accessibility permission and no keystroke simulation. Used when the Codex
    /// microphone is set to "This iPhone": the phone records + transcribes
    /// on-device, then delivers the transcript here instead of driving ChatGPT's
    /// Mac-microphone push-to-talk. When `autoSend` is on, the CODEX submit key
    /// follows once the text has landed.
    func insertCodexComposer(_ text: String, autoSend: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sendControl(["cmd": "insertText", "text": trimmed])
        guard autoSend else { return }
        // Give the renderer a beat to apply the insertion before submitting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.sendKey("ACT12", action: 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                self?.sendKey("ACT12", action: 0)
            }
        }
    }

    // MARK: - T3 Code (direct LAN client)

    /// True once a T3 server has been paired.
    var t3IsPaired: Bool { t3.isPaired }

    /// Pair the T3 page to a server from a `…/pair#token=…` (or hosted) link.
    func pairT3(_ pairingURL: String, completion: @escaping @Sendable (Result<T3Environment, T3BackendIssue>) -> Void = { _ in }) {
        t3.pair(pairingURL: pairingURL, completion: completion)
    }

    /// Forget the paired T3 server.
    func unpairT3() {
        t3.unpair()
    }

    /// Clears a workspace composer through that surface's isolated desktop
    /// controller. Claude Desktop handles this with a guarded macOS
    /// Accessibility action; it never crosses ChatGPT's patched control path.
    func clearWorkspaceComposer(surface: String) {
        guard surface == "claude-desktop" else { return }
        sendBridgeControl([
            "cmd": "vscodeClearComposer",
            "surface": surface,
        ])
    }

    /// Selects which desktop integration receives subsequent hardware events.
    /// `auto` bridge mode can switch instantly; fixed legacy modes safely
    /// ignore the request and continue serving their configured target.
    func setControlTarget(_ target: String) {
        guard target == "chatgpt"
                || target == "vscode"
                || target == "t3code"
                || target == "claude-desktop" else { return }
        desiredControlTarget = target
        slots = target == "chatgpt"
            ? chatgptSlots
            : workspaceState(for: target).slots
        // The T3 page is a direct LAN client, not a bridge surface: switching to
        // it starts the in-app poll loop and never announces itself on channel 5.
        // Switching away pauses that loop to save battery.
        if target == "t3code" {
            t3.activate()
            return
        }
        t3.deactivate()
        sendBridgeControl(["cmd": "setControlTarget", "target": target])
    }

    /// A VS Code-page key event, carried on the private bridge channel (5)
    /// instead of the Codex HID channel (2). This keeps the VS Code control
    /// surface completely off the ChatGPT/Codex wire: the desktop bridge never
    /// has to reroute the shared HID stream by page, so Codex can never be
    /// affected by anything the VS Code page does. The desktop replays these as
    /// the same `v.oai.hid` events its VS Code controller already understands.
    func sendVSCodeKey(_ key: String, action: Int, agent: Int? = nil, surface: String = "vscode") {
        if surface == "t3code" {
            t3.handleKey(key, action: action, agent: agent)
            return
        }
        var object: [String: Any] = [
            "cmd": "vscodeKey", "surface": surface, "k": key, "act": action,
        ]
        if let agent { object["ag"] = agent }
        sendBridgeControl(object)
    }

    func createVSCodeSession(kind: String, value: String, label: String, surface: String = "vscode") {
        if surface == "t3code" {
            // NEW opens a fresh chat in the T3 desktop app on macOS and brings it
            // to the front, via the desktop app's registered `t3code://` handler
            // (relayed through the Mac helper). `t3code://app/` lands the desktop
            // app straight in a new draft chat.
            openMacURL("t3code://app/", surface: "t3code")
            return
        }
        sendBridgeControl([
            "cmd": "vscodeNew", "surface": surface,
            "kind": kind, "value": value, "label": label,
        ])
    }

    /// Pin/unpin a VS Code target. Passing the explicit target the UI shows as
    /// selected avoids the desktop toggling a stale "last focused" target.
    func toggleVSCodePin(
        targetID: String? = nil,
        targetLabel: String? = nil,
        surface: String = "vscode"
    ) {
        if surface == "t3code" {
            t3.togglePin(targetID: targetID)
            return
        }
        var object: [String: Any] = ["cmd": "vscodeTogglePin", "surface": surface]
        if let targetID, !targetID.isEmpty { object["target"] = targetID }
        if let targetLabel, !targetLabel.isEmpty { object["label"] = targetLabel }
        sendBridgeControl(object)
    }

    /// Delivers iPhone transcription to the target captured when recording
    /// began. Auto-send is handled as one ordered desktop operation so a user
    /// can switch agents during recognition without redirecting the prompt.
    func insertVSCodePrompt(
        _ text: String,
        targetID: String? = nil,
        autoSend: Bool = false,
        surface: String = "vscode"
    ) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if surface == "t3code" {
            // Dictated/typed text becomes a turn on the selected T3 thread.
            t3.sendPrompt(text, to: targetID)
            return
        }
        var command: [String: Any] = [
            "cmd": "vscodeInsert",
            "surface": surface,
            "text": text,
            "submit": autoSend,
        ]
        if let targetID, !targetID.isEmpty { command["target"] = targetID }
        sendBridgeControl(command)
    }

    /// Starts or stops provider-native voice capture for one concrete editor
    /// target. The extension rejects this command for terminals, file tabs,
    /// and providers that do not expose a voice API.
    func setVSCodeNativeVoice(_ active: Bool, targetID: String? = nil, surface: String = "vscode") {
        // T3 dictation is delivered as transcribed text (insertVSCodePrompt); it
        // has no provider-native push-to-talk to arm.
        guard surface != "t3code" else { return }
        var command: [String: Any] = [
            "cmd": "vscodeVoice",
            "surface": surface,
            "active": active,
        ]
        if let targetID, !targetID.isEmpty { command["target"] = targetID }
        sendBridgeControl(command)
    }

    /// Raise the desktop editor app that owns `targetID` to the front (macOS app
    /// activation). Sent when the user double-taps an agent key so the workspace
    /// isn't just focused inside VS Code but the whole app is brought forward.
    /// Best-effort: the bridge activates the app by the bundle id the extension
    /// reported for that target, falling back to the current selection's app.
    func raiseWorkspaceApp(surface: String = "vscode", targetID: String? = nil) {
        // A local T3 server has no front-facing desktop app to raise.
        guard surface != "t3code" else { return }
        var object: [String: Any] = ["cmd": "vscodeRaise", "surface": surface]
        if let targetID, !targetID.isEmpty { object["target"] = targetID }
        sendBridgeControl(object)
    }

    /// Ask the Mac helper to open (and focus) a URL on macOS. Used by the T3
    /// page's NEW key to launch a fresh chat in the T3 desktop app via its
    /// `t3code://` handler. Requires the CodexMicroBridge helper to be running;
    /// if it isn't, the frame is simply never delivered (harmless no-op).
    func openMacURL(_ url: String, surface: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sendBridgeControl(["cmd": "openURL", "surface": surface, "url": trimmed])
    }

    func workspaceState(for surface: String) -> WorkspaceBridgeState {
        workspaceStates[surface] ?? WorkspaceBridgeState()
    }

    // Compatibility accessors for code/tests that still use the original VS
    // Code-specific names. Their source of truth is the isolated state map.
    var vscodeTargets: [VSCodeTarget] { workspaceState(for: "vscode").targets }
    var vscodePins: [String?] { workspaceState(for: "vscode").pins }
    var vscodeSelectedTargetID: String? { workspaceState(for: "vscode").selectedTargetID }
    var vscodeExtensionConnected: Bool { workspaceState(for: "vscode").connected }

    /// Refresh both halves of the foreground experience: rebuild SwiftUI's
    /// composited LED layers and ask the Mac bridge to replay the most recent
    /// semantic Agent Key state. This is side-effect-free in ChatGPT and does
    /// not fake a key press merely to wake lighting.
    func applicationDidBecomeActive() {
        foregroundRenderGeneration &+= 1
        refreshBattery()
        // Resume the T3 poll loop if the user is on that page (it was paused on
        // resign so it never polls the LAN from the background).
        if desiredControlTarget == "t3code" { t3.activate() }
        requestLatestHostState()
        startForegroundHeartbeat()
    }

    /// The app left the foreground. Stop the heartbeat so it never runs in the
    /// background (where the BLE link is torn down anyway).
    func applicationWillResignActive() {
        stopForegroundHeartbeat()
        t3.deactivate()
    }

    private func requestLatestHostState() {
        // The T3 page is off-bridge: refresh its direct client instead of
        // asking the Mac helper to replay a surface it no longer proxies.
        if desiredControlTarget == "t3code" {
            t3.refresh()
            return
        }
        // Include the durable page choice in every refresh. A BLE notification
        // can be lost at the exact subscription boundary; the foreground
        // heartbeat therefore also acts as an idempotent routing handshake.
        sendBridgeControl([
            "cmd": "refreshState",
            "target": desiredControlTarget,
        ])
    }

    /// Keep the agent lights honest while the app sits in the foreground.
    /// ChatGPT's hardware lighting has an auto-off timer and a single dropped
    /// host frame would otherwise leave the LEDs frozen until the next touch.
    /// A light heartbeat re-requests the latest host state (ChatGPT replays its
    /// cached agent status; the VSCode bridge re-emits SidePulse status), so the
    /// LEDs always converge back to the truth without faking any key press.
    private func startForegroundHeartbeat() {
        stopForegroundHeartbeat()
        let timer = Timer(timeInterval: foregroundHeartbeatInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.hostConnected, !self.isSuspended else { return }
                self.requestLatestHostState()
            }
        }
        timer.tolerance = 2 // batch wake-ups; this is a freshness poll, not a deadline
        RunLoop.main.add(timer, forMode: .common)
        foregroundHeartbeat = timer
    }

    private func stopForegroundHeartbeat() {
        foregroundHeartbeat?.invalidate()
        foregroundHeartbeat = nil
    }

    /// Send a SidePulse-only control message to the Mac shim on channel 4 (not
    /// part of the Codex Micro wire protocol).
    private func sendControl(_ object: [String: Any]) {
        guard canControlChatGPT else {
            log("ignored control request: ChatGPT connection is not operational")
            return
        }
        sendPrivateMessage(object, channel: 4, description: "control")
    }

    /// Channel 5 terminates in CodexMicroBridge and never reaches ChatGPT. It
    /// is used for bridge lifecycle requests such as replaying cached state.
    private func sendBridgeControl(_ object: [String: Any]) {
        var envelope = object
        // CoreBluetooth may replay a notification around a subscription
        // hand-off. Every logical command gets one id so the helper can make
        // toggles, NEW, and SEND idempotent instead of executing the replay.
        if envelope["commandID"] == nil { envelope["commandID"] = UUID().uuidString }
        sendPrivateMessage(
            envelope,
            channel: 5,
            description: "bridge",
            terminateWithNewline: true
        )
    }

    private func sendPrivateMessage(
        _ object: [String: Any],
        channel: UInt8,
        description: String,
        terminateWithNewline: Bool = false
    ) {
        guard hostConnected else {
            log("deferred \(description) request: no HID host subscribed")
            return
        }
        guard !isSuspended else {
            log("deferred \(description) request: HID host is suspended")
            return
        }
        guard var payload = try? JSONSerialization.data(withJSONObject: object) else {
            log("could not encode \(description) JSON")
            return
        }
        if terminateWithNewline { payload.append(0x0A) }
        var reports: [Data] = []
        var offset = 0
        while offset < payload.count {
            let chunk = min(61, payload.count - offset)
            var report = Data(count: 63)
            report[0] = channel // 4 = shim control, 5 = Mac bridge lifecycle
            report[1] = UInt8(chunk)
            report.replaceSubrange(2..<(2 + chunk), with: payload.subdata(in: offset..<(offset + chunk)))
            reports.append(report)
            offset += chunk
        }
        guard pendingReports.count + reports.count <= maxPendingReports else {
            log("outbound report queue full; dropped a \(description) message")
            return
        }
        pendingReports.append(contentsOf: reports)
        flushPendingReports()
        log("dev→host(\(description)) \(String(data: payload, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")")
    }

    /// Send a `v.oai.rad` joystick event. angle in turns (right 0, down .25, left .5, up .75).
    func sendJoystick(angle: Double, distance: Double) {
        guard hostConnected else {
            log("ignored joystick: no HID host subscribed")
            return
        }
        guard canControlChatGPT else {
            log("ignored joystick: ChatGPT connection is not operational")
            return
        }
        guard !isSuspended else {
            log("ignored joystick: HID host is suspended")
            return
        }
        guard angle.isFinite, distance.isFinite else {
            log("ignored joystick: non-finite value")
            return
        }
        let remainder = angle.truncatingRemainder(dividingBy: 1)
        let normalizedAngle = remainder < 0 ? remainder + 1 : remainder
        let clampedDistance = min(max(distance, 0), 1)
        sendJson(["method": "v.oai.rad", "params": ["a": normalizedAngle, "d": clampedDistance]])
    }

    /// Frame + chunk + notify a JSON message (newline-terminated, 61-byte chunks).
    private func sendJson(_ object: [String: Any]) {
        guard var payload = try? JSONSerialization.data(withJSONObject: object) else {
            log("could not encode outbound JSON")
            return
        }
        payload.append(0x0A)
        var reports: [Data] = []
        var offset = 0
        while offset < payload.count {
            let chunk = min(61, payload.count - offset)
            var report = Data(count: 63)
            report[0] = 2 // RPC channel (1 = debug log)
            report[1] = UInt8(chunk)
            report.replaceSubrange(2..<(2 + chunk), with: payload.subdata(in: offset..<(offset + chunk)))
            reports.append(report)
            offset += chunk
        }
        guard pendingReports.count + reports.count <= maxPendingReports else {
            log("outbound report queue full; dropped one complete JSON message")
            return
        }
        pendingReports.append(contentsOf: reports)
        flushPendingReports()
        log("dev→host \(String(data: payload, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")")
    }

    private func flushPendingReports() {
        let subscribers = Array(inputSubscribers.values)
        guard publishedServicesReady, !subscribers.isEmpty, !pendingReports.isEmpty else { return }
        var sent = 0
        for report in pendingReports {
            if !pm.updateValue(report, for: inputChar, onSubscribedCentrals: subscribers) { break }
            lastInputReport = report
            sent += 1
        }
        if sent > 0 { pendingReports.removeFirst(sent) }
    }

    // MARK: Host -> device (output report writes)

    private func handleOutputReport(_ data: Data) {
        // GATT values omit the report ID. Accept a 64-byte HIDAPI-style value too
        // for diagnostics, but rebase the Data indices after removing its prefix.
        var body = Data(data)
        if data.count == 64, data.first == 6 { body = Data(data.dropFirst()) }
        guard body.count >= 2 else {
            log("ignored short output report (\(body.count) bytes)")
            return
        }
        let channel = body[body.startIndex]
        if channel == 3 {
            handleConfigReport(body)
            return
        }
        guard channel == 2 else {
            log("ignored output report on channel \(channel)")
            return
        }
        let lengthIndex = body.index(after: body.startIndex)
        let len = Int(body[lengthIndex])
        guard len <= 61, body.count >= 2 + len else {
            log("ignored malformed output report (declared \(len), received \(body.count - 2))")
            return
        }
        let fragment = body.subdata(in: 2..<(2 + len))
        let fragmentText = String(data: fragment, encoding: .utf8)
        if !rpcBuffer.isEmpty,
           (fragmentText?.hasPrefix("{\"method\"") == true || fragmentText?.hasPrefix("{\"m\"") == true) {
            rpcBuffer.removeAll() // resync after a dropped fragmented request
        }
        rpcBuffer.append(fragment)
        guard rpcBuffer.count <= maxRPCBufferBytes else {
            log("discarded oversized RPC frame")
            rpcBuffer.removeAll()
            return
        }

        // Device-to-host messages are newline-delimited, but the current desktop
        // SDK sends host requests as bare JSON split across reports. Accept
        // newline-delimited compatibility senders first, then treat the remaining
        // buffer as complete as soon as JSONSerialization can decode it.
        while let newline = rpcBuffer.firstIndex(of: 0x0A) {
            var line = Data(rpcBuffer[..<newline])
            rpcBuffer.removeSubrange(...newline)
            if line.last == 0x0D { line.removeLast() }
            guard !line.isEmpty else { continue }
            processRpcJSON(line)
        }

        if !rpcBuffer.isEmpty,
           let object = try? JSONSerialization.jsonObject(with: rpcBuffer) as? [String: Any] {
            let complete = rpcBuffer
            rpcBuffer.removeAll()
            log("host→dev \(String(data: complete, encoding: .utf8) ?? "<non-UTF-8 JSON>")")
            handleRpc(object)
        }
    }

    private func processRpcJSON(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log("discarded malformed RPC JSON")
            return
        }
        log("host→dev \(String(data: data, encoding: .utf8) ?? "<non-UTF-8 JSON>")")
        handleRpc(object)
    }

    /// Channel-3 settings reports from the Mac bridge (not part of the real
    /// device protocol): chunked bare JSON carrying layout and brightness.
    private func handleConfigReport(_ body: Data) {
        let lengthIndex = body.index(after: body.startIndex)
        let len = Int(body[lengthIndex])
        guard len <= 61, body.count >= 2 + len else {
            log("ignored malformed config report (declared \(len), received \(body.count - 2))")
            return
        }
        let fragment = body.subdata(in: 2..<(2 + len))
        if !configBuffer.isEmpty,
           String(data: fragment, encoding: .utf8)?.hasPrefix("{\"type\"") == true {
            configBuffer.removeAll() // resync after a dropped fragmented message
        }
        configBuffer.append(fragment)
        guard configBuffer.count <= maxRPCBufferBytes else {
            log("discarded oversized config frame")
            configBuffer.removeAll()
            return
        }
        guard let object = try? JSONSerialization.jsonObject(with: configBuffer) as? [String: Any] else {
            return // wait for more fragments
        }
        configBuffer.removeAll()
        switch object["type"] as? String {
        case "codex-micro-layout":
            applyLayout(object)
            let brightness = lightingBrightness.map { " · brightness \(Int(($0 * 100).rounded()))%" } ?? ""
            log("layout synced: \(CodexMicroLayout.slotOrder.map { layout.binding(forSlot: $0).keycapId }.joined(separator: " "))\(brightness)")
        case "codex-micro-state":
            if let array = object["slots"] as? [[String: Any]] {
                updateSlots(array, surface: "chatgpt")
                log("agent lighting refreshed from Mac bridge")
            }
            if let zones = object["zones"] as? [String: Any] {
                updateZones(zones)
            }
        case "connection-health":
            applyConnectionHealth(object)
        case "vscode-state":
            applyWorkspaceState(object, surface: "vscode")
        case "workspace-state":
            guard let surface = object["surface"] as? String,
                  workspaceStates[surface] != nil else {
                log("ignored workspace state with invalid surface")
                return
            }
            applyWorkspaceState(object, surface: surface)
        default:
            log("ignored unknown config message")
        }
    }

    private func applyConnectionHealth(_ object: [String: Any]) {
        let detail = object["detail"] as? String
        switch object["state"] as? String {
        case "transport-connected":
            setMacConnection(.transportConnected, detail: detail ?? "Mac helper linked")
        case "waiting-for-chatgpt":
            setMacConnection(.waitingForChatGPT, detail: detail ?? "Waiting for ChatGPT")
        case "handshaking":
            setMacConnection(.handshaking, detail: detail ?? "Checking ChatGPT")
        case "operational":
            setMacConnection(.operational, detail: detail ?? "ChatGPT round trip succeeded")
        case "recovering":
            setMacConnection(.recovering, detail: detail ?? "Recovering connection")
        default:
            setMacConnection(.error, detail: detail ?? "Unknown connection-health response")
        }
    }

    private func applyWorkspaceState(_ object: [String: Any], surface: String) {
        var state = workspaceState(for: surface)
        state.connected = object["connected"] as? Bool ?? false
        state.selectedTargetID = object["selected"] as? String
        state.nativeVoiceActive = object["nativeVoiceActive"] as? Bool ?? false
        state.issue = object["issue"] as? String

        if let targets = object["targets"] as? [[String: Any]] {
            state.targets = targets.compactMap { entry in
                guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
                return VSCodeTarget(
                    id: id,
                    kind: entry["kind"] as? String ?? "unknown",
                    label: entry["label"] as? String ?? id,
                    provider: entry["provider"] as? String ?? "editor",
                    active: entry["active"] as? Bool ?? false,
                    nativeVoice: entry["nativeVoice"] as? Bool ?? false
                )
            }
        }

        if let values = object["pins"] as? [Any] {
            var next = Array<String?>(repeating: nil, count: 6)
            for (index, value) in values.prefix(6).enumerated() {
                if let id = value as? String, !id.isEmpty { next[index] = id }
            }
            state.pins = next
        }

        if let values = object["slots"] as? [[String: Any]] {
            state.slots = applyingSlotUpdates(values, to: state.slots)
        }

        workspaceStates[surface] = state
        if desiredControlTarget == surface { slots = state.slots }
    }

    private func applyLayout(_ object: [String: Any]) {
        var next = CodexMicroLayout.defaults
        if let slots = object["slots"] as? [String: [String: Any]] {
            for (name, entry) in slots where CodexMicroLayout.slotOrder.contains(name) {
                guard let keycapId = entry["keycapId"] as? String else { continue }
                next.slots[name] = KeyBinding(keycapId: keycapId, commandId: entry["commandId"] as? String)
            }
        }
        if let stick = object["analogStick"] as? [String: [String: Any]] {
            for (dir, entry) in stick where CodexMicroLayout.stickOrder.contains(dir) {
                next.analogStick[dir] = StickAction(
                    type: entry["type"] as? String ?? "command",
                    commandId: entry["commandId"] as? String,
                    skillName: entry["skillName"] as? String,
                    skillPath: entry["skillPath"] as? String
                )
            }
        }
        if let encoderMode = object["encoderMode"] as? String {
            next.encoderMode = encoderMode
        }
        if let percent = numericDouble(object["lightingBrightness"]) {
            lightingBrightness = min(max(percent, 0), 100) / 100
            hasSyncedDesktopBrightness = true
        }
        layout = next
    }

    private func handleRpc(_ object: [String: Any]) {
        let id = object["id"] ?? object["i"]
        let method = object["method"] as? String ?? object["m"] as? String ?? ""
        switch method {
        case "sys.version":
            sendResult(["version": fwVersion], id: id)
        case "device.status":
            refreshBattery()
            sendResult([
                "version": fwVersion, "profile_index": 0, "layer_index": 1,
                "battery": batteryPercent,
                "is_charging": UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full,
            ], id: id)
        case "v.oai.thstatus":
            guard let array = object["params"] as? [[String: Any]] else {
                sendError(code: -32602, message: "Invalid params", id: id)
                return
            }
            updateSlots(array, surface: desiredControlTarget)
            sendResult(["ok": true], id: id)
        case "v.oai.rgbcfg":
            guard let params = object["params"] as? [String: Any] else {
                sendError(code: -32602, message: "Invalid params", id: id)
                return
            }
            updateZones(params)
            sendResult(["ok": true], id: id)
        case "lights.preview":
            if let params = object["params"] as? [String: Any] { updateZones(params) }
            sendResult(["ok": true], id: id)
        case "host.focused_app":
            if let params = object["params"] as? [String: Any] {
                focusedApp = params["app"] as? String
                    ?? params["appName"] as? String
                    ?? params["name"] as? String
                    ?? params["process"] as? String
                    ?? params["path"] as? String
                    ?? params["bundleId"] as? String
                    ?? params["bundle_id"] as? String
                    ?? params.description
            } else if let params = object["params"] as? String {
                focusedApp = params
            }
            sendResult(["ok": true], id: id)
        default:
            sendError(code: -32601, message: "Method not found", id: id)
        }
    }

    private func sendResult(_ result: Any, id: Any?) {
        guard let id else { return } // JSON-RPC notifications do not receive responses.
        sendJson(["id": id, "result": result])
    }

    private func sendError(code: Int, message: String, id: Any?) {
        guard let id else { return }
        sendJson(["id": id, "error": ["code": code, "message": message]])
    }

    private func updateZones(_ params: [String: Any]) {
        let ambientValue = params["ambient"] as? [String: Any]
            ?? params["underglow"] as? [String: Any]
        let keysValue = params["keys"] as? [String: Any]
            ?? params["backlight"] as? [String: Any]

        if let value = ambientValue {
            ambient = ZoneLight(value)
        }
        if let value = keysValue {
            keysZone = ZoneLight(value)
        }

        // Channel 3 carries the durable desktop setting. A direct HID host has
        // no private config channel, so fall back to the ambient zone there;
        // the generic key zone can legitimately be 0 while agent LEDs are lit.
        let brightnessValue = ambientValue?["b"] ?? ambientValue?["brightness"]
            ?? keysValue?["b"] ?? keysValue?["brightness"]
        if !hasSyncedDesktopBrightness, let value = numericDouble(brightnessValue) {
            lightingBrightness = min(max(value, 0), 1)
        }
        hostLightingTick &+= 1
    }

    private func updateSlots(_ array: [[String: Any]], surface: String? = nil) {
        let surface = surface ?? desiredControlTarget
        if surface != "chatgpt", workspaceStates[surface] != nil {
            var state = workspaceState(for: surface)
            state.slots = applyingSlotUpdates(array, to: state.slots)
            workspaceStates[surface] = state
            if desiredControlTarget == surface { slots = state.slots }
            return
        }

        chatgptSlots = applyingSlotUpdates(array, to: chatgptSlots)
        if desiredControlTarget == "chatgpt" { slots = chatgptSlots }
        persistSlots()
    }

    private func applyingSlotUpdates(_ array: [[String: Any]], to current: [SlotLight]) -> [SlotLight] {
        var next = current.count == 6 ? current : Array(repeating: SlotLight(), count: 6)
        for entry in array {
            guard let id = numericInt(entry["id"]), (0..<6).contains(id) else { continue }
            var light = next[id]
            if let c = packedRGB(entry["c"]) { light.color = c }
            if let b = numericDouble(entry["b"]) { light.brightness = min(max(b, 0), 1) }
            if let e = numericInt(entry["e"]) { light.effect = min(max(e, 0), 6) }
            else if let e = entry["e"] as? String { light.effect = Self.effectId(forName: e) }
            if let s = numericDouble(entry["s"]) { light.speed = min(max(s, 0), 1) }
            next[id] = light
        }
        return next
    }

    private func restoreCachedSlots() {
        guard let data = UserDefaults.standard.data(forKey: cachedSlotsKey),
              let cached = try? JSONDecoder().decode([SlotLight].self, from: data),
              cached.count == 6 else { return }
        slots = cached
    }

    private func persistSlots() {
        guard let data = try? JSONEncoder().encode(chatgptSlots) else { return }
        UserDefaults.standard.set(data, forKey: cachedSlotsKey)
    }

    /// Tolerate firmware-style string effects in addition to the numeric enum.
    nonisolated fileprivate static func effectId(forName name: String) -> Int {
        switch name.lowercased() {
        case "solid": return 1
        case "snake": return 2
        case "rainbow": return 3
        case "breath": return 4
        case "gradient": return 5
        case "shallowbreath", "shallow_breath", "shallow-breath": return 6
        default: return 0
        }
    }
}

private extension ZoneLight {
    init(_ dict: [String: Any]) {
        let colorValue = dict["c"] ?? dict["color"]
        let brightnessValue = dict["b"] ?? dict["brightness"]
        let effectValue = dict["e"] ?? dict["effect"]
        let speedValue = dict["s"] ?? dict["speed"]
        if let c = packedRGB(colorValue) { color = c }
        if let b = numericDouble(brightnessValue) { brightness = min(max(b, 0), 1) }
        if let e = numericInt(effectValue) { effect = min(max(e, 0), 6) }
        else if let e = effectValue as? String { effect = CodexMicroPeripheral.effectId(forName: e) }
        if let s = numericDouble(speedValue) { speed = min(max(s, 0), 1) }
    }
}

private func numericDouble(_ value: Any?) -> Double? {
    if let number = value as? NSNumber { return number.doubleValue }
    if let number = value as? Double { return number }
    return nil
}

private func numericInt(_ value: Any?) -> Int? {
    if let number = value as? NSNumber { return number.intValue }
    if let number = value as? Int { return number }
    return nil
}

private func packedRGB(_ value: Any?) -> UInt32? {
    guard let number = numericInt(value) else { return nil }
    return UInt32(min(max(number, 0), 0xFF_FF_FF))
}

// MARK: - CBPeripheralManagerDelegate

extension CodexMicroPeripheral: CBPeripheralManagerDelegate {
    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        Task { @MainActor in
            managerState = peripheral.state
            log("BLE state \(peripheral.state.rawValue)")
            guard peripheral.state == .poweredOn else {
                isAdvertising = false
                publishedServicesReady = false
                inputSubscribers.removeAll()
                hostConnected = false
                pendingReports.removeAll()
                rpcBuffer.removeAll()
                servicesToPublish.removeAll()
                servicePublishIndex = 0
                switch peripheral.state {
                case .poweredOff:
                    blockingIssue = "Turn on Bluetooth to start Codex Micro."
                    setMacConnection(.error, detail: "Bluetooth is off")
                case .unauthorized:
                    blockingIssue = "Bluetooth access is denied. Allow it in Settings to continue."
                    setMacConnection(.error, detail: "Bluetooth permission is denied")
                case .unsupported:
                    blockingIssue = "This device does not support Bluetooth peripheral mode."
                    setMacConnection(.error, detail: "Bluetooth peripheral mode is unavailable")
                default:
                    blockingIssue = nil
                    setMacConnection(.starting, detail: "Bluetooth is starting")
                }
                return
            }

            peripheral.stopAdvertising()
            peripheral.removeAllServices()
            buildServices()
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        Task { @MainActor in
            guard servicePublishIndex < servicesToPublish.count,
                  service === servicesToPublish[servicePublishIndex] else {
                log("ignored stale service callback for \(service.uuid)")
                return
            }

            if let error {
                let nsError = error as NSError
                log("add service \(service.uuid) error: \(nsError.domain) \(nsError.code) — \(nsError.localizedDescription)")
                if service.uuid == CBUUID(string: "1812"), !bridgeMode {
                    // iOS refuses app-published HID services. Fall back to the
                    // custom GATT bridge that tools/CodexMicroBridge re-exposes
                    // on the Mac as a virtual Codex Micro HID device.
                    log("HID service unavailable — switching to Mac-helper bridge mode")
                    pm.removeAllServices()
                    buildBridgeServices()
                    return
                }
                publishedServicesReady = false
                isAdvertising = false
                blockingIssue = publicationFailureMessage(service: service, error: nsError)
                return
            }

            log("published service \(service.uuid)")
            servicePublishIndex += 1
            publishNextService()
        }
    }

    nonisolated func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        Task { @MainActor in
            guard publishedServicesReady else {
                peripheral.stopAdvertising()
                isAdvertising = false
                log("ignored advertising callback because required services are incomplete")
                return
            }
            if let error {
                let nsError = error as NSError
                isAdvertising = false
                blockingIssue = "Bluetooth advertising failed: \(nsError.localizedDescription)"
                setMacConnection(.error, detail: "Bluetooth advertising failed")
                log("advertising error: \(nsError.domain) \(nsError.code) — \(nsError.localizedDescription)")
            } else {
                isAdvertising = peripheral.isAdvertising
                blockingIssue = nil
                setMacConnection(.waitingForMac, detail: "Waiting for the Mac helper")
                log("advertising as 'Codex Micro'\(bridgeMode ? " (bridge mode, Mac helper required)" : "")")
            }
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        Task { @MainActor in
            if isInputReportCharacteristic(characteristic) {
                guard central.maximumUpdateValueLength >= 63 else {
                    blockingIssue = "The connected host's BLE packet size is too small for 63-byte Codex Micro HID reports."
                    log("rejected HID subscription from \(central.identifier): max update is \(central.maximumUpdateValueLength), need 63")
                    return
                }
                inputSubscribers[central.identifier] = central
                hostConnected = true
                setMacConnection(.transportConnected, detail: "Mac helper linked over Bluetooth")
                blockingIssue = nil
                if bridgeMode, peripheral.isAdvertising {
                    peripheral.stopAdvertising()
                    isAdvertising = false
                    log("stopped advertising while the Mac helper is connected")
                }
                peripheral.setDesiredConnectionLatency(.low, for: central)
                log("HID host \(central.identifier) subscribed (max update \(central.maximumUpdateValueLength))")
                flushPendingReports()
                // Subscription is the application-level reconnect boundary.
                // Replay the durable page choice before requesting state so
                // the helper cannot report a healthy BLE link while routing
                // every key to the backend selected before it restarted.
                sendBridgeControl([
                    "cmd": "setControlTarget",
                    "target": desiredControlTarget,
                ])
                requestLatestHostState()
            } else if characteristic === batteryChar || characteristic.uuid == CBUUID(string: "2A19") {
                refreshBattery()
                _ = peripheral.updateValue(
                    Data([UInt8(batteryPercent)]),
                    for: batteryChar,
                    onSubscribedCentrals: [central]
                )
                log("host subscribed to battery level")
            }
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        Task { @MainActor in
            if isInputReportCharacteristic(characteristic) {
                inputSubscribers.removeValue(forKey: central.identifier)
                hostConnected = !inputSubscribers.isEmpty
                if !hostConnected {
                    pendingReports.removeAll()
                    rpcBuffer.removeAll()
                    isSuspended = false
                    setMacConnection(.recovering, detail: "Mac helper disconnected; advertising again")
                    startAdvertising()
                }
                log("HID host \(central.identifier) unsubscribed\(hostConnected ? "" : " — disconnected")")
            }
        }
    }

    nonisolated func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        Task { @MainActor in flushPendingReports() }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        Task { @MainActor in
            let value: Data
            if request.characteristic === batteryChar || request.characteristic.uuid == CBUUID(string: "2A19") {
                refreshBattery()
                value = Data([UInt8(batteryPercent)])
            } else if request.characteristic === protocolModeChar || request.characteristic.uuid == CBUUID(string: "2A4E") {
                value = Data([protocolMode])
            } else if isInputReportCharacteristic(request.characteristic) {
                value = lastInputReport
            } else if isOutputReportCharacteristic(request.characteristic) {
                value = lastOutputReport
            } else {
                peripheral.respond(to: request, withResult: .requestNotSupported)
                return
            }

            guard request.offset <= value.count else {
                peripheral.respond(to: request, withResult: .invalidOffset)
                return
            }
            request.value = Data(value.dropFirst(request.offset))
            peripheral.respond(to: request, withResult: .success)
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        Task { @MainActor in
            guard let first = requests.first else { return }

            // CoreBluetooth requires exactly one response for the whole batch.
            // Validate every request before applying any of them.
            for request in requests {
                guard request.offset == 0 else {
                    peripheral.respond(to: first, withResult: .invalidOffset)
                    return
                }
                guard let value = request.value else {
                    peripheral.respond(to: first, withResult: .invalidAttributeValueLength)
                    return
                }
                if isOutputReportCharacteristic(request.characteristic) {
                    guard (2...64).contains(value.count) else {
                        peripheral.respond(to: first, withResult: .invalidAttributeValueLength)
                        return
                    }
                } else if request.characteristic === protocolModeChar || request.characteristic.uuid == CBUUID(string: "2A4E") {
                    guard value.count == 1, value[0] <= 1 else {
                        peripheral.respond(to: first, withResult: .invalidAttributeValueLength)
                        return
                    }
                } else if request.characteristic === controlPointChar || request.characteristic.uuid == CBUUID(string: "2A4C") {
                    guard value.count == 1, value[0] <= 1 else {
                        peripheral.respond(to: first, withResult: .invalidAttributeValueLength)
                        return
                    }
                } else {
                    peripheral.respond(to: first, withResult: .writeNotPermitted)
                    return
                }
            }

            for request in requests {
                guard let value = request.value else { continue }
                if isOutputReportCharacteristic(request.characteristic) {
                    let body = value.count == 64 && value.first == 6 ? Data(value.dropFirst()) : Data(value)
                    var stored = Data(count: 63)
                    stored.replaceSubrange(0..<min(63, body.count), with: body.prefix(63))
                    lastOutputReport = stored
                    handleOutputReport(value)
                } else if request.characteristic === protocolModeChar || request.characteristic.uuid == CBUUID(string: "2A4E") {
                    protocolMode = value[0]
                    log("host selected HID protocol mode \(protocolMode)")
                } else if request.characteristic === controlPointChar || request.characteristic.uuid == CBUUID(string: "2A4C") {
                    isSuspended = value[0] == 0
                    if isSuspended { pendingReports.removeAll() }
                    log(isSuspended ? "HID host entered suspend" : "HID host exited suspend")
                }
            }
            peripheral.respond(to: first, withResult: .success)
        }
    }

    private func publicationFailureMessage(service: CBService, error: NSError) -> String {
        let uuidNotAllowed = error.domain == CBErrorDomain
            && error.code == CBError.Code.uuidNotAllowed.rawValue
        if service.uuid == CBUUID(string: "1812"), uuidNotAllowed {
            return "iOS rejected the required Bluetooth HID service (0x1812). Public CoreBluetooth cannot expose this app as a macOS HID device."
        }
        if service.uuid == CBUUID(string: "1812") {
            return "The required Bluetooth HID service could not be published: \(error.localizedDescription)"
        }
        return "Required Bluetooth service \(service.uuid) could not be published: \(error.localizedDescription)"
    }
}
