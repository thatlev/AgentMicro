// CodexMicroBridge — macOS helper that links a Codex Micro device source to
// the patched ChatGPT desktop app over a local Unix socket.
//
// Two device sources, selected by command line:
//
//   default      BLE central linked to the CodexMicroRemote iPhone app.
//                iOS cannot publish the Bluetooth HID service (0x1812), so the
//                iPhone publishes a custom GATT "bridge" service instead and
//                this helper relays its report stream onto the socket.
//
//   --emulate    Built-in virtual Codex Micro: answers the RPC surface
//                (device.status, lighting acks) and lets you inject key,
//                dial, and joystick events from stdin. No iPhone needed.
//
// The socket (/tmp/codexbridge.sock) is consumed by codex-hid-shim.js, which
// patch-chatgpt.sh injects into ChatGPT's app.asar. Framing: a 4-byte
// big-endian length prefix covering tag+payload, then 1 tag byte + payload:
//   'P' helper->shim  presence, payload[0] = 0|1
//   'I' helper->shim  device->host HID report (64 bytes incl. report ID 6)
//   'O' shim->helper  host->device HID report (raw node-hid write buffer)
//
// Settings sync (BLE mode only): ChatGPT stores the Codex Micro layout and
// lighting brightness in ~/.codex/config.toml but does not expose them as
// durable device configuration. This helper watches that file (honoring
// CODEX_HOME) and pushes a snapshot to the iPhone as channel-3 config reports.
//
// Foreground refresh (BLE mode only): the bridge also caches the latest
// semantic lighting messages from ChatGPT. Channel 5 lets the iPhone request
// a replay after foregrounding without faking a key press or disturbing the
// desktop app's hardware auto-off timer.
//
// Build:  swiftc -O tools/CodexMicroBridge/main.swift tools/CodexMicroBridge/T3Backend.swift -o tools/CodexMicroBridge/codexbridge
// Run:    ./tools/CodexMicroBridge/codexbridge            # bridge the iPhone app
//         ./tools/CodexMicroBridge/codexbridge --emulate  # standalone emulator
//
// No root and no special entitlements are required: everything stays in
// userspace. If macOS asks, grant your terminal Bluetooth access in System
// Settings › Privacy & Security › Bluetooth (BLE mode only). Keep the iPhone
// app in the foreground while bridging.

import AppKit
import ApplicationServices
import CoreBluetooth
import Foundation

setvbuf(stdout, nil, _IONBF, 0) // unbuffered prints so nohup logs stay live
signal(SIGPIPE, SIG_IGN)        // writing to a vanished shim client must not kill us

/// The native menu-bar app installs a rotating file sink here. The command-line
/// helper leaves it nil and keeps its existing unbuffered stdout behavior.
var bridgeLogObserver: ((String) -> Void)?

/// Brings a desktop editor app to the front (macOS app activation) by bundle
/// id. Used when the user double-taps an agent key: the tab is focused *inside*
/// the editor and the whole app is raised above other windows. Best-effort and
/// silent — if the app isn't running or no bundle id is known, it does nothing.
enum AppActivator {
    static func activate(bundleIdentifier: String?) {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return }
        DispatchQueue.main.async {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            guard let app = running.first else {
                log("raise: no running app for bundle id \(bundleIdentifier)")
                return
            }
            app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }
    }
}

enum T3DesktopCommand {
    private static let bundleIdentifier = "com.t3tools.t3code"

    static func sendEffort(increasing: Bool) {
        var components = URLComponents()
        components.scheme = "t3code"
        components.host = "codex-micro"
        components.path = "/command"
        components.queryItems = [
            URLQueryItem(name: "kind", value: "effort"),
            URLQueryItem(name: "direction", value: increasing ? "1" : "-1"),
        ]
        open(components.url)
    }

    static func sendAction(_ action: String) {
        var components = URLComponents()
        components.scheme = "t3code"
        components.host = "codex-micro"
        components.path = "/command"
        components.queryItems = [
            URLQueryItem(name: "kind", value: "action"),
            URLQueryItem(name: "action", value: action),
        ]
        open(components.url)
    }

    static func focus(targetID: String?) {
        var components = URLComponents()
        components.scheme = "t3code"
        components.host = "codex-micro"
        components.path = "/command"
        var queryItems = [URLQueryItem(name: "kind", value: "focus")]
        if let targetID, let target = T3TargetID(rawValue: targetID) {
            queryItems.append(URLQueryItem(name: "environmentId", value: target.environmentID))
            queryItems.append(URLQueryItem(name: "threadId", value: target.threadID))
        }
        components.queryItems = queryItems
        open(components.url)
    }

    private static func open(_ url: URL?) {
        AppActivator.activate(bundleIdentifier: bundleIdentifier)
        guard let url else { return }
        DispatchQueue.main.async {
            NSWorkspace.shared.open(url)
        }
    }
}

final class MacOSDictationController {
    private let queue = DispatchQueue(label: "io.github.thislev.codexmicro.dictation")
    private var desiredActive = false
    var onStateChange: (Bool, String?) -> Void = { _, _ in }

    func setActive(_ active: Bool) {
        queue.async {
            guard self.desiredActive != active else { return }
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            guard AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary) else {
                self.onStateChange(
                    false,
                    "Allow AgentMicro in System Settings › Privacy & Security › Accessibility, then press the mic again."
                )
                return
            }
            self.desiredActive = active
            let script = """
            tell application "T3 Code (Alpha)" to activate
            tell application "System Events"
                tell process "T3 Code (Alpha)"
                    set frontmost to true
                    tell menu "Edit" of menu bar item "Edit" of menu bar 1
                        set dictationItems to every menu item whose name contains "Dictation"
                        if (count of dictationItems) is 0 then error "T3 Code has no Dictation menu item"
                        click item 1 of dictationItems
                    end tell
                end tell
            end tell
            """
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            if let error {
                self.desiredActive.toggle()
                log("t3: macOS dictation failed — \(error)")
                self.onStateChange(
                    self.desiredActive,
                    "macOS Dictation could not be toggled. Confirm Dictation is enabled and AgentMicro has Accessibility access."
                )
            } else {
                log("t3: macOS dictation \(active ? "started" : "stopped")")
                self.onStateChange(active, nil)
            }
        }
    }
}

let bridgeServiceUUID = CBUUID(string: "C0DE0001-6E10-4C0D-A5A5-C0DEB1D6E001")
let bridgeInputUUID = CBUUID(string: "C0DE0002-6E10-4C0D-A5A5-C0DEB1D6E001")
let bridgeOutputUUID = CBUUID(string: "C0DE0003-6E10-4C0D-A5A5-C0DEB1D6E001")
let hidReportID: UInt8 = 6

let tagPresence: UInt8 = 0x50 // 'P'
let tagInput: UInt8 = 0x49    // 'I'
let tagOutput: UInt8 = 0x4F   // 'O'
let tagT3Client: UInt8 = 0x54 // 'T'

func defaultCodexBridgeSocketPath() -> String {
    let directory = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("CodexMicro")
    try? FileManager.default.createDirectory(
        atPath: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    return (directory as NSString).appendingPathComponent("codexbridge.sock")
}

enum EndToEndConnectionState: String {
    case transportConnected = "transport-connected"
    case waitingForChatGPT = "waiting-for-chatgpt"
    case handshaking
    case operational
    case recovering
}

enum BridgeBluetoothState: String {
    case unknown
    case unavailable
    case denied
    case poweredOff
    case scanning
    case connecting
    case linked
}

struct CodexMicroBridgeStatus: Equatable {
    var bluetooth: BridgeBluetoothState = .unknown
    var phoneName: String?
    var phoneLinked = false
    var reportStreamReady = false
    var chatGPTLinked = false
    var endToEnd: EndToEndConnectionState = .recovering
    var detail = "Starting AgentMicro"
    var lastSuccessfulRoundTrip: Date?

    var isOperational: Bool {
        phoneLinked && reportStreamReady && chatGPTLinked && endToEnd == .operational
    }
}

/// Duplicate CoreBluetooth advertisements are not evidence that an existing
/// GATT link is stale. Only a different, explicit app-session token proves that
/// the iPhone recreated its peripheral while macOS retained the old link.
func shouldRefreshConnectedPeripheral(
    currentIdentifier: UUID,
    discoveredIdentifier: UUID,
    currentSession: Data?,
    discoveredSession: Data?
) -> Bool {
    guard currentIdentifier == discoveredIdentifier,
          let currentSession,
          let discoveredSession else { return false }
    return currentSession != discoveredSession
}

func log(_ message: String) {
    print("[bridge] \(message)")
    bridgeLogObserver?(message)
}

// MARK: - Unix socket server speaking to the in-app shim

final class SocketServer {
    private enum ClientRole {
        case shim
        case t3Code
    }

    let path: String
    private var serverFD: Int32 = -1
    private var clients: Set<Int32> = []
    private var clientRoles: [Int32: ClientRole] = [:]
    private let lock = NSLock()
    private var present = false

    /// Host -> device reports arriving from the shim ('O' frames).
    var onOutput: (Data) -> Void = { _ in }
    var onClientCountChange: (Int) -> Void = { _ in }

    init(path: String) {
        self.path = path
    }

    func start() {
        guard serverFD < 0 else { return }
        let directory = (path as NSString).deletingLastPathComponent
        if !directory.isEmpty {
            try? FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        unlink(path)
        serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else { log("FATAL: socket() failed: \(errnoString())"); exit(1) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
            path.withCString { cstr in
                strncpy(UnsafeMutableRawPointer(sunPath).assumingMemoryBound(to: CChar.self), cstr, 104)
            }
        }
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(serverFD, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, listen(serverFD, 4) == 0 else {
            log("FATAL: cannot bind \(path): \(errnoString())")
            exit(1)
        }
        log("socket listening at \(path)")

        DispatchQueue.global().async { [weak self] in
            while let self, self.serverFD >= 0 {
                let client = accept(self.serverFD, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    Thread.sleep(forTimeInterval: 0.1)
                    continue
                }
                self.addClient(client)
            }
        }
    }

    func stop() {
        lock.lock()
        let connectedClients = Array(clients)
        clients.removeAll()
        clientRoles.removeAll()
        let descriptor = serverFD
        serverFD = -1
        present = false
        lock.unlock()

        for client in connectedClients {
            shutdown(client, SHUT_RDWR)
        }
        if descriptor >= 0 {
            shutdown(descriptor, SHUT_RDWR)
            close(descriptor)
        }
        unlink(path)
        DispatchQueue.main.async { [weak self] in
            self?.onClientCountChange(0)
        }
    }

    private func errnoString() -> String { String(cString: strerror(errno)) }

    private func addClient(_ fd: Int32) {
        lock.lock()
        clients.insert(fd)
        clientRoles[fd] = .shim
        let wasPresent = present
        lock.unlock()
        let count = clientCount()
        log("shim connected (\(count) client(s))")
        DispatchQueue.main.async { [weak self] in self?.onClientCountChange(count) }
        if wasPresent { send(tagPresence, payload: Data([1]), to: fd) }
        DispatchQueue.global().async { [weak self] in self?.readLoop(fd) }
    }

    private func removeClient(_ fd: Int32) {
        lock.lock()
        clients.remove(fd)
        clientRoles.removeValue(forKey: fd)
        lock.unlock()
        close(fd)
        let count = clientCount()
        log("shim disconnected (\(count) client(s))")
        DispatchQueue.main.async { [weak self] in self?.onClientCountChange(count) }
    }

    func clientCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return clients.reduce(into: 0) { count, fd in
            if clientRoles[fd] != .t3Code { count += 1 }
        }
    }

    func t3ClientCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return clients.reduce(into: 0) { count, fd in
            if clientRoles[fd] == .t3Code { count += 1 }
        }
    }

    private func identifyT3Client(_ fd: Int32, payload: Data) {
        guard String(data: payload, encoding: .utf8) == "t3code" else { return }
        lock.lock()
        guard clients.contains(fd) else {
            lock.unlock()
            return
        }
        let changed = clientRoles[fd] != .t3Code
        clientRoles[fd] = .t3Code
        lock.unlock()
        guard changed else { return }
        log("T3 Code transport attached")
        let count = clientCount()
        DispatchQueue.main.async { [weak self] in self?.onClientCountChange(count) }
    }

    private func readLoop(_ fd: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break } // EOF or error: client gone
            buffer.append(contentsOf: chunk[0..<n])
            while buffer.count >= 4 {
                let len = Int(buffer.withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian)
                guard len >= 1, len <= 1 << 20 else { buffer.removeAll(); break }
                guard buffer.count >= 4 + len else { break }
                let frame = buffer.subdata(in: 4..<(4 + len))
                buffer.removeSubrange(0..<(4 + len))
                if frame[0] == tagOutput {
                    let report = frame.subdata(in: 1..<frame.count)
                    DispatchQueue.main.async { [weak self] in self?.onOutput(report) }
                } else if frame[0] == tagT3Client {
                    identifyT3Client(fd, payload: frame.subdata(in: 1..<frame.count))
                }
            }
        }
        removeClient(fd)
    }

    /// Broadcast one framed message to every connected shim.
    func broadcast(_ tag: UInt8, payload: Data) {
        lock.lock()
        let targets = Array(clients)
        lock.unlock()
        for fd in targets { send(tag, payload: payload, to: fd) }
    }

    private func send(_ tag: UInt8, payload: Data, to fd: Int32) {
        var frame = Data(capacity: 5 + payload.count)
        var len = UInt32(1 + payload.count).bigEndian
        frame.append(contentsOf: withUnsafeBytes(of: &len) { Array($0) })
        frame.append(tag)
        frame.append(payload)
        frame.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let n = write(fd, base + written, raw.count - written)
                if n <= 0 { return } // client will be reaped by its read loop
                written += n
            }
        }
    }

    /// Device plugged/unplugged; remembered for clients that connect later.
    func setPresent(_ next: Bool) {
        lock.lock()
        let changed = present != next
        present = next
        lock.unlock()
        guard changed else { return }
        log("device \(next ? "present" : "absent")")
        broadcast(tagPresence, payload: Data([next ? 1 : 0]))
    }

    /// Device -> host report. The report must already include report ID 6.
    func broadcastInput(_ report: Data) {
        broadcast(tagInput, payload: report)
    }

    /// Channel-5 workspace controls belong to the packaged T3 app while it is
    /// attached. ChatGPT shim clients never receive these private controls.
    func broadcastT3Input(_ report: Data) {
        lock.lock()
        let targets = clients.filter { clientRoles[$0] == .t3Code }
        lock.unlock()
        for fd in targets { send(tagInput, payload: report, to: fd) }
    }
}

// MARK: - Codex Micro layout (key binding) model + config.toml parsing

/// The host's `codex-micro-layout` setting. ChatGPT persists it to
/// ~/.codex/config.toml but never sends it to the device, so the bridge reads
/// the file itself and pushes it to the iPhone over channel 3.
struct CodexMicroLayout: Equatable {
    struct Slot: Equatable { var keycapId: String; var commandId: String? }
    /// Direction -> action fields (type/commandId or type/skillName/skillPath).
    var analogStick: [String: [String: String]]
    var slots: [String: Slot]
    var encoderMode: String
    var lightingBrightness: Int

    static let slotOrder = ["ACT06", "ACT07", "ACT08", "ACT09", "ACT10_ACT11", "ACT12"]
    static let stickOrder = ["up", "right", "down", "left"]

    /// Mirrors the desktop app's built-in defaults; partial config tables are
    /// merged over this, exactly like the app does.
    static let defaults = CodexMicroLayout(
        analogStick: [
            "up": ["type": "command", "commandId": "composer.togglePlanMode"],
            "right": ["type": "command", "commandId": "navigateForward"],
            "down": ["type": "command", "commandId": "toggleSidebar"],
            "left": ["type": "command", "commandId": "navigateBack"],
        ],
        slots: [
            "ACT06": Slot(keycapId: "FAST", commandId: nil),
            "ACT07": Slot(keycapId: "APPR", commandId: nil),
            "ACT08": Slot(keycapId: "REJ", commandId: nil),
            "ACT09": Slot(keycapId: "SPLIT", commandId: nil),
            "ACT10_ACT11": Slot(keycapId: "MIC", commandId: nil),
            "ACT12": Slot(keycapId: "CODEX", commandId: nil),
        ],
        encoderMode: "composer-navigation",
        lightingBrightness: 100
    )

    /// Parse the [desktop.codex-micro-layout] table out of config.toml,
    /// merged over `defaults`. Anything unreadable yields the defaults.
    static func load(from path: String) -> CodexMicroLayout {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return defaults }
        let prefix = "desktop.codex-micro-layout"
        var layout = defaults
        var section = ""
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard let value = unquote(String(line[line.index(after: eq)...])) else { continue }
            if section == "desktop", key == "codex-micro-lighting-brightness" {
                if let percent = Int(value) {
                    layout.lightingBrightness = min(max(percent, 0), 100)
                }
                continue
            }
            guard section == prefix || section.hasPrefix(prefix + ".") else { continue }
            if section == prefix {
                if key == "encoderMode" { layout.encoderMode = value }
                continue
            }
            let leaf = String(section.dropFirst(prefix.count + 1))
            if leaf.hasPrefix("slots.") {
                let slot = String(leaf.dropFirst("slots.".count))
                guard slotOrder.contains(slot) else { continue }
                var entry = layout.slots[slot] ?? Slot(keycapId: slot, commandId: nil)
                if key == "keycapId" { entry.keycapId = value }
                if key == "commandId" { entry.commandId = value }
                layout.slots[slot] = entry
            } else if leaf.hasPrefix("analogStick.") {
                let dir = String(leaf.dropFirst("analogStick.".count))
                guard stickOrder.contains(dir) else { continue }
                var action = layout.analogStick[dir] ?? [:]
                if ["type", "commandId", "skillName", "skillPath"].contains(key) {
                    if key == "type" {
                        if value == "skill" {
                            action.removeValue(forKey: "commandId")
                        } else if value == "command" {
                            action.removeValue(forKey: "skillName")
                            action.removeValue(forKey: "skillPath")
                        }
                    }
                    action[key] = value
                }
                layout.analogStick[dir] = action
            }
        }
        return layout
    }

    /// TOML scalar to string: basic "…" strings (with the common escapes) and
    /// literal '…' strings; anything else is returned trimmed, as-is.
    private static func unquote(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            var out = ""
            var it = value.dropFirst().dropLast().makeIterator()
            while let ch = it.next() {
                if ch == "\\", let esc = it.next() {
                    switch esc {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    default: out.append(esc)
                    }
                } else {
                    out.append(ch)
                }
            }
            return out
        }
        if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
            return String(value.dropFirst().dropLast())
        }
        return value.isEmpty ? nil : value
    }

    /// Compact, key-sorted JSON for the channel-3 config message.
    func jsonData() -> Data? {
        var slotsObj: [String: Any] = [:]
        for name in CodexMicroLayout.slotOrder {
            guard let slot = slots[name] else { continue }
            var entry: [String: Any] = ["keycapId": slot.keycapId]
            if let commandId = slot.commandId { entry["commandId"] = commandId }
            slotsObj[name] = entry
        }
        var stickObj: [String: Any] = [:]
        for dir in CodexMicroLayout.stickOrder {
            if let action = analogStick[dir] { stickObj[dir] = action }
        }
        let obj: [String: Any] = [
            "type": "codex-micro-layout",
            "version": 1,
            "slots": slotsObj,
            "analogStick": stickObj,
            "encoderMode": encoderMode,
            "lightingBrightness": lightingBrightness,
        ]
        return try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    }

    var summary: String {
        let keys = CodexMicroLayout.slotOrder.compactMap { slots[$0]?.keycapId }.joined(separator: " ")
        let stick = CodexMicroLayout.stickOrder
            .compactMap { dir -> String? in
                guard let action = analogStick[dir] else { return nil }
                if action["type"] == "skill", let name = action["skillName"] {
                    return "stick.\(dir)=skill:\(name)"
                }
                return action["commandId"].map { "stick.\(dir)=\($0)" }
            }
            .joined(separator: " ")
        return "[\(keys)] \(stick) enc=\(encoderMode) brightness=\(lightingBrightness)%"
    }
}

// MARK: - config.toml watcher

/// Watches the Codex config file and re-parses the layout on change. The app
/// rewrites config.toml promptly after each settings save (possibly via a
/// temp-file replace), so the file watch is re-established after rename/delete
/// and the parent directory is watched to catch (re)creation.
final class LayoutWatcher {
    /// Called on a global queue with the merged layout whenever it changes.
    var onUpdate: (CodexMicroLayout) -> Void = { _ in }

    private let path: String
    private var fileSource: DispatchSourceFileSystemObject?
    private var dirSource: DispatchSourceFileSystemObject?
    private var debounce: DispatchWorkItem?
    private(set) var current = CodexMicroLayout.defaults

    init(path: String) {
        self.path = path
    }

    func start() {
        current = CodexMicroLayout.load(from: path)
        log("layout: \(current.summary)")
        watchFile()
        watchDirectory()
    }

    private func scheduleReparse() {
        debounce?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let parsed = CodexMicroLayout.load(from: self.path)
            guard parsed != self.current else { return }
            self.current = parsed
            log("layout updated: \(parsed.summary)")
            self.onUpdate(parsed)
        }
        debounce = item
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    private func watchFile() {
        fileSource?.cancel()
        fileSource = nil
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return } // missing: the directory watch notices (re)creation
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .global())
        src.setEventHandler { [weak self] in
            guard let self else { return }
            if src.data.contains([.delete, .rename]) { self.watchFile() }
            self.scheduleReparse()
        }
        src.setCancelHandler { close(fd) }
        fileSource = src
        src.resume()
    }

    private func watchDirectory() {
        let dir = (path as NSString).deletingLastPathComponent
        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .global())
        src.setEventHandler { [weak self] in
            guard let self else { return }
            self.watchFile() // config.toml may have been (re)created or replaced
            self.scheduleReparse()
        }
        src.setCancelHandler { close(fd) }
        dirSource = src
        src.resume()
    }
}

// MARK: - BLE central linking the iPhone app

final class Bridge: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let server: SocketServer
    private var central: CBCentralManager!
    private var shouldRun = false
    private var phone: CBPeripheral?
    private var phoneConnected = false
    private var outputChar: CBCharacteristic?
    private var pendingWrites: [Data] = []
    private var isSubscribed = false
    private var subscribedAt: Date?
    private var phoneAdvertisingSession: Data?
    private var bridgeControlBuffer = Data()
    private var discardingBridgeControlFrame = false
    /// Channel-5 commands are idempotent at the transport boundary. The iPhone
    /// assigns one UUID to each logical command before BLE fragmentation; keep a
    /// bounded recent set so reconnect/retry delivery cannot execute a toggle or
    /// NEW action twice.
    private var recentBridgeCommandIDs: [String: TimeInterval] = [:]
    private let bridgeCommandIDTTL: TimeInterval = 120
    private let maxRecentBridgeCommandIDs = 512
    private var hostRPCBuffer = Data()
    private var deviceRPCBuffer = Data()
    private var healthResponseBuffer = Data()
    private var pendingHealthRequestIDs: [String: Date] = [:]
    private var shimConnected = false
    private var endToEndState: EndToEndConnectionState = .recovering
    private var endToEndDetail = "Waiting for the Mac helper"
    private var bluetoothState: BridgeBluetoothState = .unknown
    private var lastSuccessfulRoundTrip: Date?
    private var healthCheckTimeoutWorkItem: DispatchWorkItem?
    private var healthProbeWorkItem: DispatchWorkItem?
    private let healthProbeInterval: TimeInterval = 30
    private var phoneLivenessWorkItem: DispatchWorkItem?
    /// The foreground iPhone app sends an idempotent refresh every eight
    /// seconds. Requiring one within three heartbeat windows prevents a cached
    /// CoreBluetooth subscription from keeping the menu status healthy after
    /// the mobile app has been closed or suspended.
    private let phoneLivenessTimeout: TimeInterval = 26
    private var lastPhoneActivityAt: Date?
    private var cachedAgentSlots: [[String: Any]]?
    private var cachedZones: [String: Any]?
    /// One-shot guard: a resync re-presents the virtual device, which must stay
    /// stably present afterward so ChatGPT can reopen it. Fire at most once per
    /// empty-cache episode; cleared the moment ChatGPT actually replies.
    private var didRequestHostResync = false
    /// Briefly preserve ChatGPT's virtual HID identity while CoreBluetooth
    /// repairs a radio interruption. This must remain comfortably below the
    /// Work Louder SDK's 10-second RPC timeout: a longer false-present window
    /// lets a battery/status request disappear into a dead BLE transport and
    /// causes ChatGPT to unregister every input handler.
    private var presenceDropWorkItem: DispatchWorkItem?
    private let reconnectGrace: TimeInterval = 2

    /// Called once the iPhone has subscribed to the report stream; used to
    /// push the current key binding layout to the freshly connected phone.
    var onSubscribed: () -> Void = {}
    var onStatusChange: (CodexMicroBridgeStatus) -> Void = { _ in }

    /// When set (--target vscode), phone channel-2 RPC (v.oai.hid / v.oai.rad)
    /// is parsed here and routed to the VSCode controller instead of being
    /// relayed to a ChatGPT shim. nil keeps the default ChatGPT relay path.
    var onDeviceEvent: ((String, [String: Any]) -> Void)?
    var shouldInterceptDeviceEvents: () -> Bool = { true }

    init(server: SocketServer) {
        self.server = server
        self.shimConnected = server.clientCount() > 0
        super.init()
        server.onClientCountChange = { [weak self] count in
            self?.shimClientCountChanged(count)
        }
    }

    func start() {
        shouldRun = true
        if central == nil {
            central = CBCentralManager(delegate: self, queue: nil)
        } else {
            startScanning()
            publishStatus()
        }
    }

    func stop() {
        shouldRun = false
        healthCheckTimeoutWorkItem?.cancel()
        healthCheckTimeoutWorkItem = nil
        healthProbeWorkItem?.cancel()
        healthProbeWorkItem = nil
        phoneLivenessWorkItem?.cancel()
        phoneLivenessWorkItem = nil
        presenceDropWorkItem?.cancel()
        presenceDropWorkItem = nil
        central?.stopScan()
        if let phone {
            central?.cancelPeripheralConnection(phone)
        }
        outputChar = nil
        phone = nil
        phoneConnected = false
        isSubscribed = false
        subscribedAt = nil
        lastPhoneActivityAt = nil
        pendingWrites.removeAll()
        server.setPresent(false)
        bluetoothState = .unknown
        setEndToEndState(.recovering, detail: "Bridge paused", force: true)
    }

    func reconnect() {
        shouldRun = true
        if let phone {
            central?.cancelPeripheralConnection(phone)
        }
        reset()
        publishStatus()
    }

    /// A cheap, non-disruptive recovery nudge used when the user opens the
    /// menu. Healthy links are left untouched; an idle bridge resumes scanning.
    func ensureConnected() {
        guard shouldRun else {
            start()
            return
        }
        guard !isSubscribed, phone == nil else { return }
        startScanning()
        publishStatus()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            bluetoothState = .scanning
            log("Bluetooth on — scanning for the AgentMicro iPhone app")
            startScanning()
        case .unauthorized:
            bluetoothState = .denied
            server.setPresent(false)
#if CODEX_MICRO_MENU_APP
            log("Bluetooth access denied. Allow AgentMicro in System Settings › Privacy & Security › Bluetooth, then choose Reconnect.")
#else
            log("Bluetooth access denied. Allow the bridge in System Settings › Privacy & Security › Bluetooth, then rerun.")
#endif
        case .poweredOff:
            bluetoothState = .poweredOff
            server.setPresent(false)
            log("Bluetooth is off — turn it on in System Settings")
        case .unsupported:
            bluetoothState = .unavailable
            server.setPresent(false)
            log("this Mac does not support Bluetooth LE")
        default:
            bluetoothState = .unknown
            break
        }
        publishStatus()
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let discoveredSession = Self.advertisingSession(from: advertisementData)
        if let current = phone {
            if shouldRefreshConnectedPeripheral(
                currentIdentifier: current.identifier,
                discoveredIdentifier: peripheral.identifier,
                currentSession: phoneAdvertisingSession,
                discoveredSession: discoveredSession
            ) {
                log("iPhone app session changed — refreshing stale connection")
                central.cancelPeripheralConnection(current)
                reset(preservePresence: true)
            }
            return
        }
        log("found \(peripheral.name ?? "iPhone") (RSSI \(RSSI)) — connecting")
        phone = peripheral
        phoneConnected = false
        bluetoothState = .connecting
        phoneAdvertisingSession = discoveredSession
        peripheral.delegate = self
        publishStatus()
        if #available(macOS 14.0, *) {
            central.connect(peripheral, options: [CBConnectPeripheralOptionEnableAutoReconnect: true])
        } else {
            central.connect(peripheral)
        }
    }

    private static func advertisingSession(from advertisementData: [String: Any]) -> Data? {
        guard let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              data.count == 4,
              data.starts(with: [0x43, 0x4D]) else { return nil }
        return data
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        phoneConnected = true
        bluetoothState = .linked
        log("connected — discovering bridge service")
        publishStatus()
        peripheral.discoverServices([bridgeServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard phone?.identifier == peripheral.identifier else { return }
        phoneConnected = false
        log("connect failed: \(error?.localizedDescription ?? "unknown error") — rescanning")
        reset(preservePresence: presenceDropWorkItem != nil)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard phone?.identifier == peripheral.identifier else { return }
        phoneConnected = false
        log("iPhone disconnected\(error.map { ": \($0.localizedDescription)" } ?? "") — preserving virtual device while rescanning")
        reset(preservePresence: isSubscribed || presenceDropWorkItem != nil)
    }

    @available(macOS 14.0, *)
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        timestamp: CFAbsoluteTime, isReconnecting: Bool, error: Error?) {
        guard phone?.identifier == peripheral.identifier else { return }
        phoneConnected = isReconnecting
        log("iPhone link interrupted\(error.map { ": \($0.localizedDescription)" } ?? "")"
            + (isReconnecting ? " — system auto-reconnect active" : " — rescanning"))
        if isReconnecting {
            schedulePresenceDrop()
            outputChar = nil
            isSubscribed = false
            subscribedAt = nil
            pendingWrites.removeAll()
            bridgeControlBuffer.removeAll()
            discardingBridgeControlFrame = false
            hostRPCBuffer.removeAll()
            deviceRPCBuffer.removeAll()
            bluetoothState = .connecting
            publishStatus()
        } else {
            reset(preservePresence: isSubscribed || presenceDropWorkItem != nil)
        }
    }

    private func startScanning() {
        guard shouldRun, central.state == .poweredOn else { return }
        bluetoothState = .scanning
        central.scanForPeripherals(
            withServices: [bridgeServiceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    private func reset(preservePresence: Bool = false) {
        healthProbeWorkItem?.cancel()
        healthProbeWorkItem = nil
        phoneLivenessWorkItem?.cancel()
        phoneLivenessWorkItem = nil
        if preservePresence { schedulePresenceDrop() }
        else {
            presenceDropWorkItem?.cancel()
            presenceDropWorkItem = nil
            server.setPresent(false)
        }
        outputChar = nil
        phone = nil
        phoneConnected = false
        isSubscribed = false
        subscribedAt = nil
        lastPhoneActivityAt = nil
        phoneAdvertisingSession = nil
        pendingWrites.removeAll()
        bridgeControlBuffer.removeAll()
        discardingBridgeControlFrame = false
        hostRPCBuffer.removeAll()
        deviceRPCBuffer.removeAll()
        central.stopScan()
        startScanning()
        publishStatus()
    }

    private func schedulePresenceDrop() {
        presenceDropWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isSubscribed else { return }
            self.presenceDropWorkItem = nil
            self.server.setPresent(false)
            log("iPhone reconnect grace expired — AgentMicro removed")
        }
        presenceDropWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + reconnectGrace, execute: work)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == bridgeServiceUUID }) else {
            log("bridge service missing: \(error?.localizedDescription ?? "not present") — is the iPhone app in bridge mode?")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([bridgeInputUUID, bridgeOutputUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let characteristics = service.characteristics,
              let input = characteristics.first(where: { $0.uuid == bridgeInputUUID }),
              let output = characteristics.first(where: { $0.uuid == bridgeOutputUUID }) else {
            log("bridge characteristics missing: \(error?.localizedDescription ?? "incomplete service")")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        outputChar = output
        peripheral.setNotifyValue(true, for: input)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == bridgeInputUUID else { return }
        if let error {
            log("could not subscribe to iPhone reports: \(error.localizedDescription)")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        log("subscribed to the iPhone report stream — AgentMicro is live")
        // Once the report stream is live, duplicate scan callbacks add no
        // information and can contain cached advertisements from before iOS
        // stopped advertising. Stop scanning until a real disconnect.
        central.stopScan()
        presenceDropWorkItem?.cancel()
        presenceDropWorkItem = nil
        isSubscribed = true
        subscribedAt = Date()
        notePhoneActivity()
        phoneConnected = true
        bluetoothState = .linked
        server.setPresent(true)
        beginEndToEndHandshake()
        onSubscribed()
        publishStatus()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == bridgeInputUUID, error == nil,
              let value = characteristic.value, !value.isEmpty else { return }
        notePhoneActivity()
        if value.first == 2 { observeDeviceResponse(value) }
        if value.first == 5 {
            if server.t3ClientCount() > 0 {
                var report = Data([hidReportID])
                report.append(value)
                server.broadcastT3Input(report)
            } else {
                // The native menu companion remains a complete fallback when
                // T3 Code is closed; once T3 attaches, its configurable
                // controls own this surface and execute each command once.
                handleBridgeControl(value)
            }
            return
        }
        // VSCode target: intercept the phone's channel-2 RPC (key/dial/joystick
        // events) and route it to the controller instead of a ChatGPT shim.
        if onDeviceEvent != nil, shouldInterceptDeviceEvents(), value.first == 2 {
            parseDeviceChannel2(value)
            return
        }
        // The phone sends the 63-byte body; the in-app parser expects the
        // hidapi-style buffer with report ID 6 in front.
        var report = Data([hidReportID])
        report.append(value)
        server.broadcastInput(report)
    }

    private func notePhoneActivity() {
        lastPhoneActivityAt = Date()
        schedulePhoneLivenessCheck()
    }

    private func schedulePhoneLivenessCheck() {
        phoneLivenessWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.phoneLivenessWorkItem = nil
            guard self.shouldRun, self.isSubscribed, let last = self.lastPhoneActivityAt else { return }
            let age = Date().timeIntervalSince(last)
            if age < self.phoneLivenessTimeout {
                self.schedulePhoneLivenessCheck()
                return
            }

            log("iPhone heartbeat expired — treating the mobile app as disconnected")
            self.isSubscribed = false
            self.phoneConnected = false
            self.outputChar = nil
            self.pendingWrites.removeAll()
            self.server.setPresent(false)
            self.bluetoothState = .connecting
            self.setEndToEndState(
                .recovering,
                detail: "iPhone app stopped responding; waiting for it to reopen",
                force: true
            )
            if let phone = self.phone {
                self.central.cancelPeripheralConnection(phone)
            } else {
                self.reset()
            }
        }
        phoneLivenessWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + phoneLivenessTimeout,
            execute: work
        )
    }

    /// Accumulate device->host channel-2 fragments (newline-terminated JSON) and
    /// dispatch each complete `{method,params}` message to `onDeviceEvent`.
    private func parseDeviceChannel2(_ value: Data) {
        guard value.count >= 2 else { return }
        let len = min(Int(value[1]), value.count - 2)
        deviceRPCBuffer.append(value.subdata(in: 2..<(2 + len)))
        guard deviceRPCBuffer.count <= 64 * 1024 else { deviceRPCBuffer.removeAll(); return }
        while let nl = deviceRPCBuffer.firstIndex(of: 0x0A) {
            let line = deviceRPCBuffer.subdata(in: deviceRPCBuffer.startIndex..<nl)
            deviceRPCBuffer.removeSubrange(deviceRPCBuffer.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let method = (obj["method"] as? String) ?? (obj["m"] as? String) else { continue }
            let params = (obj["params"] as? [String: Any]) ?? (obj["p"] as? [String: Any]) ?? [:]
            DispatchQueue.main.async { [weak self] in self?.onDeviceEvent?(method, params) }
        }
    }

    /// Host -> device RPC pushed to the phone as a notification (bare JSON, no
    /// newline, channel 2). Used by --target vscode to drive the agent-key LEDs
    /// from CodexMicro status without a ChatGPT host present.
    func sendHostRPC(_ obj: [String: Any]) {
        guard phone != nil, outputChar != nil,
              let json = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        var offset = 0
        while offset < json.count {
            let chunk = min(61, json.count - offset)
            var report = Data(count: 64)
            report[0] = hidReportID
            report[1] = 2 // RPC channel
            report[2] = UInt8(chunk)
            report.replaceSubrange(3..<(3 + chunk), with: json.subdata(in: offset..<(offset + chunk)))
            pendingWrites.append(report)
            offset += chunk
        }
        flushWrites()
    }

    /// Host -> device ('O' frame from the shim). The app writes 64-byte
    /// hidapi buffers including report ID 6; the iPhone app tolerates both
    /// the 64-byte form and the bare 63-byte body, so forward unchanged.
    func forwardToPhone(_ report: Data) {
        guard isSubscribed, phone != nil, outputChar != nil else {
            // Never acknowledge a host write into an unusable transport while
            // continuing to advertise a virtual device. Marking it absent
            // closes the shim HID handle, rejects in-flight RPCs immediately,
            // and lets the next successful subscription re-present it cleanly.
            pendingWrites.removeAll()
            setEndToEndState(.recovering, detail: "Bluetooth transport interrupted")
            server.setPresent(false)
            return
        }
        observeHostOutput(report)
        pendingWrites.append(report)
        flushWrites()
    }

    /// Decode host lighting requests while forwarding them unchanged. The
    /// cached values are semantic agent state; they intentionally survive the
    /// iPhone being backgrounded or briefly disconnected.
    private func observeHostOutput(_ report: Data) {
        var body = report
        if body.count == 64, body.first == hidReportID { body = Data(body.dropFirst()) }
        guard body.count >= 2, body[0] == 2 else { return }
        let len = min(Int(body[1]), 61)
        guard body.count >= 2 + len else { return }
        let fragment = body.subdata(in: 2..<(2 + len))
        let fragmentText = String(data: fragment, encoding: .utf8)
        if !hostRPCBuffer.isEmpty,
           (fragmentText?.hasPrefix("{\"method\"") == true || fragmentText?.hasPrefix("{\"m\"") == true) {
            hostRPCBuffer.removeAll()
        }
        hostRPCBuffer.append(fragment)
        guard hostRPCBuffer.count <= 64 * 1024 else {
            hostRPCBuffer.removeAll()
            return
        }
        guard let object = try? JSONSerialization.jsonObject(with: hostRPCBuffer) as? [String: Any] else {
            return
        }
        hostRPCBuffer.removeAll()
        observeHostRequest(object)
        let method = object["method"] as? String ?? object["m"] as? String
        if method == "v.oai.thstatus", let slots = object["params"] as? [[String: Any]] {
            cachedAgentSlots = slots
            didRequestHostResync = false // ChatGPT replied; re-arm for the next gap
        } else if method == "v.oai.rgbcfg", let zones = object["params"] as? [String: Any] {
            cachedZones = zones
            didRequestHostResync = false
        }
    }

    private func shimClientCountChanged(_ count: Int) {
        shimConnected = count > 0
        publishStatus()
        guard isSubscribed else { return }
        if shimConnected {
            beginEndToEndHandshake()
        } else {
            healthCheckTimeoutWorkItem?.cancel()
            healthCheckTimeoutWorkItem = nil
            pendingHealthRequestIDs.removeAll()
            setEndToEndState(.waitingForChatGPT, detail: "ChatGPT bridge is not connected")
        }
    }

    private func beginEndToEndHandshake() {
        healthProbeWorkItem?.cancel()
        healthProbeWorkItem = nil
        healthCheckTimeoutWorkItem?.cancel()
        healthCheckTimeoutWorkItem = nil
        pendingHealthRequestIDs.removeAll()
        healthResponseBuffer.removeAll()
        didRequestHostResync = false
        guard shimConnected else {
            setEndToEndState(.waitingForChatGPT, detail: "Bluetooth is linked; waiting for ChatGPT")
            return
        }
        setEndToEndState(.handshaking, detail: "Bluetooth linked; checking ChatGPT")
        // A fresh phone subscription is an application-level transport
        // boundary. Re-present the virtual HID once so ChatGPT must open it,
        // send a real RPC, and receive the phone's response before we turn the
        // iPhone status green.
        requestHostResync()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self,
                  self.isSubscribed,
                  self.shimConnected,
                  self.endToEndState == .handshaking else { return }
            self.healthCheckTimeoutWorkItem = nil
            self.setEndToEndState(
                .recovering,
                detail: "ChatGPT did not complete the check; quit and reopen ChatGPT"
            )
        }
        healthCheckTimeoutWorkItem = timeout
        // The SDK's own request timeout is 10 seconds. Allow its cleanup to
        // finish, then replace an indefinite spinner with actionable truth.
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: timeout)
    }

    private func observeHostRequest(_ object: [String: Any]) {
        guard let id = rpcIDKey(object["id"] ?? object["i"]),
              (object["method"] as? String ?? object["m"] as? String) != nil else { return }
        let cutoff = Date().addingTimeInterval(-30)
        pendingHealthRequestIDs = pendingHealthRequestIDs.filter { $0.value >= cutoff }
        pendingHealthRequestIDs[id] = Date()
        if endToEndState != .operational {
            setEndToEndState(.handshaking, detail: "ChatGPT request received; awaiting iPhone reply")
        }
    }

    private func observeDeviceResponse(_ reportBody: Data) {
        guard reportBody.count >= 2 else { return }
        let len = min(Int(reportBody[1]), reportBody.count - 2)
        let fragment = reportBody.subdata(in: 2..<(2 + len))
        if !healthResponseBuffer.isEmpty,
           String(data: fragment, encoding: .utf8)?.hasPrefix("{\"id\"") == true {
            healthResponseBuffer.removeAll()
        }
        healthResponseBuffer.append(fragment)
        guard healthResponseBuffer.count <= 64 * 1024 else {
            healthResponseBuffer.removeAll()
            return
        }
        while let newline = healthResponseBuffer.firstIndex(of: 0x0A) {
            let line = Data(healthResponseBuffer[..<newline])
            healthResponseBuffer.removeSubrange(...newline)
            observeCompleteDeviceResponse(line)
        }
        if let object = try? JSONSerialization.jsonObject(with: healthResponseBuffer) as? [String: Any],
           object["id"] != nil || object["i"] != nil {
            healthResponseBuffer.removeAll()
            matchDeviceResponse(object)
        }
    }

    private func observeCompleteDeviceResponse(_ data: Data) {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        matchDeviceResponse(object)
    }

    private func matchDeviceResponse(_ object: [String: Any]) {
        guard let id = rpcIDKey(object["id"] ?? object["i"]),
              pendingHealthRequestIDs.removeValue(forKey: id) != nil,
              object["result"] != nil || object["error"] != nil else { return }
        healthCheckTimeoutWorkItem?.cancel()
        healthCheckTimeoutWorkItem = nil
        if object["error"] != nil {
            setEndToEndState(
                .recovering,
                detail: "ChatGPT reached the iPhone, but the device request failed"
            )
            return
        }
        setEndToEndState(
            .operational,
            detail: "ChatGPT and iPhone exchanged data successfully"
        )
    }

    private func rpcIDKey(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if let int = value as? Int { return String(int) }
        return nil
    }

    private func setEndToEndState(
        _ state: EndToEndConnectionState,
        detail: String,
        force: Bool = false
    ) {
        let changed = force || state != endToEndState || detail != endToEndDetail
        endToEndState = state
        endToEndDetail = detail
        if state == .operational {
            lastSuccessfulRoundTrip = Date()
            scheduleHealthProbe()
            // Every matching request/response is fresh liveness evidence even
            // when the semantic state remains operational. Publish the new
            // timestamp without spamming the iPhone or logs.
            publishStatus()
            guard changed else { return }
        } else {
            healthProbeWorkItem?.cancel()
            healthProbeWorkItem = nil
        }
        guard changed else { return }
        if state != .operational {
            publishStatus()
        }
        let object: [String: Any] = [
            "type": "connection-health",
            "version": 1,
            "state": state.rawValue,
            "detail": detail,
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        sendConfigJSON(json)
        log("connection health: \(state.rawValue) — \(detail)")
    }

    /// A connected socket and subscribed BLE characteristic can both remain
    /// nominal after one endpoint becomes wedged. If ordinary ChatGPT traffic
    /// has not already supplied a recent request/response, periodically
    /// re-present the virtual device so ChatGPT performs another real RPC
    /// through the iPhone before the menu bar remains healthy.
    private func scheduleHealthProbe() {
        healthProbeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.healthProbeWorkItem = nil
            guard self.shouldRun,
                  self.isSubscribed,
                  self.shimConnected,
                  self.endToEndState == .operational else { return }

            if let last = self.lastSuccessfulRoundTrip,
               Date().timeIntervalSince(last) < self.healthProbeInterval * 0.8 {
                self.scheduleHealthProbe()
                return
            }
            self.beginEndToEndHandshake()
        }
        healthProbeWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + healthProbeInterval,
            execute: work
        )
    }

    private func publishStatus() {
        let snapshot = CodexMicroBridgeStatus(
            bluetooth: bluetoothState,
            phoneName: phone?.name,
            phoneLinked: phoneConnected,
            reportStreamReady: isSubscribed,
            chatGPTLinked: shimConnected,
            endToEnd: endToEndState,
            detail: endToEndDetail,
            lastSuccessfulRoundTrip: lastSuccessfulRoundTrip
        )
        DispatchQueue.main.async { [weak self] in
            self?.onStatusChange(snapshot)
        }
    }

    /// Channel 5 is private to the phone/helper pair. It is never forwarded
    /// to the ChatGPT HID shim.
    private func handleBridgeControl(_ body: Data) {
        guard body.count >= 2 else { return }
        let len = min(Int(body[1]), 61)
        guard body.count >= 2 + len else { return }
        let fragment = body.subdata(in: 2..<(2 + len))
        bridgeControlBuffer.append(fragment)

        // Updated apps newline-terminate each logical frame. Consume every
        // complete line independently so one malformed command cannot poison
        // the command that follows it.
        while let newline = bridgeControlBuffer.firstIndex(of: 0x0A) {
            let line = bridgeControlBuffer.subdata(in: bridgeControlBuffer.startIndex..<newline)
            bridgeControlBuffer.removeSubrange(bridgeControlBuffer.startIndex...newline)
            if discardingBridgeControlFrame {
                discardingBridgeControlFrame = false
                continue
            }
            guard line.count <= 64 * 1024 else {
                log("discarded oversized bridge-control frame")
                continue
            }
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                if !line.isEmpty { log("discarded malformed bridge-control frame") }
                continue
            }
            dispatchBridgeControl(object)
        }

        if bridgeControlBuffer.count > 64 * 1024 {
            // Drop only this frame, then ignore its tail until its newline. This
            // preserves framing for the next valid command in the same BLE link.
            bridgeControlBuffer.removeAll()
            discardingBridgeControlFrame = true
            log("discarded oversized bridge-control frame")
            return
        }

        // Compatibility with already-installed iPhone builds that sent a bare
        // JSON object without a newline. JSONSerialization succeeds only after
        // the final fragment, so incomplete legacy frames remain buffered.
        guard !discardingBridgeControlFrame,
              let object = try? JSONSerialization.jsonObject(with: bridgeControlBuffer) as? [String: Any] else {
            return
        }
        bridgeControlBuffer.removeAll()
        dispatchBridgeControl(object)
    }

    private func dispatchBridgeControl(_ object: [String: Any]) {
        if let commandID = object["commandID"] as? String, !commandID.isEmpty {
            let now = Date.timeIntervalSinceReferenceDate
            recentBridgeCommandIDs = recentBridgeCommandIDs.filter { now - $0.value < bridgeCommandIDTTL }
            if recentBridgeCommandIDs[commandID] != nil {
                log("ignored duplicate bridge command \(commandID)")
                return
            }
            if recentBridgeCommandIDs.count >= maxRecentBridgeCommandIDs,
               let oldest = recentBridgeCommandIDs.min(by: { $0.value < $1.value })?.key {
                recentBridgeCommandIDs.removeValue(forKey: oldest)
            }
            recentBridgeCommandIDs[commandID] = now
        }

        switch object["cmd"] as? String {
        case "refreshState":
            if let target = object["target"] as? String,
               target == "chatgpt" || target == "vscode" {
                onControlTargetChange?(target)
            }
            if let onRefreshRequest { onRefreshRequest() }
            else { sendCachedState() }
        case "setPins":
            if let pins = object["pins"] as? [Any] { onSetPins?(pins) }
        case "setControlTarget":
            if let target = object["target"] as? String { onControlTargetChange?(target) }
        case "vscodeKey":
            // Workspace-page key/dial events arrive on this private channel
            // instead of the shared channel-2 HID stream, so the ChatGPT/Codex
            // wire is never touched. The `surface` tag ("vscode" | "t3code")
            // keeps the two workspace surfaces fully isolated: the wiring routes
            // each to its own controller, so T3 can never drive VS Code and vice
            // versa. Replay them as the same v.oai.hid events the controllers
            // already handle.
            guard let key = object["k"] as? String else { break }
            let surface = object["surface"] as? String ?? "vscode"
            var params: [String: Any] = ["k": key, "act": object["act"] as? Int ?? 1]
            if let agent = object["ag"] as? Int { params["ag"] = agent }
            onVSCodeKey?("v.oai.hid", params, surface)
        case "vscodeNew", "vscodeTogglePin", "vscodeInsert", "vscodeVoice",
             "vscodeRaise", "vscodeClearComposer":
            onVSCodeControl?(object)
        case "openURL":
            // Open (and focus) a URL on this Mac — used by the T3 page's NEW key
            // to launch a fresh chat in the T3 desktop app via its registered
            // `t3code://` handler. Scheme-limited so a stray frame can't open
            // arbitrary files/apps.
            guard let raw = object["url"] as? String,
                  let url = URL(string: raw),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" || scheme == "t3code" else { break }
            log("open on macOS: \(raw)")
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        default:
            break
        }
    }

    /// Exercises the exact channel-5 parser and replay guard without starting
    /// Bluetooth or binding either Unix socket. Keeping this beside the parser
    /// lets `--self-test` cover fragmented BLE delivery and recovery behavior
    /// using the same private implementation shipped in the helper.
    static func runControlFrameRegressionTest() -> Bool {
        let server = SocketServer(
            path: FileManager.default.temporaryDirectory
                .appendingPathComponent("codexbridge-control-selftest-\(UUID().uuidString).sock")
                .path
        )
        let bridge = Bridge(server: server)
        var dispatchCount = 0
        bridge.onVSCodeControl = { _ in dispatchCount += 1 }

        func encodedCommand(_ commandID: String, newlineTerminated: Bool = true) -> Data? {
            let object: [String: Any] = [
                "cmd": "vscodeTogglePin",
                "commandID": commandID,
            ]
            guard var data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
            if newlineTerminated { data.append(0x0A) }
            return data
        }

        func feed(_ payload: Data, fragmentSize: Int) {
            precondition(fragmentSize > 0 && fragmentSize <= 61)
            var offset = 0
            while offset < payload.count {
                let count = min(fragmentSize, payload.count - offset)
                var report = Data([5, UInt8(count)])
                report.append(payload.subdata(in: offset..<(offset + count)))
                bridge.handleBridgeControl(report)
                offset += count
            }
        }

        guard let first = encodedCommand("same-command"),
              let duplicate = encodedCommand("same-command"),
              let second = encodedCommand("second-command") else { return false }
        var stream = first
        stream.append(Data("{malformed}\n".utf8))
        stream.append(duplicate)
        stream.append(second)
        feed(stream, fragmentSize: 17)
        guard dispatchCount == 2 else { return false }

        // Compatibility with the already-deployed app that did not terminate
        // bridge-control JSON with a newline.
        guard let legacy = encodedCommand("legacy-command", newlineTerminated: false) else { return false }
        feed(legacy, fragmentSize: 13)
        guard dispatchCount == 3 else { return false }

        // An oversized corrupt frame must not poison the next valid frame,
        // even when both arrive across arbitrary BLE report boundaries.
        guard let afterOversized = encodedCommand("after-oversized") else { return false }
        var oversized = Data(repeating: 0x78, count: 70_000)
        oversized.append(0x0A)
        oversized.append(afterOversized)
        feed(oversized, fragmentSize: 61)
        return dispatchCount == 4
    }

    /// Proves the surface tag survives the channel-5 parser so the wiring can
    /// keep VS Code and T3 on separate controllers. A dropped tag is exactly how
    /// T3 key/pin presses used to leak into the VS Code controller.
    static func runSurfaceIsolationRegressionTest() -> Bool {
        let server = SocketServer(
            path: FileManager.default.temporaryDirectory
                .appendingPathComponent("codexbridge-surface-selftest-\(UUID().uuidString).sock")
                .path
        )
        let bridge = Bridge(server: server)
        var keyEvents: [(String, String)] = []
        var controlEvents: [(String, String)] = []
        bridge.onVSCodeKey = { _, params, surface in
            keyEvents.append(((params["k"] as? String) ?? "", surface))
        }
        bridge.onVSCodeControl = { object in
            controlEvents.append(((object["cmd"] as? String) ?? "",
                                  (object["surface"] as? String) ?? "vscode"))
        }
        func feedFrame(_ object: [String: Any]) {
            guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
            data.append(0x0A)
            var offset = 0
            while offset < data.count {
                let count = min(61, data.count - offset)
                var report = Data([5, UInt8(count)])
                report.append(data.subdata(in: offset..<(offset + count)))
                bridge.handleBridgeControl(report)
                offset += count
            }
        }
        feedFrame(["cmd": "vscodeKey", "surface": "t3code", "k": "AG01", "act": 1])
        feedFrame(["cmd": "vscodeKey", "k": "AG00", "act": 1]) // no surface → vscode default
        feedFrame([
            "cmd": "vscodeKey", "surface": "claude-desktop",
            "k": "JOY_RIGHT", "act": 1,
        ])
        feedFrame(["cmd": "vscodeTogglePin", "surface": "t3code"])
        feedFrame(["cmd": "vscodeRaise", "surface": "vscode"])
        feedFrame(["cmd": "vscodeVoice", "surface": "claude-desktop"])
        feedFrame(["cmd": "vscodeClearComposer", "surface": "claude-desktop"])
        guard keyEvents.contains(where: { $0 == ("AG01", "t3code") }),
              keyEvents.contains(where: { $0 == ("AG00", "vscode") }),
              keyEvents.contains(where: { $0 == ("JOY_RIGHT", "claude-desktop") }) else {
            return false
        }
        return controlEvents.contains(where: { $0 == ("vscodeTogglePin", "t3code") })
            && controlEvents.contains(where: { $0 == ("vscodeRaise", "vscode") })
            && controlEvents.contains(where: { $0 == ("vscodeVoice", "claude-desktop") })
            && controlEvents.contains(where: { $0 == ("vscodeClearComposer", "claude-desktop") })
    }

    /// VSCode target: the phone asked for the latest lighting. There is no
    /// ChatGPT cache to replay, so re-emit from CodexMicro status instead.
    var onRefreshRequest: (() -> Void)?

    /// VSCode target: the phone edited the agent-key pin map (Editor pins screen).
    var onSetPins: (([Any]) -> Void)?
    /// Hybrid mode page switch and direct VS Code actions (NEW/PIN/dictation).
    var onControlTargetChange: ((String) -> Void)?
    var onVSCodeControl: (([String: Any]) -> Void)?
    /// Workspace-page key/dial events, delivered on the private bridge channel so
    /// they never share the Codex HID stream. The third argument is the surface
    /// tag ("vscode" | "t3code") so the wiring can route each to its own,
    /// isolated controller.
    var onVSCodeKey: ((String, [String: Any], String) -> Void)?

    /// True once ChatGPT has pushed at least one lighting frame to this helper.
    var hasCachedHostState: Bool { cachedAgentSlots != nil || cachedZones != nil }

    /// Force the patched ChatGPT app to re-emit its Codex Micro lighting.
    /// ChatGPT only pushes lighting when it (re)detects the virtual device.
    /// After a fast helper restart the shim can keep the device "present" the
    /// whole time (a deliberate grace against restart blips), so a plain
    /// presence=1 is a no-op and the agent keys never resync. Briefly dropping
    /// then re-asserting presence makes ChatGPT re-detect and replay its state.
    /// Rate-limited so a foreground-refresh storm can't strobe the device.
    func requestHostResync() {
        guard !didRequestHostResync else { return }
        didRequestHostResync = true
        log("no cached ChatGPT state — re-presenting device to trigger a resync")
        // The absent gap must outlast ChatGPT's topology-watch debounce, or the
        // detach+attach collapse into a no-op and it never reopens the device
        // (and so never replays lighting). 1.5s clears that comfortably.
        server.setPresent(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.server.setPresent(true)
        }
    }

    func sendCachedState() {
        guard cachedAgentSlots != nil || cachedZones != nil else {
            log("foreground refresh requested before ChatGPT supplied lighting state")
            requestHostResync()
            return
        }
        var object: [String: Any] = ["type": "codex-micro-state", "version": 1]
        if let cachedAgentSlots { object["slots"] = cachedAgentSlots }
        if let cachedZones { object["zones"] = cachedZones }
        guard let json = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        sendConfigJSON(json)
        log("replayed latest ChatGPT lighting state to foregrounded iPhone")
    }

    /// Push the key binding layout to the phone as channel-3 config reports
    /// ([6][3][len][chunk…pad]). Bridge->phone only; nothing is sent toward
    /// the shim, so ChatGPT never sees these frames.
    func sendLayout(_ layout: CodexMicroLayout) {
        guard phone != nil, outputChar != nil, let json = layout.jsonData() else { return }
        sendConfigJSON(json)
    }

    func sendVSCodeState(
        targets: [[String: Any]],
        pins: [String?],
        selected: String?,
        connected: Bool
    ) {
        let encodedPins: [Any] = pins.map { $0 as Any? ?? NSNull() }
        var object: [String: Any] = [
            "type": "vscode-state",
            "version": 2,
            "connected": connected,
            "targets": targets,
            "pins": encodedPins,
        ]
        if let selected { object["selected"] = selected }
        guard let json = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        sendConfigJSON(json)
    }

    /// Push the state of any isolated non-Codex surface (currently `t3code`) to
    /// the phone. The iPhone consumes `{"type":"workspace-state","surface":…}`
    /// per surface, so each surface's targets/pins/LEDs stay independent.
    func sendWorkspaceState(
        surface: String,
        targets: [[String: Any]],
        pins: [String?],
        selected: String?,
        connected: Bool,
        slots: [[String: Any]]? = nil,
        issue: String? = nil,
        nativeVoiceActive: Bool? = nil
    ) {
        let encodedPins: [Any] = pins.map { $0 as Any? ?? NSNull() }
        var object: [String: Any] = [
            "type": "workspace-state",
            "surface": surface,
            "version": 2,
            "connected": connected,
            "targets": targets,
            "pins": encodedPins,
        ]
        if let selected { object["selected"] = selected }
        if let slots { object["slots"] = slots }
        if let issue { object["issue"] = issue }
        if let nativeVoiceActive { object["nativeVoiceActive"] = nativeVoiceActive }
        guard let json = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        sendConfigJSON(json)
    }

    private func sendConfigJSON(_ json: Data) {
        guard phone != nil, outputChar != nil else { return }
        var offset = 0
        while offset < json.count {
            let chunk = min(61, json.count - offset)
            var report = Data(count: 64)
            report[0] = hidReportID
            report[1] = 3 // config channel (1 = device debug log, 2 = RPC)
            report[2] = UInt8(chunk)
            report.replaceSubrange(3..<(3 + chunk), with: json.subdata(in: offset..<(offset + chunk)))
            pendingWrites.append(report)
            offset += chunk
        }
        flushWrites()
    }

    private func flushWrites() {
        guard let phone, let outputChar else { return }
        while !pendingWrites.isEmpty, phone.canSendWriteWithoutResponse {
            phone.writeValue(pendingWrites.removeFirst(), for: outputChar, type: .withoutResponse)
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        flushWrites()
    }
}

// MARK: - Built-in virtual Codex Micro (--emulate)

final class EmuDevice {
    private let server: SocketServer
    private var rpcBuffer = Data()
    let firmwareVersion = "0.2.0-socket-emu"

    init(server: SocketServer) {
        self.server = server
    }

    /// Host -> device: one raw node-hid write (64 bytes, report ID 6 first).
    func handleOutput(_ data: Data) {
        var d = data
        // Data(dropping) rebases indices to zero — a bare dropFirst() slice
        // keeps startIndex = 1 and d[0] would trap.
        if d.count >= 3 && d[0] == hidReportID { d = Data(d.dropFirst()) }
        guard d.count >= 2, d[0] == 2 else { return } // channel 2 = RPC
        let len = min(Int(d[1]), 61)
        guard d.count >= 2 + len else { return }
        let frag = d.subdata(in: 2..<(2 + len))
        if String(data: frag, encoding: .utf8)?.hasPrefix("{\"method\"") == true { rpcBuffer.removeAll() }
        rpcBuffer.append(frag)
        guard let text = String(data: rpcBuffer, encoding: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: rpcBuffer) as? [String: Any],
              let method = obj["method"] as? String else {
            if String(data: rpcBuffer, encoding: .utf8) != nil { return } // wait for more fragments
            rpcBuffer.removeAll()
            return
        }
        rpcBuffer.removeAll()
        log("host->dev \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        handleRpc(method: method, obj: obj)
    }

    private func handleRpc(method: String, obj: [String: Any]) {
        let id = obj["id"]
        switch method {
        case "sys.version":
            sendJson(["id": id ?? NSNull(), "result": ["version": firmwareVersion]])
        case "device.status":
            sendJson(["id": id ?? NSNull(), "result": [
                "version": firmwareVersion, "profile_index": 0, "layer_index": 1,
                "battery": 100, "is_charging": true]])
        case "v.oai.thstatus":
            if let arr = obj["params"] as? [[String: Any]] {
                for t in arr { log("  [light] agent \(t["id"] ?? "?") color=\(t["c"] ?? 0) bright=\(t["b"] ?? 0) effect=\(t["e"] ?? "")") }
            }
            sendJson(["id": id ?? NSNull(), "result": ["ok": true]])
        case "v.oai.rgbcfg", "lights.preview", "host.focused_app":
            sendJson(["id": id ?? NSNull(), "result": ["ok": true]])
        default:
            sendJson(["id": id ?? NSNull(), "error": ["code": -32601, "message": "Method not found"]])
        }
    }

    /// Device -> host CodexMicro control message on channel 4 (not part of the
    /// Codex Micro protocol). The shim consumes it to run host-side actions like
    /// clearing the composer; ChatGPT's device layer never sees it.
    func sendControl(_ obj: [String: Any]) {
        guard let payload = try? JSONSerialization.data(withJSONObject: obj) else { return }
        var offset = 0
        while offset < payload.count {
            let chunk = min(61, payload.count - offset)
            var report = Data(count: 64)
            report[0] = hidReportID
            report[1] = 4 // CodexMicro control channel (1 debug, 2 RPC, 3 layout)
            report[2] = UInt8(chunk)
            report.replaceSubrange(3..<(3 + chunk), with: payload.subdata(in: offset..<(offset + chunk)))
            server.broadcastInput(report)
            offset += chunk
            usleep(4000)
        }
        log("dev->host(ctrl) \(String(data: payload, encoding: .utf8) ?? "")")
    }

    /// Device -> host: newline-terminated JSON, chunked into 64-byte reports.
    func sendJson(_ obj: [String: Any]) {
        guard var payload = try? JSONSerialization.data(withJSONObject: obj) else { return }
        payload.append(0x0A)
        var offset = 0
        while offset < payload.count {
            let chunk = min(61, payload.count - offset)
            var report = Data(count: 64)
            report[0] = hidReportID
            report[1] = 2 // RPC channel
            report[2] = UInt8(chunk)
            report.replaceSubrange(3..<(3 + chunk), with: payload.subdata(in: offset..<(offset + chunk)))
            server.broadcastInput(report)
            offset += chunk
            usleep(4000)
        }
        log("dev->host \(String(data: payload, encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
}

// MARK: - stdin event injection for --emulate

func startStdinLoop(_ emu: EmuDevice) {
    let keyMap: [String: (String, Int8?)] = [
        "ag0": ("AG00", 0), "ag1": ("AG01", 1), "ag2": ("AG02", 2),
        "ag3": ("AG03", 3), "ag4": ("AG04", 4), "ag5": ("AG05", 5),
        "fast": ("ACT06", nil), "approve": ("ACT07", nil), "decline": ("ACT08", nil),
        "fork": ("ACT09", nil), "mic": ("ACT10", nil), "send": ("ACT12", nil),
    ]
    let joyMap: [String: Float] = ["right": 0.0, "down": 0.25, "left": 0.5, "up": 0.75]

    print("""
    Emulate mode — inject device events:
      ag0..ag5 press|release      agent key (default: press+release)
      fast|approve|decline|fork|mic|send [press|release]
      up|down|left|right [press|release]
      enc cw|cc|press
      clear                       clear the ChatGPT composer (CodexMicro channel 4)
      json <raw json>
    """)

    DispatchQueue.global().async {
        while let line = readLine()?.trimmingCharacters(in: .whitespaces), !line.isEmpty {
            let parts = line.split(separator: " ").map(String.init)
            if line.hasPrefix("json ") {
                let raw = String(line.dropFirst(5))
                if let d = raw.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    emu.sendJson(o)
                }
                continue
            }
            let actStr = parts.count > 1 ? parts[1] : "tap"
            if parts[0] == "clear" {
                emu.sendControl(["cmd": "clearComposer"])
                continue
            }
            if parts[0] == "enc", parts.count > 1 {
                switch parts[1] {
                case "cw": emu.sendJson(["method": "v.oai.hid", "params": ["k": "ENC_CW", "act": 2]])
                case "cc": emu.sendJson(["method": "v.oai.hid", "params": ["k": "ENC_CC", "act": 2]])
                default:
                    emu.sendJson(["method": "v.oai.hid", "params": ["k": "ENC", "act": 1]])
                    usleep(50000)
                    emu.sendJson(["method": "v.oai.hid", "params": ["k": "ENC", "act": 0]])
                }
                continue
            }
            if let (key, ag) = keyMap[parts[0]] {
                let send: (Int) -> Void = { act in
                    var params: [String: Any] = ["k": key, "act": act]
                    if let a = ag { params["ag"] = a }
                    emu.sendJson(["method": "v.oai.hid", "params": params])
                }
                if actStr == "press" { send(1) }
                else if actStr == "release" { send(0) }
                else { send(1); usleep(50000); send(0) }
                continue
            }
            if let angle = joyMap[parts[0]] {
                let send: (Float) -> Void = { d in emu.sendJson(["method": "v.oai.rad", "params": ["a": angle, "d": d]]) }
                if actStr == "press" { send(1.0) }
                else if actStr == "release" { send(0.0) }
                else { send(1.0); usleep(50000); send(0.0) }
                continue
            }
            print("unknown command")
        }
    }
}

// MARK: - VSCode target: drive editor tabs / agent terminals from the macropad

/// Unix-domain socket client to the AgentMicro VS Code companion extension.
/// Newline-delimited JSON both ways; auto-reconnects if the window/extension
/// restarts. Thread-safe writes.
final class VSCodeClient {
    let path: String
    private var fd: Int32 = -1
    private var connectedPathIdentity: UInt64?
    private var pathMonitor: DispatchSourceTimer?
    private let lock = NSLock()

    /// Latest pinnable target list from the extension.
    var onTargets: ([[String: Any]]) -> Void = { _ in }
    var onMessage: ([String: Any]) -> Void = { _ in }
    var onConnectionChange: (Bool) -> Void = { _ in }

    init(path: String) { self.path = path }

    func start() {
        let monitor = DispatchSource.makeTimerSource(queue: .global())
        monitor.schedule(deadline: .now() + 1.0, repeating: 1.0)
        monitor.setEventHandler { [weak self] in self?.disconnectIfSocketOwnerChanged() }
        pathMonitor = monitor
        monitor.resume()

        DispatchQueue.global().async { [weak self] in
            while let self {
                if self.tryConnect() {
                    self.send(["op": "hello"])
                    self.readLoop()
                }
                Thread.sleep(forTimeInterval: 1.0) // extension not up yet / dropped
            }
        }
    }

    private func tryConnect() -> Bool {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
            path.withCString { cstr in
                strncpy(UnsafeMutableRawPointer(sunPath).assumingMemoryBound(to: CChar.self), cstr, 104)
            }
        }
        let r = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(s, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if r != 0 { close(s); return false }
        lock.lock(); fd = s; connectedPathIdentity = socketPathIdentity(); lock.unlock()
        log("VSCode extension connected at \(path)")
        onConnectionChange(true)
        return true
    }

    func send(_ obj: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        data.append(0x0A)
        lock.lock(); let f = fd; lock.unlock()
        guard f >= 0 else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let n = write(f, base + written, raw.count - written)
                if n <= 0 { break }
                written += n
            }
        }
    }

    private func readLoop() {
        lock.lock(); let f = fd; lock.unlock()
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(f, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                if obj["type"] as? String == "targets", let targets = obj["targets"] as? [[String: Any]] {
                    onTargets(targets)
                }
                onMessage(obj)
            }
        }
        lock.lock()
        if fd == f { fd = -1; connectedPathIdentity = nil }
        lock.unlock()
        close(f)
        onConnectionChange(false)
        log("VSCode extension disconnected — will retry")
    }

    /// Unix permits a listening socket pathname to be replaced while an old
    /// client remains connected to the now-unlinked server. That is exactly
    /// what made a newly frontmost VS Code window report clients=0: the helper
    /// was still talking to another window's orphaned inode. Follow pathname
    /// ownership changes proactively so the normal reconnect loop attaches to
    /// the current frontmost window.
    private func disconnectIfSocketOwnerChanged() {
        lock.lock()
        let currentFD = fd
        let expected = connectedPathIdentity
        lock.unlock()
        guard currentFD >= 0 else { return }
        let current = socketPathIdentity()
        guard current == nil || expected == nil || current != expected else { return }
        log("VSCode socket owner changed — reconnecting to the frontmost window")
        shutdown(currentFD, SHUT_RDWR)
    }

    private func socketPathIdentity() -> UInt64? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return UInt64(info.st_ino)
    }
}

/// Maps the six agent keys to concrete editor/terminal target IDs. The stored
/// id is authoritative, but each pin also remembers the target's provider,
/// title, and workspace so it can re-find the SAME conversation after its id
/// churns — which happens every time the VS Code extension host reactivates (a
/// window reload re-mints every webview tab id). Re-attachment is only done when
/// the match is unambiguous, so a pin never silently jumps to a different chat.
final class PinMap {
    struct Entry { var provider: String?; var label: String?; var cwd: String?; var kind: String?; var id: String? }
    let path: String
    private var pins: [Entry?] = Array(repeating: nil, count: 6)
    private var missingSince: [Int: TimeInterval] = [:]
    private let missingTargetGrace: TimeInterval = 20
    private let pinLock = NSRecursiveLock()

    init(path: String) { self.path = path; reload() }

    func reload() {
        pinLock.lock(); defer { pinLock.unlock() }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["pins"] as? [Any] else { return }
        // v1 stored provider/name guesses from the retired orange settings
        // screen. Start v2 direct pinning cleanly rather than silently
        // occupying the first three keys with heuristic matches.
        guard (obj["version"] as? Int ?? 1) >= 2 else {
            pins = Array(repeating: nil, count: 6)
            missingSince.removeAll()
            return
        }
        var out: [Entry?] = Array(repeating: nil, count: 6)
        for (i, e) in arr.prefix(6).enumerated() {
            guard let d = e as? [String: Any] else { continue }
            out[i] = Entry(provider: d["provider"] as? String,
                           label: d["label"] as? String,
                           cwd: d["cwd"] as? String,
                           kind: d["kind"] as? String,
                           id: d["id"] as? String)
        }
        pins = out
        missingSince.removeAll()
    }

    /// Re-find the same conversation whose id has changed (extension-host
    /// reactivation re-mints every webview tab id on a window reload). Match on
    /// the stable, human-meaningful attributes — provider + title + workspace —
    /// but only when EXACTLY ONE editor/agent tab matches, so a pin can never
    /// silently jump to a different chat. Returns nil for terminals (their id is
    /// a runtime UUID with no stable attributes) and for ambiguous matches
    /// (e.g. several untitled "Claude Code" tabs).
    private func reattachedID(for pin: Entry, targets: [[String: Any]]) -> String? {
        guard let label = pin.label, !label.isEmpty else { return nil }
        let candidates = targets.filter { target in
            let kind = target["kind"] as? String
            guard kind == "agent-editor" || kind == "editor" else { return false }
            guard (target["label"] as? String) == label else { return false }
            if let provider = pin.provider, let targetProvider = target["provider"] as? String,
               targetProvider != provider { return false }
            if let cwd = pin.cwd, let targetCwd = target["cwd"] as? String, targetCwd != cwd { return false }
            return true
        }
        guard candidates.count == 1 else { return nil }
        return candidates[0]["id"] as? String
    }

    /// Capture a resolved target's stable attributes into an older id-only pin so
    /// it can survive the NEXT reload without needing to be re-pinned. Fires at
    /// most once per pin (only while its title is still missing).
    private func backfill(_ index: Int, from target: [String: Any]) {
        guard pins.indices.contains(index), var pin = pins[index],
              (pin.label ?? "").isEmpty,
              let label = target["label"] as? String, !label.isEmpty else { return }
        pin.label = label
        if pin.provider == nil { pin.provider = target["provider"] as? String }
        if pin.cwd == nil { pin.cwd = target["cwd"] as? String }
        if pin.kind == nil { pin.kind = target["kind"] as? String }
        pins[index] = pin
        save()
    }

    func resolve(_ index: Int, targets: [[String: Any]]) -> String? {
        pinLock.lock(); defer { pinLock.unlock() }
        guard index >= 0, index < pins.count, let pin = pins[index], let id = pin.id, !id.isEmpty else { return nil }
        if let match = targets.first(where: { ($0["id"] as? String) == id }) {
            backfill(index, from: match)
            return id
        }
        // Exact id gone — try to re-find the same conversation and adopt its new id.
        if let newID = reattachedID(for: pin, targets: targets) {
            pins[index]?.id = newID
            save()
            return newID
        }
        return nil
    }

    func resolvedIDs(targets: [[String: Any]], now: TimeInterval = Date.timeIntervalSinceReferenceDate) -> [String?] {
        pinLock.lock(); defer { pinLock.unlock() }
        var changed = false
        let resolved: [String?] = (0..<6).map { index in
            guard pins.indices.contains(index), let pin = pins[index], let id = pin.id, !id.isEmpty else {
                missingSince.removeValue(forKey: index)
                return nil
            }
            if let match = targets.first(where: { ($0["id"] as? String) == id }) {
                missingSince.removeValue(forKey: index)
                backfill(index, from: match)
                return id
            }
            // The exact id vanished. Before treating the tab as missing, try to
            // re-find the same conversation by its stable attributes — this is
            // what makes a pin survive a window reload that re-minted every
            // webview tab id. Adopt the new id so the pin self-heals.
            if let newID = reattachedID(for: pin, targets: targets), newID != id {
                pins[index]?.id = newID
                missingSince.removeValue(forKey: index)
                changed = true
                return newID
            }
            // A hub-owner election or extension-host reload briefly removes a
            // whole project from the aggregate. Retain its concrete ids long
            // enough for peers to reconnect; otherwise switching/reloading one
            // window instantly erased pins in every project. Truly closed tabs
            // still expire and free their key after the bounded grace.
            let firstMissing = missingSince[index] ?? now
            missingSince[index] = firstMissing
            if now - firstMissing < missingTargetGrace { return id }
            pins[index] = nil
            missingSince.removeValue(forKey: index)
            changed = true
            return nil
        }
        if changed { save() }
        return resolved
    }

    /// Toggle the selected target. Existing pins are removed; new pins take
    /// the first free key (0, 1, 2…) so the third agent naturally gets key 3.
    @discardableResult
    func toggle(_ targetID: String, targets: [[String: Any]]) -> Int? {
        pinLock.lock(); defer { pinLock.unlock() }
        _ = resolvedIDs(targets: targets) // prune vanished concrete targets
        // A target id belongs to one concrete VS Code window. Never persist a
        // stale id received during a socket-owner hand-off: it could otherwise
        // occupy a key despite naming nothing in the window that now owns the
        // bridge.
        guard let entry = targets.first(where: { ($0["id"] as? String) == targetID }) else { return nil }
        for index in pins.indices where resolve(index, targets: targets) == targetID {
            pins[index] = nil
            missingSince.removeValue(forKey: index)
            save()
            return index
        }
        guard let index = pins.firstIndex(where: { $0 == nil }) else { return nil }
        // Remember the target's stable attributes so the pin can re-find this
        // exact conversation after a reload churns its id.
        pins[index] = Entry(
            provider: entry["provider"] as? String,
            label: entry["label"] as? String,
            cwd: entry["cwd"] as? String,
            kind: entry["kind"] as? String,
            id: targetID)
        missingSince.removeValue(forKey: index)
        save()
        return index
    }

    private func save() {
        pinLock.lock(); defer { pinLock.unlock() }
        let encoded: [Any] = pins.map { pin in
            guard let pin else { return NSNull() }
            var entry: [String: Any] = [:]
            if let id = pin.id { entry["id"] = id }
            if let provider = pin.provider { entry["provider"] = provider }
            if let label = pin.label { entry["label"] = label }
            if let cwd = pin.cwd { entry["cwd"] = cwd }
            if let kind = pin.kind { entry["kind"] = kind }
            return entry
        }
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(
            withJSONObject: ["version": 2, "pins": encoded], options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

}

/// BLE notifications are reliable but not transaction-oriented: during a
/// subscriber hand-off the same UI edge can occasionally be observed more than
/// once. PIN is a toggle, so replaying one edge is destructive (pin -> unpin,
/// or, after a tab reorder, pinning a sibling). Treat a sub-second burst as one
/// physical press. The gate is global rather than target-specific because the
/// stale selection bug could make duplicate copies carry two neighbouring ids.
final class PinToggleGate {
    private let lock = NSLock()
    private let minimumInterval: TimeInterval
    private var lastAcceptedAt: TimeInterval?

    init(minimumInterval: TimeInterval = 0.65) {
        self.minimumInterval = minimumInterval
    }

    func accept(at now: TimeInterval = Date.timeIntervalSinceReferenceDate) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let lastAcceptedAt, now - lastAcceptedAt < minimumInterval { return false }
        lastAcceptedAt = now
        return true
    }
}

/// Watches CodexMicro's status.json and turns per-session status into agent-key
/// lighting (v.oai.thstatus), so the macropad LEDs reflect live Claude / Codex /
/// Kimi session state — the same source that drives the LED strip.
final class StatusLights {
    let path: String
    var push: ([String: Any]) -> Void = { _ in }
    var onBuild: ([String: Any]) -> Void = { _ in }
    private var timer: DispatchSourceTimer?
    private var lastMtime: TimeInterval = -1
    private var ticks = 0
    private let heartbeatEvery = 15 // re-push unchanged state every 15s so any dropped write self-heals
    private let selectionLock = NSLock()
    private var selectedSlot: Int?
    /// Concrete target metadata keyed by the agent slot to which that exact
    /// target ID is pinned. This is also the assignment gate: absent slots are
    /// always off, regardless of unrelated CodexMicro strip slot numbers.
    private var assignedTargets: [Int: [String: Any]] = [:]

    // status -> (packed 0xRRGGBB, effect id, effect speed). Effects: 1 solid, 4 breath.
    static let map: [String: (Int, Int, Double)] = [
        "idle": (0xFFFFFF, 1, 0.0),
        "thinking": (0x304FFE, 4, 0.4),
        "working": (0x304FFE, 4, 0.4),
        "running": (0x304FFE, 4, 0.4),
        "complete": (0x00FF4C, 1, 0.0),
        "done": (0x00FF4C, 1, 0.0),
        "unread": (0x00FF4C, 1, 0.0),
        "needs_input": (0xFF8F00, 4, 0.4),
        "awaiting-approval": (0xFF8F00, 4, 0.4),
        "awaiting-response": (0xFF8F00, 4, 0.4),
        "approval": (0xFF8F00, 4, 0.4),
        "error": (0xFF0033, 1, 0.0),
        "failed": (0xFF0033, 1, 0.0),
    ]

    init(path: String) { self.path = path }

    func start() {
        emit()
        let t = DispatchSource.makeTimerSource(queue: .global())
        t.schedule(deadline: .now() + 1.0, repeating: 1.0)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let m = (try? FileManager.default.attributesOfItem(atPath: self.path)[.modificationDate] as? Date)??.timeIntervalSince1970 ?? -1
            self.ticks += 1
            // Emit on any status.json change, and unconditionally on the
            // heartbeat so the LEDs never silently drift out of sync.
            if m != self.lastMtime { self.lastMtime = m; self.emit() }
            else if self.ticks % self.heartbeatEvery == 0 { self.emit() }
        }
        timer = t
        t.resume()
    }

    func setSelectedSlot(_ slot: Int?) {
        selectionLock.lock(); selectedSlot = slot; selectionLock.unlock()
        emit()
    }

    func setAssignments(pins: [String?], targets: [[String: Any]]) {
        var targetsByID: [String: [String: Any]] = [:]
        for target in targets {
            if let id = target["id"] as? String { targetsByID[id] = target }
        }
        var next: [Int: [String: Any]] = [:]
        for index in pins.indices {
            if let id = pins[index], let target = targetsByID[id] { next[index] = target }
        }
        selectionLock.lock(); assignedTargets = next; selectionLock.unlock()
        emit()
    }

    func emit() {
        let object = build()
        onBuild(object)
        push(object)
    }

    func build() -> [String: Any] {
        var sessions: [[String: Any]] = []
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let sessionObjects = obj["sessions"] as? [String: Any] {
            for (sessionID, value) in sessionObjects {
                guard var session = value as? [String: Any], session["status"] is String else { continue }
                session["sessionID"] = sessionID
                sessions.append(session)
            }
        }
        var slots: [[String: Any]] = []
        selectionLock.lock()
        let selected = selectedSlot
        let assigned = assignedTargets
        selectionLock.unlock()
        for key in 0..<6 {
            guard let target = assigned[key] else {
                slots.append(["id": key, "c": 0, "b": 0, "e": 0, "s": 0, "status": "off"])
                continue
            }
            let semanticStatus = matchingStatus(for: target, sessions: sessions)
            if selected == key {
                // Selection clears stale completion/unread green immediately,
                // but it must never hide live work, approval, or failure. Those
                // semantic states remain authoritative while the tab is open.
                let liveStatuses: Set<String> = [
                    "thinking", "working", "running",
                    "needs_input", "awaiting-approval", "awaiting-response", "approval",
                    "error", "failed",
                ]
                if let status = semanticStatus, liveStatuses.contains(status), let c = StatusLights.map[status] {
                    slots.append(["id": key, "c": c.0, "b": 1, "e": c.1, "s": c.2, "status": status])
                } else {
                    slots.append(["id": key, "c": 0xFFFFFF, "b": 1, "e": 4, "s": 0.4, "status": "selected"])
                }
            } else if let status = semanticStatus, let c = StatusLights.map[status] {
                slots.append(["id": key, "c": c.0, "b": 1, "e": c.1, "s": c.2, "status": status])
            } else {
                slots.append(["id": key, "c": 0xFFFFFF, "b": 1, "e": 1, "s": 0, "status": "idle"])
            }
        }
        return ["method": "v.oai.thstatus", "params": slots]
    }

    /// Kept as a helper instead of relying on CodexMicro's numeric strip slot:
    /// strip allocation is global and has no relationship to the user's VS
    /// Code pins. Prefer an explicit target ID when hooks provide one, then a
    /// concrete provider+working-directory match. Ambiguous/unmatched targets
    /// remain idle rather than displaying another chat's status.
    private func matchingStatus(for target: [String: Any], sessions: [[String: Any]]) -> String? {
        guard let targetID = target["id"] as? String else { return nil }
        if let exact = sessions.first(where: {
            ($0["targetId"] as? String) == targetID || ($0["target_id"] as? String) == targetID
        }) {
            return exact["status"] as? String
        }

        guard let targetCWD = normalizedPath(target["cwd"] as? String) else { return nil }
        let targetProvider = (target["provider"] as? String)?.lowercased()
        let providerIsSpecific = targetProvider != nil && targetProvider != "editor" && targetProvider != "terminal"
        let candidates = sessions.filter { session in
            guard normalizedPath(session["cwd"] as? String) == targetCWD else { return false }
            guard providerIsSpecific else { return true }
            return (session["provider"] as? String)?.lowercased() == targetProvider
        }
        guard !candidates.isEmpty else { return nil }
        return candidates.max {
            (($0["updated"] as? NSNumber)?.doubleValue ?? 0) < (($1["updated"] as? NSNumber)?.doubleValue ?? 0)
        }?["status"] as? String
    }

    private func normalizedPath(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return (value as NSString).standardizingPath
    }

}

/// Turns decoded macropad events into VSCode extension ops. Agent-key presses
/// select (focus) the pinned target; command keys act on the last selection.
final class VSCodeController {
    private let client: VSCodeClient
    private let pins: PinMap
    private let lock = NSLock()
    private var targets: [[String: Any]] = []
    private var lastFocused: String?
    /// The one editor/webview VS Code itself reports active. This is kept apart
    /// from `lastFocused`, which may be a terminal or a remote logical selection.
    /// When the phone has a stale editor id, the live editor wins for PIN.
    private var activeEditorTarget: String?
    private var extensionConnected = false
    private let pinToggleGate = PinToggleGate()
    var onStateChange: ([[String: Any]], [String?], String?, Bool) -> Void = { _, _, _, _ in }
    var onSelectedSlotChange: (Int?) -> Void = { _ in }

    init(client: VSCodeClient, pins: PinMap) {
        self.client = client
        self.pins = pins
        client.onTargets = { [weak self] t in
            guard let self else { return }
            let liveEditors = t.filter {
                guard ($0["active"] as? Bool) == true else { return false }
                let kind = $0["kind"] as? String
                return kind == "editor" || kind == "agent-editor"
            }
            // New extensions publish exactly one active editor. Refuse an
            // ambiguous legacy list instead of picking its first (wrong) tab.
            let selected = liveEditors.count == 1 ? liveEditors[0]["id"] as? String : nil
            self.lock.lock()
            self.targets = t
            self.activeEditorTarget = selected
            if let selected { self.lastFocused = selected }
            self.lock.unlock()
            log("vscode targets: \(t.compactMap { $0["label"] as? String }.joined(separator: ", "))")
            self.publishState()
        }
        client.onMessage = { [weak self] message in
            guard let self else { return }
            if message["type"] as? String == "selection", let id = message["id"] as? String {
                self.selectTarget(id, focus: false)
            }
        }
        client.onConnectionChange = { [weak self] connected in
            guard let self else { return }
            self.lock.lock(); self.extensionConnected = connected; self.lock.unlock()
            self.publishState()
        }
    }

    private func snapshotTargets() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }; return targets
    }

    private func selectTarget(_ id: String, focus: Bool = true) {
        lock.lock(); lastFocused = id; lock.unlock()
        if focus { client.send(["op": "focus", "id": id]) }
        let resolved = pins.resolvedIDs(targets: snapshotTargets())
        onSelectedSlotChange(resolved.firstIndex(where: { $0 == id }))
        publishState()
    }

    private func publishState() {
        lock.lock()
        let snapshot = targets
        let selected = lastFocused
        let connected = extensionConnected
        lock.unlock()
        let resolvedPins = pins.resolvedIDs(targets: snapshot)
        onStateChange(snapshot, resolvedPins, selected, connected)
        client.send([
            "op": "pins",
            "pins": resolvedPins.map { $0 as Any? ?? NSNull() },
            "selected": selected as Any? ?? NSNull(),
        ])
    }

    func forwardStatusToExtension(_ object: [String: Any]) {
        guard let slots = object["params"] as? [[String: Any]] else { return }
        let snapshot = snapshotTargets()
        lock.lock(); let selected = lastFocused; lock.unlock()
        client.send([
            "op": "status",
            "slots": slots,
            "pins": pins.resolvedIDs(targets: snapshot).map { $0 as Any? ?? NSNull() },
            "selected": selected as Any? ?? NSNull(),
        ])
    }

    func refreshState() { publishState() }

    func handleBridgeCommand(_ object: [String: Any]) {
        switch object["cmd"] as? String {
        case "vscodeNew":
            let kind = object["kind"] as? String ?? "command"
            let value = object["value"] as? String ?? ""
            let label = object["label"] as? String ?? "Agent"
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                log("vscode: NEW ignored because its configured action is empty")
                return
            }
            client.send(["op": "new", "kind": kind, "value": value, "label": label])
        case "vscodeTogglePin":
            guard pinToggleGate.accept() else {
                log("vscode: ignored duplicate PIN edge")
                return
            }
            let requestedTarget = (object["target"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let snapshot = snapshotTargets()
            lock.lock()
            let cached = lastFocused
            let liveEditor = activeEditorTarget
            lock.unlock()

            let requestedEntry = requestedTarget.flatMap { requested in
                snapshot.first(where: { ($0["id"] as? String) == requested })
            }
            let requestedKind = requestedEntry?["kind"] as? String
            let requestedIsEditor = requestedKind == "editor" || requestedKind == "agent-editor"
            // For an editor request, VS Code's live active tab is authoritative.
            // Terminal selections remain explicit because an editor tab stays
            // `isActive` while keyboard focus is in the terminal panel.
            let selected: String?
            if requestedIsEditor {
                selected = liveEditor ?? requestedTarget
            } else if requestedEntry != nil {
                selected = requestedTarget
            } else {
                selected = liveEditor ?? cached.flatMap { id in
                    snapshot.contains(where: { ($0["id"] as? String) == id }) ? id : nil
                }
            }
            guard let selected else {
                log("vscode: PIN ignored because no target is selected")
                return
            }
            if let changedSlot = pins.toggle(selected, targets: snapshot) {
                let stillPinned = pins.resolvedIDs(targets: snapshot).firstIndex(where: { $0 == selected })
                onSelectedSlotChange(stillPinned)
                log("vscode: toggled pin for \(selected) at slot \(changedSlot)")
                publishState()
            } else {
                log("vscode: all six agent keys are already pinned")
            }
        case "vscodeInsert":
            guard let text = object["text"] as? String, !text.isEmpty else { return }
            lock.lock(); let selected = lastFocused; lock.unlock()
            let requestedTarget = object["target"] as? String
            let target = requestedTarget ?? selected
            var message: [String: Any] = ["op": "insert", "text": text]
            if let target { message["id"] = target }
            message["submit"] = object["submit"] as? Bool ?? false
            client.send(message)
        case "vscodeVoice":
            // Toggle Claude's own dictation using the Mac's CURRENT default input
            // (e.g. the user's headset / MacBook mic). We deliberately do NOT
            // switch the Mac input to the iPhone: that triggers iOS's full-screen
            // "Using <iPhone> as Microphone" banner, which covers the macropad the
            // user is holding. Speak near the Mac / into your headset mic.
            guard let target = object["target"] as? String, !target.isEmpty else { return }
            client.send(["op": "voice", "id": target, "active": object["active"] as? Bool ?? false])
        case "vscodeRaise":
            // Double-tap of an agent key: bring the desktop editor app that owns
            // this target to the front. Prefer the explicitly-named target, then
            // the live selection; resolve its app bundle id from the extension's
            // target list (falling back to any known editor app).
            let requested = (object["target"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            lock.lock(); let selected = lastFocused; lock.unlock()
            let id = requested ?? selected
            let snapshot = snapshotTargets()
            let bundleId = snapshot.first(where: { ($0["id"] as? String) == id })?["appBundleId"] as? String
                ?? snapshot.compactMap { $0["appBundleId"] as? String }.first
            AppActivator.activate(bundleIdentifier: bundleId)
            if let id { client.send(["op": "focus", "id": id]) }
        default:
            break
        }
    }

    func handleEvent(_ method: String, _ params: [String: Any]) {
        guard method == "v.oai.hid", let k = params["k"] as? String else { return }
        let act = params["act"] as? Int ?? 1

        if k.hasPrefix("AG"), act == 1 {
            let idx = (params["ag"] as? Int) ?? Int(k.dropFirst(2)) ?? 0
            pins.reload()
            if let id = pins.resolve(idx, targets: snapshotTargets()) {
                selectTarget(id)
                log("vscode: focus slot \(idx) -> \(id)")
            } else {
                log("vscode: agent key \(idx) has no target")
            }
            return
        }

        guard act == 1 else { return } // command keys fire on press
        lock.lock(); let target = lastFocused; lock.unlock()
        let id = target ?? pins.resolve(0, targets: snapshotTargets()) ?? "claude"
        switch k {
        case "ACT07": client.send(["op": "approve", "id": id])
        case "ACT08": client.send(["op": "reject", "id": id])
        case "ACT12": client.send(["op": "submit", "id": id])
        case "ACT09": client.send(["op": "command", "cmd": "claude-vscode.newConversation"])
        default: log("vscode: unmapped key \(k)")
        }
    }
}

// MARK: - Claude Desktop target

/// Strict parser for the Claude Desktop Code deep-link surface. Keeping this
/// small and allow-listed prevents arbitrary schemes, credentials, fragments,
/// or extra path components from crossing the phone-to-Mac bridge.
enum ClaudeDesktopLink {
    static let bundleIdentifier = "com.anthropic.claudefordesktop"
    static let maximumPromptUTF8Bytes = 8_192

    static func isBridgeSessionID(_ value: String) -> Bool {
        value.hasPrefix("session_")
            && (20...128).contains(value.utf8.count)
            && value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics
                    .union(CharacterSet(charactersIn: "_-"))
                    .contains($0)
            }
    }

    static func normalized(_ rawValue: String, exactSessionOnly: Bool = false) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "claude",
              components.host?.lowercased() == "code",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.fragment == nil else { return nil }

        let path = components.percentEncodedPath
        if !exactSessionOnly, path.isEmpty || path == "/" {
            guard components.percentEncodedQuery == nil else { return nil }
            return URL(string: "claude://code")
        }
        if !exactSessionOnly, path == "/new" {
            guard components.queryItems == nil else { return nil }
            return URL(string: "claude://code/new")
        }

        let rawID = String(path.dropFirst())
        guard path.first == "/",
              !rawID.isEmpty,
              !rawID.contains("/"),
              components.percentEncodedQuery == nil else { return nil }
        if isBridgeSessionID(rawID) {
            return URL(string: "claude://code/\(rawID)")
        }
        guard rawID.unicodeScalars.allSatisfy({
            CharacterSet(charactersIn: "0123456789abcdefABCDEF-").contains($0)
        }),
        let uuid = UUID(uuidString: rawID) else { return nil }
        return URL(string: "claude://code/\(uuid.uuidString.lowercased())")
    }

    static func newSessionPrefill(_ rawPrompt: String) -> URL? {
        let prompt = rawPrompt
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty,
              prompt.utf8.count <= maximumPromptUTF8Bytes,
              !prompt.unicodeScalars.contains(where: {
                  $0.value < 0x20 && $0 != "\n" && $0 != "\t"
              }) else { return nil }
        var components = URLComponents()
        components.scheme = "claude"
        components.host = "code"
        components.path = "/new"
        components.queryItems = [URLQueryItem(name: "q", value: prompt)]
        return components.url
    }
}

/// Claude Desktop persists one small metadata document per local Code session.
/// Reading that first-party state lets the macropad address the session Claude
/// is actually showing without modifying Claude or asking the phone to store a
/// brittle hand-copied deep link.
struct ClaudeDesktopSessionSnapshot: Equatable {
    let localID: String
    let cliSessionID: String
    let bridgeSessionID: String
    let deepLink: URL
    let title: String
    let model: String?
    let effort: String?
    let lastFocusedAt: Double
}

final class ClaudeDesktopSessionStore {
    private struct Metadata: Decodable {
        let sessionId: String
        let cliSessionId: String?
        let lastFocusedAt: Double?
        let lastActivityAt: Double?
        let model: String?
        let effort: String?
        let title: String?
        let bridgeSessionIds: [String]?
    }

    private let rootURL: URL
    private let focusLogURL: URL

    init(
        rootURL: URL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(
                "Library/Application Support/Claude/claude-code-sessions",
                isDirectory: true
            ),
        focusLogURL: URL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/Claude/main.log")
    ) {
        self.rootURL = rootURL
        self.focusLogURL = focusLogURL
    }

    /// Resolves only Claude's explicit focused-session event. Falling back to a
    /// metadata timestamp can pin a recently active background agent instead of
    /// the conversation visible in the Code tab.
    func focusedSession() -> ClaudeDesktopSessionSnapshot? {
        guard let focusedID = focusedLocalSessionID() else { return nil }
        return sessions().first(where: { $0.localID == focusedID })
    }

    func session(cliSessionID: String) -> ClaudeDesktopSessionSnapshot? {
        sessions().first {
            $0.cliSessionID.caseInsensitiveCompare(cliSessionID) == .orderedSame
        }
    }

    private func sessions() -> [ClaudeDesktopSessionSnapshot] {
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var snapshots: [ClaudeDesktopSessionSnapshot] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "json",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  (values.fileSize ?? 0) <= 4 * 1024 * 1024,
                  let data = try? Data(contentsOf: url),
                  let metadata = try? JSONDecoder().decode(Metadata.self, from: data),
                  let cliSessionID = metadata.cliSessionId,
                  let bridgeSessionID = metadata.bridgeSessionIds?.last(where: {
                    ClaudeDesktopLink.isBridgeSessionID($0)
                  }),
                  let deepLink = ClaudeDesktopLink.normalized(
                    "claude://code/\(bridgeSessionID)",
                    exactSessionOnly: true
                  ) else { continue }

            let title = Self.sanitizedTitle(metadata.title, cliSessionID: cliSessionID)
            let focusedAt = metadata.lastFocusedAt ?? metadata.lastActivityAt ?? 0
            let candidate = ClaudeDesktopSessionSnapshot(
                localID: metadata.sessionId,
                cliSessionID: cliSessionID.lowercased(),
                bridgeSessionID: bridgeSessionID,
                deepLink: deepLink,
                title: title,
                model: metadata.model,
                effort: metadata.effort,
                lastFocusedAt: focusedAt
            )
            snapshots.append(candidate)
        }
        return snapshots
    }

    private func focusedLocalSessionID() -> String? {
        guard let handle = try? FileHandle(forReadingFrom: focusLogURL) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let tailSize = min(size, 512 * 1024)
        try? handle.seek(toOffset: size - tailSize)
        guard let data = try? handle.readToEnd(),
              let tail = String(data: data, encoding: .utf8) else { return nil }

        let prefix = "[CCD] LocalSessions.setFocusedSession: sessionId="
        for line in tail.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let range = line.range(of: prefix) else { continue }
            let value = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard value != "null" else { return nil }
            return value.hasPrefix("local_") ? value : nil
        }
        return nil
    }

    private static func sanitizedTitle(_ rawValue: String?, cliSessionID: String) -> String {
        let printable = (rawValue ?? "")
            .unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init)
            .joined()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        if !printable.isEmpty { return String(printable.prefix(80)) }
        return "Claude session \(cliSessionID.prefix(8))"
    }
}

enum ClaudeDesktopEffort {
    static let levels = ["low", "medium", "high", "xhigh", "max"]

    static func stepped(from rawValue: String?, increasing: Bool) -> (value: String, index: Int)? {
        guard let rawValue,
              let index = levels.firstIndex(of: rawValue.lowercased()) else { return nil }
        let target = min(max(index + (increasing ? 1 : -1), 0), levels.count - 1)
        guard target != index else { return nil }
        return (levels[target], target)
    }
}

/// Narrow macOS automation used only for Claude Desktop's own composer.
/// Dictation invokes Claude's shipped Command-D action. Clearing is guarded by
/// the Accessibility role of the focused element so Command-A/Delete can never
/// be sent to a sidebar, conversation list, terminal, or another application.
enum ClaudeDesktopAutomation {
    enum ClearResult {
        case cleared
        case permissionRequired
        case noEditableComposer
        case eventCreationFailed
    }

    enum ActionResult {
        case completed
        case permissionRequired
        case noFocusedComposer
        case composerNotEmpty
        case noFocusedControl
        case noSendControl
        case commandPaletteUnavailable
        case effortControlUnavailable
        case eventCreationFailed
    }

    private static let commandDKeyCode: CGKeyCode = 2
    private static let commandEKeyCode: CGKeyCode = 14
    private static let commandAKeyCode: CGKeyCode = 0
    private static let commandJKeyCode: CGKeyCode = 38
    private static let commandKKeyCode: CGKeyCode = 40
    private static let commandPKeyCode: CGKeyCode = 35
    private static let semicolonKeyCode: CGKeyCode = 41
    private static let returnKeyCode: CGKeyCode = 36
    private static let tabKeyCode: CGKeyCode = 48
    private static let deleteKeyCode: CGKeyCode = 51
    private static let escapeKeyCode: CGKeyCode = 53

    static func toggleDictation() -> Bool {
        guard accessibilityTrusted(prompt: true) else { return false }
        return postKey(commandDKeyCode, flags: .maskCommand)
    }

    static func toggleBrowser() -> ActionResult {
        shortcut(commandPKeyCode, flags: [.maskCommand, .maskShift])
    }

    static func toggleTerminal() -> ActionResult {
        shortcut(commandJKeyCode, flags: .maskCommand)
    }

    static func toggleSideChat() -> ActionResult {
        shortcut(semicolonKeyCode, flags: .maskCommand)
    }

    static func navigateComposer(forward: Bool) -> ActionResult {
        shortcut(tabKeyCode, flags: forward ? [] : .maskShift)
    }

    static func activateFocusedControl(processIdentifier: pid_t) -> ActionResult {
        guard accessibilityTrusted(prompt: true) else { return .permissionRequired }
        guard let focused = focusedElement(processIdentifier: processIdentifier),
              !isEditableTextElement(focused) else {
            return .noFocusedControl
        }
        var actions: CFArray?
        guard AXUIElementCopyActionNames(focused, &actions) == .success,
              let actionNames = actions as? [String],
              actionNames.contains(kAXPressAction as String),
              AXUIElementPerformAction(focused, kAXPressAction as CFString) == .success else {
            return .noFocusedControl
        }
        return .completed
    }

    static func submitFocusedComposer(processIdentifier: pid_t) -> ActionResult {
        guard accessibilityTrusted(prompt: true) else { return .permissionRequired }
        // Claude's composer is not guaranteed to own keyboard focus (the user
        // may just have toggled the terminal, browser, or side chat). Press the
        // enabled native button by its shipped accessibility label instead.
        guard let send = exactAction(
            processIdentifier: processIdentifier,
            labels: ["Send message", "Send"],
            allowedRoles: [kAXButtonRole as String]
        ) else {
            return .noSendControl
        }
        return AXUIElementPerformAction(send, kAXPressAction as CFString) == .success
            ? .completed
            : .eventCreationFailed
    }

    static func invokeFrontendMax(processIdentifier: pid_t) -> ActionResult {
        guard accessibilityTrusted(prompt: true) else { return .permissionRequired }
        guard let composer = focusedEditableElement(processIdentifier: processIdentifier) else {
            return .noFocusedComposer
        }
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            composer,
            kAXValueAttribute as CFString,
            &value
        ) == .success {
            let currentValue = (value as? String)
                ?? (value as? NSAttributedString)?.string
                ?? ""
            if !currentValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .composerNotEmpty
            }
        }
        guard postUnicodeText("/frontend-max"),
              postKey(returnKeyCode) else {
            return .eventCreationFailed
        }
        return .completed
    }

    static func invokeForkSession(
        processIdentifier: pid_t,
        completion: @escaping (ActionResult) -> Void
    ) {
        guard accessibilityTrusted(prompt: true) else {
            completion(.permissionRequired)
            return
        }
        let previousFocus = focusedElement(processIdentifier: processIdentifier)
        guard postKey(commandKKeyCode, flags: .maskCommand) else {
            completion(.eventCreationFailed)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            guard postUnicodeText("Fork session") else {
                completion(.eventCreationFailed)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                guard let fork = exactAction(
                    processIdentifier: processIdentifier,
                    labels: ["Fork session"],
                    allowedRoles: nil
                ),
                previousFocus.map({ !CFEqual($0, fork) }) ?? true else {
                    _ = postKey(escapeKeyCode)
                    completion(.commandPaletteUnavailable)
                    return
                }
                let result = AXUIElementPerformAction(
                    fork,
                    kAXPressAction as CFString
                )
                if result != .success { _ = postKey(escapeKeyCode) }
                completion(result == .success ? .completed : .eventCreationFailed)
            }
        }
    }

    /// One physical detent maps to one native slider increment/decrement. The
    /// role and action checks prevent encoder rotation from merely focusing or
    /// toggling Claude's effort control.
    static func stepEffort(
        increasing: Bool,
        processIdentifier: pid_t,
        completion: @escaping (ActionResult) -> Void
    ) {
        guard accessibilityTrusted(prompt: true) else {
            completion(.permissionRequired)
            return
        }
        guard postKey(commandEKeyCode, flags: [.maskCommand, .maskShift]) else {
            completion(.eventCreationFailed)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
            guard let slider = firstElement(
                processIdentifier: processIdentifier,
                matching: { role(of: $0) == (kAXSliderRole as String) }
            ) else {
                _ = postKey(escapeKeyCode)
                completion(.effortControlUnavailable)
                return
            }
            let action = increasing ? kAXIncrementAction : kAXDecrementAction
            var actions: CFArray?
            guard AXUIElementCopyActionNames(slider, &actions) == .success,
                  let actionNames = actions as? [String],
                  actionNames.contains(action as String),
                  AXUIElementPerformAction(slider, action as CFString) == .success else {
                _ = postKey(escapeKeyCode)
                completion(.effortControlUnavailable)
                return
            }
            _ = postKey(escapeKeyCode)
            completion(.completed)
        }
    }

    static func clearFocusedComposer(processIdentifier: pid_t) -> ClearResult {
        guard accessibilityTrusted(prompt: true) else { return .permissionRequired }
        guard let composer = focusedEditableElement(processIdentifier: processIdentifier) else {
            return .noEditableComposer
        }

        var valueIsSettable = DarwinBoolean(false)
        let settableResult = AXUIElementIsAttributeSettable(
            composer,
            kAXValueAttribute as CFString,
            &valueIsSettable
        )
        if settableResult == .success, valueIsSettable.boolValue {
            let result = AXUIElementSetAttributeValue(
                composer,
                kAXValueAttribute as CFString,
                "" as CFString
            )
            if result == .success { return .cleared }
        }

        // Some Electron contenteditables expose an editable AX role but do not
        // permit direct AXValue assignment. The verified role still makes this
        // fallback local to the composer rather than a blind global keystroke.
        guard postKey(commandAKeyCode, flags: .maskCommand),
              postKey(deleteKeyCode) else {
            return .eventCreationFailed
        }
        return .cleared
    }

    private static func accessibilityTrusted(prompt: Bool) -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private static func focusedEditableElement(processIdentifier: pid_t) -> AXUIElement? {
        guard let focused = focusedElement(processIdentifier: processIdentifier) else {
            return nil
        }
        var candidate = focused
        for _ in 0..<6 {
            if isEditableTextElement(candidate) { return candidate }
            var parentValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                candidate,
                kAXParentAttribute as CFString,
                &parentValue
            ) == .success,
            let parentValue,
            CFGetTypeID(parentValue) == AXUIElementGetTypeID() else {
                return nil
            }
            candidate = unsafeBitCast(parentValue, to: AXUIElement.self)
        }
        return nil
    }

    private static func focusedElement(processIdentifier: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(processIdentifier)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
        let focusedValue,
        CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(focusedValue, to: AXUIElement.self)
    }

    private static func focusedWindow(processIdentifier: pid_t) -> AXUIElement {
        let application = AXUIElementCreateApplication(processIdentifier)
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                application,
                attribute as CFString,
                &value
            ) == .success,
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID() {
                return unsafeBitCast(value, to: AXUIElement.self)
            }
        }
        return application
    }

    private static func firstElement(
        processIdentifier: pid_t,
        matching predicate: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(focusedWindow(processIdentifier: processIdentifier), 0)]
        var cursor = 0
        while cursor < queue.count, cursor < 4_000 {
            let (element, depth) = queue[cursor]
            cursor += 1
            if predicate(element), isEnabled(element) { return element }
            guard depth < 18 else { continue }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                element,
                kAXChildrenAttribute as CFString,
                &value
            ) == .success,
            let children = value as? [AXUIElement] else { continue }
            queue.append(contentsOf: children.map { ($0, depth + 1) })
        }
        return nil
    }

    private static func exactAction(
        processIdentifier: pid_t,
        labels: [String],
        allowedRoles: Set<String>?
    ) -> AXUIElement? {
        for label in labels {
            if let element = firstElement(
                processIdentifier: processIdentifier,
                matching: { candidate in
                    if let allowedRoles, !allowedRoles.contains(role(of: candidate) ?? "") {
                        return false
                    }
                    return strings(of: candidate).contains {
                        $0.compare(label, options: [.caseInsensitive, .diacriticInsensitive])
                            == .orderedSame
                    } && actionable(candidate) != nil
                }
            ) {
                return actionable(element)
            }
        }
        return nil
    }

    private static func actionable(_ element: AXUIElement) -> AXUIElement? {
        var candidate = element
        for _ in 0..<7 {
            var actions: CFArray?
            if AXUIElementCopyActionNames(candidate, &actions) == .success,
               let names = actions as? [String],
               names.contains(kAXPressAction as String),
               isEnabled(candidate) {
                return candidate
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                candidate,
                kAXParentAttribute as CFString,
                &parent
            ) == .success,
            let parent,
            CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            candidate = unsafeBitCast(parent, to: AXUIElement.self)
        }
        return nil
    }

    private static func strings(of element: AXUIElement) -> [String] {
        [
            kAXTitleAttribute,
            kAXDescriptionAttribute,
            kAXHelpAttribute,
            kAXValueAttribute,
            kAXRoleDescriptionAttribute,
            kAXIdentifierAttribute,
        ].compactMap { attribute in
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                element,
                attribute as CFString,
                &value
            ) == .success else { return nil }
            return (value as? String) ?? (value as? NSAttributedString)?.string
        }
    }

    private static func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &value
        ) == .success else { return nil }
        return value as? String
    }

    private static func isEnabled(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXEnabledAttribute as CFString,
            &value
        ) == .success else { return true }
        return (value as? Bool) ?? true
    }

    private static func isEditableTextElement(_ element: AXUIElement) -> Bool {
        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &roleValue
        ) == .success,
        let role = roleValue as? String else {
            return false
        }
        let editableRoles = [
            kAXTextAreaRole as String,
            kAXTextFieldRole as String,
            kAXComboBoxRole as String,
        ]
        return editableRoles.contains(role)
    }

    @discardableResult
    private static func postKey(
        _ keyCode: CGKeyCode,
        flags: CGEventFlags = []
    ) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(
                keyboardEventSource: source,
                virtualKey: keyCode,
                keyDown: true
              ),
              let up = CGEvent(
                keyboardEventSource: source,
                virtualKey: keyCode,
                keyDown: false
              ) else {
            return false
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private static func shortcut(
        _ keyCode: CGKeyCode,
        flags: CGEventFlags
    ) -> ActionResult {
        guard accessibilityTrusted(prompt: true) else { return .permissionRequired }
        return postKey(keyCode, flags: flags) ? .completed : .eventCreationFailed
    }

    private static func postUnicodeText(_ text: String) -> Bool {
        let utf16 = Array(text.utf16)
        guard !utf16.isEmpty,
              let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0,
                keyDown: true
              ),
              let up = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0,
                keyDown: false
              ) else {
            return false
        }
        utf16.withUnsafeBufferPointer { buffer in
            down.keyboardSetUnicodeString(
                stringLength: buffer.count,
                unicodeString: buffer.baseAddress
            )
            up.keyboardSetUnicodeString(
                stringLength: buffer.count,
                unicodeString: buffer.baseAddress
            )
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}

/// Isolated controller for Claude's native macOS app. The phone never opens a
/// Claude link locally: every action reaches this controller over the private
/// bridge channel, which then opens the allow-listed link explicitly with the
/// installed Claude Desktop bundle.
final class ClaudeDesktopController {
    private struct Pin: Codable {
        let id: String
        let label: String
    }

    private let persistenceURL: URL
    private let sessionStore: ClaudeDesktopSessionStore
    private let lock = NSLock()
    private var pins = Array<Pin?>(repeating: nil, count: 6)
    private var selected: String?
    private var currentSession: ClaudeDesktopSessionSnapshot?
    private var automationIssue: String?
    private var nativeVoiceActive = false
    private var nativeVoiceDesiredActive = false
    private var nativeVoiceTransitionInFlight = false
    // Channel-5 command IDs already suppress retransmissions. Keep only a
    // short mechanical debounce so deliberate quick pin/unpin taps are not
    // discarded as duplicates.
    private let pinToggleGate = PinToggleGate(minimumInterval: 0.18)

    /// (targets, pins, selected, connected, slots, issue, native voice active)
    var onPublish: (
        [[String: Any]], [String?], String?, Bool, [[String: Any]], String?, Bool
    ) -> Void = { _, _, _, _, _, _, _ in }

    init(
        path: String,
        sessionStore: ClaudeDesktopSessionStore = ClaudeDesktopSessionStore()
    ) {
        persistenceURL = URL(fileURLWithPath: path)
        self.sessionStore = sessionStore
        load()
    }

    func refreshState() {
        _ = syncCurrentSession()
        if !AXIsProcessTrusted() {
            lock.lock()
            automationIssue =
                "Reconnect codexbridge in macOS Settings › Privacy & Security › Accessibility."
            lock.unlock()
        }
        publishState()
    }

    func handleBridgeCommand(_ object: [String: Any]) {
        switch object["cmd"] as? String {
        case "vscodeNew":
            guard let raw = object["value"] as? String,
                  let url = ClaudeDesktopLink.normalized(raw) else {
                log("claude desktop: NEW ignored because its link is invalid")
                return
            }
            open(url)
        case "vscodeTogglePin":
            guard pinToggleGate.accept() else {
                log("claude desktop: ignored duplicate PIN edge")
                return
            }
            if let raw = object["target"] as? String,
               let url = ClaudeDesktopLink.normalized(raw, exactSessionOnly: true) {
                togglePin(
                    id: url.absoluteString,
                    label: sanitizedLabel(object["label"] as? String, url: url)
                )
                return
            }
            // No phone-side configuration is required. Once Claude is raised,
            // its own session metadata identifies the exact local conversation.
            withActivatedApplication { _ in
                guard let session = self.syncCurrentSession() else {
                    self.setAutomationState(
                        issue: "Open a Claude Code conversation, then tap Pin again."
                    )
                    log("claude desktop: PIN could not identify the current session")
                    return
                }
                self.togglePin(id: session.deepLink.absoluteString, label: session.title)
            }
        case "vscodeInsert":
            guard let prompt = object["text"] as? String,
                  let url = ClaudeDesktopLink.newSessionPrefill(prompt) else {
                log("claude desktop: voice prefill ignored because the prompt is empty or unsafe")
                return
            }
            open(url)
        case "vscodeVoice":
            toggleNativeDictation(active: object["active"] as? Bool ?? false)
        case "vscodeClearComposer":
            clearComposer()
        case "vscodeRaise":
            raiseOrLaunch()
        default:
            break
        }
    }

    func handleEvent(_ method: String, _ params: [String: Any]) {
        guard method == "v.oai.hid",
              let key = params["k"] as? String else { return }
        let action = params["act"] as? Int ?? 1
        if key.hasPrefix("AG") {
            guard action == 1 else { return }
            let index = (params["ag"] as? Int) ?? Int(key.dropFirst(2)) ?? -1
            lock.lock()
            let pin = pins.indices.contains(index) ? pins[index] : nil
            if let pin { selected = pin.id }
            lock.unlock()
            guard let pin, let url = URL(string: pin.id) else {
                log("claude desktop: agent key \(index) has no pinned session")
                return
            }
            publishState()
            open(url)
            return
        }

        switch key {
        case "JOY_RIGHT" where action == 1:
            performImmediateAction("toggle Browser", ClaudeDesktopAutomation.toggleBrowser)
        case "JOY_DOWN" where action == 1:
            performImmediateAction("toggle Terminal", ClaudeDesktopAutomation.toggleTerminal)
        case "JOY_LEFT" where action == 1:
            performImmediateAction("toggle Side Chat", ClaudeDesktopAutomation.toggleSideChat)
        case "JOY_UP" where action == 1:
            withActivatedApplication { processIdentifier in
                self.finishAction(
                    "Frontend Max",
                    result: ClaudeDesktopAutomation.invokeFrontendMax(
                        processIdentifier: processIdentifier
                    )
                )
            }
        case "ENC_CC" where action == 2:
            changeEffort(increasing: true)
        case "ENC_CW" where action == 2:
            changeEffort(increasing: false)
        case "ACT09" where action == 1:
            withActivatedApplication { processIdentifier in
                ClaudeDesktopAutomation.invokeForkSession(
                    processIdentifier: processIdentifier
                ) { result in
                    self.finishAction("fork session", result: result)
                }
            }
        case "ACT12" where action == 1:
            withActivatedApplication { processIdentifier in
                self.finishAction(
                    "send",
                    result: ClaudeDesktopAutomation.submitFocusedComposer(
                        processIdentifier: processIdentifier
                    )
                )
            }
        default:
            break
        }
    }

    private func togglePin(id: String, label: String) {
        lock.lock()
        if let index = pins.firstIndex(where: { $0?.id == id }) {
            pins[index] = nil
            // The session remains selected even when it is no longer assigned
            // to an agent key, so the phone immediately renders PIN (not UNPIN).
            selected = id
            lock.unlock()
            save()
            log("claude desktop: unpinned session from agent key \(index + 1)")
            publishState()
            return
        }
        guard let index = pins.firstIndex(where: { $0 == nil }) else {
            lock.unlock()
            log("claude desktop: all six agent keys are already pinned")
            return
        }
        pins[index] = Pin(id: id, label: label)
        selected = id
        lock.unlock()
        save()
        log("claude desktop: pinned \(label) to agent key \(index + 1)")
        publishState()
    }

    private func publishState() {
        lock.lock()
        let snapshot = pins
        let selected = selected
        let currentSession = currentSession
        let automationIssue = automationIssue
        let nativeVoiceActive = nativeVoiceActive
        lock.unlock()
        let installed = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: ClaudeDesktopLink.bundleIdentifier
        ) != nil
        var targets: [[String: Any]] = snapshot.compactMap { pin in
            guard let pin else { return nil }
            return [
                "id": pin.id,
                "kind": "desktop-session",
                "label": pin.label,
                "provider": "claude-desktop",
                "active": pin.id == selected,
                "nativeVoice": true,
                "appBundleId": ClaudeDesktopLink.bundleIdentifier,
            ]
        }
        if let currentSession,
           !targets.contains(where: { ($0["id"] as? String) == currentSession.deepLink.absoluteString }) {
            targets.append([
                "id": currentSession.deepLink.absoluteString,
                "kind": "desktop-session",
                "label": currentSession.title,
                "provider": "claude-desktop",
                "active": currentSession.deepLink.absoluteString == selected,
                "nativeVoice": true,
                "appBundleId": ClaudeDesktopLink.bundleIdentifier,
            ])
        }
        let ids = snapshot.map { $0?.id }
        let slots: [[String: Any]] = ids.enumerated().map { index, id in
            guard let id else {
                return ["id": index, "c": 0, "b": 1.0, "e": 0, "s": 0.0]
            }
            let isSelected = id == selected
            return [
                "id": index,
                "c": 0xFFFFFF,
                "b": 1.0,
                "e": isSelected ? 4 : 1,
                "s": isSelected ? 0.4 : 0.0,
            ]
        }
        onPublish(
            targets, ids, selected, installed, slots,
            installed
                ? automationIssue
                : "Install Claude Desktop on this Mac to use this page.",
            nativeVoiceActive
        )
    }

    private func toggleNativeDictation(active requestedActive: Bool) {
        lock.lock()
        nativeVoiceDesiredActive = requestedActive
        lock.unlock()
        reconcileNativeDictation()
    }

    /// Serializes the desired native voice state. A quick tap can request stop
    /// before Claude has acknowledged start; retaining the latest desired state
    /// guarantees that the queued stop still runs instead of leaving dictation
    /// accidentally latched.
    private func reconcileNativeDictation() {
        lock.lock()
        guard !nativeVoiceTransitionInFlight,
              nativeVoiceActive != nativeVoiceDesiredActive else {
            lock.unlock()
            publishState()
            return
        }
        let targetActive = nativeVoiceDesiredActive
        nativeVoiceTransitionInFlight = true
        lock.unlock()

        withActivatedApplication(
            onFailure: {
                self.lock.lock()
                self.nativeVoiceTransitionInFlight = false
                self.nativeVoiceDesiredActive = self.nativeVoiceActive
                self.lock.unlock()
                self.setAutomationState(issue: "Claude Desktop could not be opened.")
            }
        ) { _ in
            if ClaudeDesktopAutomation.toggleDictation() {
                self.lock.lock()
                self.nativeVoiceActive = targetActive
                self.nativeVoiceTransitionInFlight = false
                self.automationIssue = nil
                let needsAnotherTransition =
                    self.nativeVoiceActive != self.nativeVoiceDesiredActive
                self.lock.unlock()
                self.publishState()
                if needsAnotherTransition {
                    self.reconcileNativeDictation()
                }
                log("claude desktop: toggled native dictation")
            } else {
                self.lock.lock()
                self.nativeVoiceTransitionInFlight = false
                self.nativeVoiceDesiredActive = self.nativeVoiceActive
                self.automationIssue =
                    "Allow codexbridge in macOS Settings › Privacy & Security › Accessibility."
                self.lock.unlock()
                self.publishState()
                log("claude desktop: native dictation needs Accessibility permission")
            }
        }
    }

    private func performImmediateAction(
        _ name: String,
        _ action: @escaping () -> ClaudeDesktopAutomation.ActionResult
    ) {
        withActivatedApplication { _ in
            self.finishAction(name, result: action())
        }
    }

    private func changeEffort(increasing: Bool) {
        withActivatedApplication { processIdentifier in
            ClaudeDesktopAutomation.stepEffort(
                increasing: increasing,
                processIdentifier: processIdentifier
            ) { result in
                if case .completed = result {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        if let current = self.syncCurrentSession()?.effort {
                            log("claude desktop: effort -> \(current)")
                        }
                        self.publishState()
                    }
                }
                self.finishAction("change effort", result: result)
            }
        }
    }

    private func finishAction(
        _ name: String,
        result: ClaudeDesktopAutomation.ActionResult
    ) {
        let issue: String?
        switch result {
        case .completed:
            issue = nil
        case .permissionRequired:
            issue = "Allow codexbridge in macOS Settings › Privacy & Security › Accessibility."
        case .noFocusedComposer:
            issue = "Click the Claude message box once, then try \(name) again."
        case .composerNotEmpty:
            issue = "Send or clear the current Claude draft before starting Frontend Max."
        case .noFocusedControl:
            issue = "Turn the dial to focus a Claude composer control before pressing it."
        case .noSendControl:
            issue = "Type a Claude message before tapping Send."
        case .commandPaletteUnavailable:
            issue = "Claude's command palette did not open, so Fork was cancelled safely."
        case .effortControlUnavailable:
            issue = "Claude's effort control did not open, so the change was cancelled."
        case .eventCreationFailed:
            issue = "Claude \(name) control failed; try again."
        }
        setAutomationState(issue: issue)
        if issue == nil {
            log("claude desktop: \(name)")
        } else {
            log("claude desktop: \(name) unavailable (\(String(describing: result)))")
        }
    }

    private func clearComposer() {
        withActivatedApplication { processIdentifier in
            switch ClaudeDesktopAutomation.clearFocusedComposer(
                processIdentifier: processIdentifier
            ) {
            case .cleared:
                self.setAutomationState(issue: nil)
                log("claude desktop: cleared focused composer")
            case .permissionRequired:
                self.setAutomationState(
                    issue: "Allow codexbridge in macOS Settings › Privacy & Security › Accessibility."
                )
                log("claude desktop: clear composer needs Accessibility permission")
            case .noEditableComposer:
                self.setAutomationState(
                    issue: "Click the Claude message box once, then tap Clear again."
                )
                log("claude desktop: clear ignored because the composer is not focused")
            case .eventCreationFailed:
                self.setAutomationState(issue: "Claude composer control failed; try again.")
                log("claude desktop: could not create clear-composer key events")
            }
        }
    }

    private func setAutomationState(issue: String?, nativeVoiceActive: Bool? = nil) {
        lock.lock()
        automationIssue = issue
        if let nativeVoiceActive { self.nativeVoiceActive = nativeVoiceActive }
        lock.unlock()
        publishState()
    }

    private func withActivatedApplication(
        retryAfterLaunch: Bool = true,
        onFailure: (() -> Void)? = nil,
        action: @escaping (pid_t) -> Void
    ) {
        DispatchQueue.main.async {
            if let running = NSRunningApplication.runningApplications(
                withBundleIdentifier: ClaudeDesktopLink.bundleIdentifier
            ).first {
                running.activate(options: [.activateAllWindows])
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    action(running.processIdentifier)
                }
                return
            }

            guard retryAfterLaunch else {
                if let onFailure {
                    onFailure()
                } else {
                    self.setAutomationState(issue: "Claude Desktop could not be opened.")
                }
                return
            }
            self.open(URL(string: "claude://code")!)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                self.withActivatedApplication(
                    retryAfterLaunch: false,
                    onFailure: onFailure,
                    action: action
                )
            }
        }
    }

    @discardableResult
    private func syncCurrentSession() -> ClaudeDesktopSessionSnapshot? {
        guard let session = sessionStore.focusedSession() else { return nil }
        lock.lock()
        currentSession = session
        selected = session.deepLink.absoluteString
        lock.unlock()
        return session
    }

    private func open(_ url: URL) {
        DispatchQueue.main.async {
            guard let appURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: ClaudeDesktopLink.bundleIdentifier
            ) else {
                log("claude desktop: app is not installed")
                self.publishState()
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open(
                [url],
                withApplicationAt: appURL,
                configuration: configuration
            ) { _, error in
                if let error {
                    log("claude desktop: could not open \(url.absoluteString): \(error.localizedDescription)")
                }
            }
        }
    }

    private func raiseOrLaunch() {
        DispatchQueue.main.async {
            if let running = NSRunningApplication.runningApplications(
                withBundleIdentifier: ClaudeDesktopLink.bundleIdentifier
            ).first {
                running.activate(options: [.activateAllWindows])
            } else {
                self.open(URL(string: "claude://code")!)
            }
        }
    }

    private func sanitizedLabel(_ rawValue: String?, url: URL) -> String {
        let printable = (rawValue ?? "")
            .unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init)
            .joined()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        if !printable.isEmpty { return String(printable.prefix(80)) }
        return "Claude session \(url.lastPathComponent.prefix(8))"
    }

    private func load() {
        guard let data = try? Data(contentsOf: persistenceURL),
              let decoded = try? JSONDecoder().decode([Pin?].self, from: data) else { return }
        var normalized = Array<Pin?>(repeating: nil, count: 6)
        var seen = Set<String>()
        var migratedLegacyPin = false
        for (index, pin) in decoded.prefix(6).enumerated() {
            guard let pin,
                  let parsed = ClaudeDesktopLink.normalized(pin.id, exactSessionOnly: true)
            else { continue }
            let url: URL
            if ClaudeDesktopLink.isBridgeSessionID(parsed.lastPathComponent) {
                url = parsed
            } else if let session = sessionStore.session(cliSessionID: parsed.lastPathComponent) {
                // Build 12 stored CLI UUIDs. Claude interprets those as new
                // task identifiers; migrate to its true `session_*` deep link.
                url = session.deepLink
                migratedLegacyPin = true
            } else {
                // Never retain an ID known to open a new agent instead of the
                // pinned conversation.
                migratedLegacyPin = true
                continue
            }
            guard seen.insert(url.absoluteString).inserted else { continue }
            normalized[index] = Pin(id: url.absoluteString, label: sanitizedLabel(pin.label, url: url))
        }
        pins = normalized
        selected = normalized.compactMap { $0 }.first?.id
        if migratedLegacyPin {
            save()
            log("claude desktop: migrated legacy session pins to exact bridge links")
        }
    }

    private func save() {
        lock.lock()
        let snapshot = pins
        lock.unlock()
        let directory = persistenceURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: persistenceURL, options: .atomic)
    }
}

/// Drives the fully-isolated T3 Code surface from the macropad. Wraps the
/// standalone, self-contained `T3Backend` (runtime discovery + pairing + status
/// polling + turn dispatch) and republishes its snapshots to the phone as
/// `workspace-state` frames tagged `t3code`. It shares no state, wire, or
/// controller with `VSCodeController`, so the T3 page can never disturb VS Code
/// or Codex. When no T3 server is running the backend stays cleanly
/// disconnected and every macropad action is a harmless no-op.
final class T3Controller {
    private let backend: T3Backend
    private let lock = NSLock()
    private var latest: T3BackendSnapshot?
    private var nativeVoiceActive = false
    private var dictationIssue: String?
    private var started = false
    private let pinToggleGate = PinToggleGate()
    private let dictation = MacOSDictationController()
    /// (targets, pins, selected, connected, slots, issue, native voice)
    var onPublish: ([[String: Any]], [String?], String?, Bool, [[String: Any]], String?, Bool) -> Void
        = { _, _, _, _, _, _, _ in }

    init(backend: T3Backend = T3Backend()) {
        self.backend = backend
        backend.setUpdateHandler { [weak self] snapshot in self?.ingest(snapshot) }
        dictation.onStateChange = { [weak self] active, issue in
            guard let self else { return }
            self.lock.lock()
            self.nativeVoiceActive = active
            self.dictationIssue = issue
            self.lock.unlock()
            self.publish()
        }
    }

    /// Called when the user switches to the T3 page. Idempotent: starts the
    /// backend the first time (lazily — nothing runs until the page is used),
    /// and refreshes + republishes on every later switch.
    func activate() {
        lock.lock(); let first = !started; started = true; lock.unlock()
        if first { backend.start() } else { backend.refreshNow() }
        publish()
    }

    func refreshState() {
        lock.lock(); let active = started; lock.unlock()
        if active { backend.refreshNow() }
        publish()
    }

    private func ingest(_ snapshot: T3BackendSnapshot) {
        lock.lock(); latest = snapshot; lock.unlock()
        publish()
    }

    private func snapshotNow() -> T3BackendSnapshot? {
        lock.lock(); defer { lock.unlock() }; return latest
    }

    private func normalizedPins(_ slots: [String?]) -> [String?] {
        var next = Array<String?>(repeating: nil, count: 6)
        for (index, value) in slots.prefix(6).enumerated() { next[index] = value }
        return next
    }

    private func publish() {
        let snapshot = snapshotNow()
        let targets = snapshot?.targets ?? []
        let selected = snapshot?.pins.selectedTargetID
        let pins = normalizedPins(snapshot?.pins.slots ?? [])
        let connected = (snapshot?.phase == .connected)
        lock.lock()
        let nativeVoiceActive = nativeVoiceActive
        let dictationIssue = dictationIssue
        lock.unlock()
        let issue = dictationIssue ?? snapshot?.issue?.message
        let targetDicts: [[String: Any]] = targets.map { target in
            [
                "id": target.id,
                "kind": "t3",
                "label": target.title,
                "provider": "t3",
                "active": target.id == selected,
                "nativeVoice": false,
            ]
        }
        let slots = buildSlots(pins: pins, selected: selected, targets: targets)
        onPublish(targetDicts, pins, selected, connected, slots, issue, nativeVoiceActive)
    }

    private func buildSlots(pins: [String?], selected: String?, targets: [T3Target]) -> [[String: Any]] {
        (0..<6).map { key in
            guard let id = pins[key], let target = targets.first(where: { $0.id == id }) else {
                return ["id": key, "c": 0, "b": 0, "e": 0, "s": 0, "status": "off"]
            }
            if id == selected {
                return ["id": key, "c": 0xFFFFFF, "b": 1, "e": 4, "s": 0.4, "status": "selected"]
            }
            let status = Self.statusName(target.status)
            if let color = StatusLights.map[status] {
                return ["id": key, "c": color.0, "b": 1, "e": color.1, "s": color.2, "status": status]
            }
            return ["id": key, "c": 0xFFFFFF, "b": 1, "e": 1, "s": 0, "status": "idle"]
        }
    }

    private static func statusName(_ status: T3AgentStatus) -> String {
        switch status {
        case .idle: return "idle"
        case .working: return "working"
        case .done: return "complete"
        case .needsApproval: return "needs_input"
        case .error: return "error"
        case .unavailable: return "off"
        }
    }

    // MARK: - macropad events (t3code surface only)

    func handleEvent(_ method: String, _ params: [String: Any]) {
        guard method == "v.oai.hid", let k = params["k"] as? String else { return }
        let act = params["act"] as? Int ?? 1
        if k == "ENC_CC", act == 2 {
            T3DesktopCommand.sendEffort(increasing: true)
            return
        }
        if k == "ENC_CW", act == 2 {
            T3DesktopCommand.sendEffort(increasing: false)
            return
        }
        if act == 1 {
            let actions = [
                "ACT06": "fast",
                "ACT07": "new",
                "ACT09": "fork",
                "ACT12": "send",
                "JOY_UP": "frontendMax",
                "JOY_RIGHT": "browser",
                "JOY_DOWN": "terminal",
                "JOY_LEFT": "sideChat",
                "ENC_HOLD": "settings",
            ]
            if let action = actions[k] {
                T3DesktopCommand.sendAction(action)
                return
            }
        }
        guard act == 1, k.hasPrefix("AG") else { return }
        let idx = (params["ag"] as? Int) ?? Int(k.dropFirst(2)) ?? 0
        guard let snapshot = snapshotNow(), snapshot.pins.slots.indices.contains(idx),
              let id = snapshot.pins.slots[idx] else {
            log("t3: agent key \(idx) has no target")
            return
        }
        backend.select(targetID: id)
        log("t3: focus slot \(idx) -> \(id)")
    }

    func handleBridgeCommand(_ object: [String: Any]) {
        switch object["cmd"] as? String {
        case "vscodeTogglePin":
            guard pinToggleGate.accept() else { log("t3: ignored duplicate PIN edge"); return }
            let requested = (object["target"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            guard let id = requested ?? snapshotNow()?.pins.selectedTargetID else {
                log("t3: PIN ignored because nothing is selected")
                return
            }
            backend.togglePin(targetID: id)
        case "vscodeInsert":
            guard let text = object["text"] as? String, !text.isEmpty else { return }
            let target = (object["target"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            backend.sendPrompt(text, to: target) { _ in }
        case "vscodeNew":
            let value = (object["value"] as? String) ?? ""
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            backend.sendPrompt(value, to: nil) { _ in }
        case "vscodeVoice":
            dictation.setActive(object["active"] as? Bool ?? false)
        case "vscodeRaise":
            let target = (object["target"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? snapshotNow()?.pins.selectedTargetID
            T3DesktopCommand.focus(targetID: target)
        default:
            break
        }
    }
}

/// stdin injection for `--target vscode --emulate` (no iPhone needed).
func startVSCodeStdinLoop(_ controller: VSCodeController) {
    let keyMap: [String: (String, Int?)] = [
        "ag0": ("AG00", 0), "ag1": ("AG01", 1), "ag2": ("AG02", 2),
        "ag3": ("AG03", 3), "ag4": ("AG04", 4), "ag5": ("AG05", 5),
        "fast": ("ACT06", nil), "approve": ("ACT07", nil), "decline": ("ACT08", nil),
        "reject": ("ACT08", nil), "fork": ("ACT09", nil), "mic": ("ACT10", nil),
        "send": ("ACT12", nil),
    ]
    print("""
    VSCode target (emulate) — inject events; ops go to the VSCode extension:
      ag0..ag5        focus the target pinned to that agent key
      approve         approve (Claude diff accept · terminal 'y')
      reject|decline  reject (Claude diff reject · terminal 'n')
      send            submit (terminal Enter)
      fork            new Claude conversation
    """)
    DispatchQueue.global().async {
        while let line = readLine()?.trimmingCharacters(in: .whitespaces), !line.isEmpty {
            let parts = line.split(separator: " ").map(String.init)
            guard let (k, ag) = keyMap[parts[0]] else { print("unknown command"); continue }
            var params: [String: Any] = ["k": k, "act": 1]
            if let ag { params["ag"] = ag }
            controller.handleEvent("v.oai.hid", params)
        }
    }
}

// MARK: - deterministic regression checks

/// Runs without Bluetooth, VS Code, a helper socket, or user state. Kept in the
/// production executable so the exact PinMap/lighting implementation compiled
/// for release is what CI exercises.
func runBridgeRegressionTests() -> Bool {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("codexbridge-regression-\(UUID().uuidString)", isDirectory: true)
    do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    catch { print("self-test: could not create temp directory: \(error)"); return false }
    defer { try? FileManager.default.removeItem(at: directory) }

    func fail(_ message: String) -> Bool { print("self-test failed: \(message)"); return false }

    let phoneID = UUID()
    let otherPhoneID = UUID()
    let sessionA = Data([0x43, 0x4D, 0x01, 0x01])
    let sessionB = Data([0x43, 0x4D, 0x01, 0x02])
    guard !shouldRefreshConnectedPeripheral(
              currentIdentifier: phoneID, discoveredIdentifier: phoneID,
              currentSession: nil, discoveredSession: nil),
          !shouldRefreshConnectedPeripheral(
              currentIdentifier: phoneID, discoveredIdentifier: phoneID,
              currentSession: sessionA, discoveredSession: nil),
          !shouldRefreshConnectedPeripheral(
              currentIdentifier: phoneID, discoveredIdentifier: phoneID,
              currentSession: sessionA, discoveredSession: sessionA),
          !shouldRefreshConnectedPeripheral(
              currentIdentifier: phoneID, discoveredIdentifier: otherPhoneID,
              currentSession: sessionA, discoveredSession: sessionB),
          shouldRefreshConnectedPeripheral(
              currentIdentifier: phoneID, discoveredIdentifier: phoneID,
              currentSession: sessionA, discoveredSession: sessionB) else {
        return fail("duplicate BLE advertisements can still tear down a healthy connection")
    }

    guard EndToEndConnectionState.operational.rawValue == "operational",
          EndToEndConnectionState.handshaking.rawValue == "handshaking",
          EndToEndConnectionState.waitingForChatGPT.rawValue == "waiting-for-chatgpt" else {
        return fail("end-to-end connection state wire values changed")
    }

    guard Bridge.runControlFrameRegressionTest() else {
        return fail("channel-5 framing, recovery, or command replay suppression regressed")
    }

    // Surface isolation: every workspace event must carry its surface tag intact
    // so the wiring can route VS Code and T3 to separate controllers. If the tag
    // were dropped (the old behavior), T3 key/pin presses would drive VS Code.
    guard Bridge.runSurfaceIsolationRegressionTest() else {
        return fail("workspace events did not preserve their surface tag (VS Code/T3 could collide)")
    }

    let targetOne: [String: Any] = ["id": "window-a:first", "kind": "agent-editor", "active": false]
    let targetTwo: [String: Any] = ["id": "window-a:second", "kind": "agent-editor", "active": false]
    let targetThree: [String: Any] = [
        "id": "window-a:third", "kind": "agent-editor", "active": true,
        "provider": "claude", "cwd": "/tmp/project-a",
    ]
    let targets = [targetOne, targetTwo, targetThree]
    let pins = PinMap(path: directory.appendingPathComponent("pins.json").path)
    let gate = PinToggleGate(minimumInterval: 0.65)
    if gate.accept(at: 10) { _ = pins.toggle("window-a:third", targets: targets) }
    if gate.accept(at: 10.05) { _ = pins.toggle("window-a:first", targets: targets) }
    let resolved = pins.resolvedIDs(targets: targets, now: 10.1)
    guard resolved[0] == "window-a:third", resolved.compactMap({ $0 }).count == 1 else {
        return fail("one duplicate PIN burst did not produce exactly one slot for the active third tab")
    }
    guard !gate.accept(at: 10.4), gate.accept(at: 10.7) else {
        return fail("legacy PIN edge gate interval is not deterministic")
    }

    // A multi-window hub election must not erase persisted pins during its
    // short target-list gap, while a genuinely vanished target still expires.
    guard pins.resolvedIDs(targets: [], now: 20)[0] == "window-a:third",
          pins.resolvedIDs(targets: [], now: 39.9)[0] == "window-a:third",
          pins.resolvedIDs(targets: [], now: 40.1)[0] == nil else {
        return fail("missing-target grace did not retain then expire a concrete pin")
    }

    // A window reload re-mints every webview tab id. A pin must re-find the SAME
    // conversation by its stable attributes (provider + title + workspace) and
    // adopt the new id, so the agent key still focuses it. This is the exact bug
    // behind "I pin a tab, switch away, press the agent key, nothing happens".
    let reattach = PinMap(path: directory.appendingPathComponent("reattach.json").path)
    let chatA: [String: Any] = ["id": "view:win1:aaaa", "kind": "agent-editor",
        "provider": "claude", "cwd": "/tmp/proj", "label": "Fix the parser", "active": true]
    let chatB: [String: Any] = ["id": "view:win1:bbbb", "kind": "agent-editor",
        "provider": "claude", "cwd": "/tmp/proj", "label": "Write the docs", "active": false]
    guard reattach.toggle("view:win1:aaaa", targets: [chatA, chatB]) == 0 else {
        return fail("reattach: initial pin did not land on slot 0")
    }
    // Reload: same two conversations, brand-new ids.
    let reloaded: [[String: Any]] = [
        ["id": "view:win2:cccc", "kind": "agent-editor", "provider": "claude", "cwd": "/tmp/proj", "label": "Fix the parser"],
        ["id": "view:win2:dddd", "kind": "agent-editor", "provider": "claude", "cwd": "/tmp/proj", "label": "Write the docs"],
    ]
    guard reattach.resolve(0, targets: reloaded) == "view:win2:cccc" else {
        return fail("reattach: agent key did not re-find the reloaded conversation by title")
    }
    // And it must have adopted the new id so it keeps resolving cheaply.
    guard reattach.resolvedIDs(targets: reloaded)[0] == "view:win2:cccc" else {
        return fail("reattach: pin did not adopt the reloaded conversation's new id")
    }
    // Ambiguous titles (several untitled "Claude Code" tabs) must NEVER be
    // guessed — better an unresolved key than focusing the wrong chat.
    let ambiguous = PinMap(path: directory.appendingPathComponent("ambiguous.json").path)
    _ = ambiguous.toggle("view:win1:e1", targets: [["id": "view:win1:e1", "kind": "agent-editor",
        "provider": "claude", "cwd": "/tmp/proj", "label": "Claude Code"]])
    let duplicates: [[String: Any]] = [
        ["id": "view:win2:f1", "kind": "agent-editor", "provider": "claude", "cwd": "/tmp/proj", "label": "Claude Code"],
        ["id": "view:win2:f2", "kind": "agent-editor", "provider": "claude", "cwd": "/tmp/proj", "label": "Claude Code"],
    ]
    guard ambiguous.resolve(0, targets: duplicates) == nil else {
        return fail("reattach: ambiguous duplicate titles must not resolve to a guessed tab")
    }

    let statusURL = directory.appendingPathComponent("status.json")
    func writeStatus(_ status: String) -> Bool {
        let object: [String: Any] = [
            "sessions": ["session": [
                "status": status,
                "targetId": "window-a:third",
                "provider": "claude",
                "cwd": "/tmp/project-a",
            ]],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return false }
        do { try data.write(to: statusURL, options: .atomic); return true }
        catch { return false }
    }
    let lights = StatusLights(path: statusURL.path)
    lights.setAssignments(pins: ["window-a:third", nil, nil, nil, nil, nil], targets: targets)
    lights.setSelectedSlot(0)

    guard writeStatus("working"),
          let working = (lights.build()["params"] as? [[String: Any]])?.first,
          working["status"] as? String == "working",
          working["c"] as? Int == 0x304FFE,
          working["e"] as? Int == 4 else {
        return fail("selected working target is not blue and breathing")
    }
    guard writeStatus("complete"),
          let complete = (lights.build()["params"] as? [[String: Any]])?.first,
          complete["status"] as? String == "selected",
          complete["c"] as? Int == 0xFFFFFF else {
        return fail("selecting a completed target did not clear green to white")
    }
    guard writeStatus("needs_input"),
          let approval = (lights.build()["params"] as? [[String: Any]])?.first,
          approval["c"] as? Int == 0xFF8F00 else {
        return fail("selected needs-input target is not orange")
    }

    // The Claude status hook cannot know a webview tab's view id, so it writes
    // sessions keyed by cwd + provider with NO targetId. The pinned key must
    // still light blue for "working" via that fallback match — this is the exact
    // path behind "when an agent is working the key should be blue, not white".
    func writeHookStatus(_ status: String) -> Bool {
        let object: [String: Any] = ["sessions": ["hookSession": [
            "status": status,
            "provider": "claude",
            "cwd": "/tmp/project-a",
            "updated": 12_345.0,
        ]]]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return false }
        do { try data.write(to: statusURL, options: .atomic); return true } catch { return false }
    }
    lights.setSelectedSlot(nil) // isolate the non-selected working->blue path
    guard writeHookStatus("working"),
          let hookWorking = (lights.build()["params"] as? [[String: Any]])?.first,
          hookWorking["status"] as? String == "working",
          hookWorking["c"] as? Int == 0x304FFE,
          hookWorking["e"] as? Int == 4 else {
        return fail("a targetId-less Claude-hook status did not light the pinned key blue by cwd+provider")
    }
    lights.setSelectedSlot(0)

    // Claude Desktop accepts only the documented Code links. Verify canonical
    // session identity, safe prompt encoding, and rejection of link injection
    // before any command can reach NSWorkspace.
    let mixedCaseSession = "claude://code/AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
    guard ClaudeDesktopLink.normalized(mixedCaseSession, exactSessionOnly: true)?.absoluteString
            == "claude://code/aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
          ClaudeDesktopLink.normalized(
            "claude://code/session_01AbCdEfGhIjKlMnOpQrStUv",
            exactSessionOnly: true
          )?.absoluteString == "claude://code/session_01AbCdEfGhIjKlMnOpQrStUv",
          ClaudeDesktopLink.normalized("https://claude.ai/code") == nil,
          ClaudeDesktopLink.normalized("claude://user:pass@code/session") == nil,
          ClaudeDesktopLink.normalized("claude://code/new?q=unexpected") == nil,
          let promptURL = ClaudeDesktopLink.newSessionPrefill("ship & verify #1"),
          URLComponents(url: promptURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first?.value == "ship & verify #1" else {
        return fail("Claude Desktop deep-link validation is not strict or lossless")
    }

    // Pin resolves from Claude's explicit focused-session event, never from a
    // "most recently active" guess. Its bridge session ID is the only deep link
    // that reopens the same conversation instead of creating a new agent.
    let sessionRoot = directory.appendingPathComponent("claude-sessions", isDirectory: true)
    let focusLogURL = directory.appendingPathComponent("claude-main.log")
    do {
        try FileManager.default.createDirectory(
            at: sessionRoot.appendingPathComponent("account/org", isDirectory: true),
            withIntermediateDirectories: true
        )
        let older: [String: Any] = [
            "sessionId": "local_old",
            "cliSessionId": "11111111-1111-4111-8111-111111111111",
            "lastFocusedAt": 100,
            "effort": "medium",
            "title": "Older",
            "bridgeSessionIds": ["session_01OlderConversationBridge"],
        ]
        let newest: [String: Any] = [
            "sessionId": "local_new",
            "cliSessionId": "22222222-2222-4222-8222-222222222222",
            "lastFocusedAt": 200,
            "effort": "high",
            "title": "Current session",
            "bridgeSessionIds": ["session_01CurrentConversationBridge"],
        ]
        try JSONSerialization.data(withJSONObject: older).write(
            to: sessionRoot.appendingPathComponent("account/org/old.json")
        )
        try JSONSerialization.data(withJSONObject: newest).write(
            to: sessionRoot.appendingPathComponent("account/org/new.json")
        )
        try Data("""
        2026-07-23 18:00:00 [info] [CCD] LocalSessions.setFocusedSession: sessionId=local_old
        2026-07-23 18:01:00 [info] [CCD] LocalSessions.setFocusedSession: sessionId=local_new
        """.utf8).write(to: focusLogURL)
    } catch {
        return fail("could not prepare Claude Desktop session fixture: \(error)")
    }
    guard let currentClaudeSession = ClaudeDesktopSessionStore(
        rootURL: sessionRoot,
        focusLogURL: focusLogURL
    ).focusedSession(),
          currentClaudeSession.localID == "local_new",
          currentClaudeSession.title == "Current session",
          currentClaudeSession.effort == "high",
          currentClaudeSession.deepLink.absoluteString
            == "claude://code/session_01CurrentConversationBridge" else {
        return fail("Claude Desktop current-session resolution is not exact")
    }

    guard ClaudeDesktopEffort.stepped(from: "low", increasing: false) == nil,
          ClaudeDesktopEffort.stepped(from: "low", increasing: true)?.value == "medium",
          ClaudeDesktopEffort.stepped(from: "high", increasing: true)?.value == "xhigh",
          ClaudeDesktopEffort.stepped(from: "max", increasing: true) == nil else {
        return fail("Claude Desktop effort rotation is not ordered or bounded")
    }

    // The T3 surface ships its own deterministic self-tests (runtime discovery,
    // pairing, sequence gating, dispatch). Exercise them from the same release
    // binary so the isolated T3 backend is covered too.
    do {
        try T3BackendSelfTests.run()
    } catch {
        return fail("T3 backend self-tests failed: \(error)")
    }

    print("AgentMicro bridge regression tests passed")
    return true
}

// MARK: - entry point

#if CODEX_MICRO_MENU_APP
CodexMicroMenuApplication.run()
#else
enum Target { case auto, chatgpt, vscode }

var emulate = false
var runSelfTests = false
var checkAccessibility = false
var target: Target = .auto
var socketPath = defaultCodexBridgeSocketPath()
var vscodeSocket = NSTemporaryDirectory() + "codexbridge-vscode.sock"
var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    switch arg {
    case "--self-test": runSelfTests = true
    case "--check-accessibility": checkAccessibility = true
    case "--emulate": emulate = true
    case "--target":
        guard let value = args.popFirst() else { log("--target needs auto|chatgpt|vscode"); exit(2) }
        switch value {
        case "auto": target = .auto
        case "chatgpt": target = .chatgpt
        case "vscode": target = .vscode
        default: log("unknown target: \(value) (use auto|chatgpt|vscode)"); exit(2)
        }
    case "--socket":
        guard let value = args.popFirst() else { log("--socket needs a path"); exit(2) }
        socketPath = value
    case "--vscode-socket":
        guard let value = args.popFirst() else { log("--vscode-socket needs a path"); exit(2) }
        vscodeSocket = value
    case "--help", "-h":
        print("usage: codexbridge [--target auto|chatgpt|vscode] [--emulate] [--self-test] [--check-accessibility] [--socket PATH] [--vscode-socket PATH]")
        print("  --target auto (default):    follow the Codex / VS Code page selected on iPhone")
        print("  --target chatgpt:           drive only the patched ChatGPT app via the HID shim")
        print("  --target vscode:            drive the Claude/Codex/Kimi VSCode extension + terminals")
        print("  --emulate:                  built-in virtual device / stdin injection, no iPhone needed")
        exit(0)
    default:
        log("unknown argument: \(arg)")
        exit(2)
    }
}

if runSelfTests { exit(runBridgeRegressionTests() ? 0 : 1) }
if checkAccessibility {
    let trusted = AXIsProcessTrusted()
    print("Accessibility: \(trusted ? "trusted" : "not trusted")")
    exit(trusted ? 0 : 1)
}

let server = SocketServer(path: socketPath)

if target == .auto, !emulate {
    server.start()
    let client = VSCodeClient(path: vscodeSocket)
    let pinMap = PinMap(path: NSHomeDirectory() + "/.codexbridge/pins.json")
    let controller = VSCodeController(client: client, pins: pinMap)
    let claudeDesktopController = ClaudeDesktopController(
        path: NSHomeDirectory() + "/.codexbridge/claude-desktop-pins.json"
    )
    let t3Controller = T3Controller()
    let statusPath = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Caches/CodexMicro/status.json")
    let lights = StatusLights(path: statusPath)
    let bridge = Bridge(server: server)
    let activeControlTargetDefaultsKey = "CodexMicroBridge.activeControlTarget"
    // The installed helper's bundle id already owns the standard defaults
    // domain. Opening that same id as an explicit suite produces a macOS
    // warning and is not guaranteed to persist.
    let controlTargetDefaults = UserDefaults.standard
    let storedControlTarget = controlTargetDefaults.string(forKey: activeControlTargetDefaultsKey)
    let knownControlTargets: Set<String> = ["chatgpt", "vscode", "t3code", "claude-desktop"]
    var activeControlTarget = knownControlTargets.contains(storedControlTarget ?? "") ? storedControlTarget! : "chatgpt"

    server.onOutput = bridge.forwardToPhone
    // Channel 2 (the Codex HID stream) is now ALWAYS relayed straight to the
    // ChatGPT shim and never intercepted. The workspace pages send their own key
    // events on the private channel (vscodeKey) instead, tagged with a surface,
    // so the surfaces share no wire and Codex can never be disturbed. The
    // `surface` tag routes each workspace event to its own isolated controller:
    // VS Code events can never reach T3 and vice versa.
    bridge.shouldInterceptDeviceEvents = { false }
    bridge.onVSCodeKey = { method, params, surface in
        switch surface {
        case "t3code": t3Controller.handleEvent(method, params)
        case "claude-desktop": claudeDesktopController.handleEvent(method, params)
        default: controller.handleEvent(method, params)
        }
    }
    bridge.onVSCodeControl = { object in
        switch object["surface"] as? String ?? "vscode" {
        case "t3code": t3Controller.handleBridgeCommand(object)
        case "claude-desktop": claudeDesktopController.handleBridgeCommand(object)
        default: controller.handleBridgeCommand(object)
        }
    }
    bridge.onControlTargetChange = { requested in
        guard knownControlTargets.contains(requested) else { return }
        let changed = activeControlTarget != requested
        activeControlTarget = requested
        controlTargetDefaults.set(requested, forKey: activeControlTargetDefaultsKey)
        if changed { log("control page switched to \(requested)") }
        switch requested {
        case "vscode":
            controller.refreshState()
            lights.emit()
        case "t3code":
            t3Controller.activate() // lazily start + republish the isolated T3 surface
        case "claude-desktop":
            claudeDesktopController.refreshState()
        default: // chatgpt
            bridge.sendCachedState()
        }
    }
    controller.onSelectedSlotChange = { slot in lights.setSelectedSlot(slot) }
    controller.onStateChange = { [weak bridge] targets, pins, selected, connected in
        lights.setAssignments(pins: pins, targets: targets)
        DispatchQueue.main.async {
            bridge?.sendVSCodeState(targets: targets, pins: pins, selected: selected, connected: connected)
        }
    }
    t3Controller.onPublish = {
        [weak bridge] targets, pins, selected, connected, slots, issue, nativeVoiceActive in
        DispatchQueue.main.async {
            bridge?.sendWorkspaceState(
                surface: "t3code", targets: targets, pins: pins,
                selected: selected, connected: connected, slots: slots, issue: issue,
                nativeVoiceActive: nativeVoiceActive
            )
        }
    }
    claudeDesktopController.onPublish = {
        [weak bridge] targets, pins, selected, connected, slots, issue, nativeVoiceActive in
        DispatchQueue.main.async {
            bridge?.sendWorkspaceState(
                surface: "claude-desktop", targets: targets, pins: pins,
                selected: selected, connected: connected, slots: slots, issue: issue,
                nativeVoiceActive: nativeVoiceActive
            )
        }
    }
    lights.onBuild = { object in controller.forwardStatusToExtension(object) }
    lights.push = { [weak bridge] object in
        DispatchQueue.main.async {
            if activeControlTarget == "vscode" { bridge?.sendHostRPC(object) }
        }
    }

    let configHome = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"
    let layoutWatcher = LayoutWatcher(path: (configHome as NSString).expandingTildeInPath + "/config.toml")
    layoutWatcher.onUpdate = { [weak bridge] layout in
        DispatchQueue.main.async { bridge?.sendLayout(layout) }
    }
    // Re-emit the active surface's state on (re)subscribe and on every foreground
    // refresh so a dropped BLE frame always self-heals. Each surface is
    // independent: VS Code re-emits CodexMicro lights, T3 republishes its backend
    // snapshot, Claude Desktop republishes its native-app pin state, and
    // ChatGPT replays its cached lighting.
    let reemitActiveSurface = { [weak bridge] in
        switch activeControlTarget {
        case "vscode":
            controller.refreshState(); lights.emit()
        case "t3code":
            t3Controller.refreshState()
        case "claude-desktop":
            claudeDesktopController.refreshState()
        default:
            bridge?.sendCachedState()
        }
    }
    bridge.onSubscribed = {
        layoutWatcher.onUpdate(layoutWatcher.current)
        controller.refreshState()
        claudeDesktopController.refreshState()
        reemitActiveSurface()
    }
    bridge.onRefreshRequest = { reemitActiveSurface() }

    layoutWatcher.start()
    client.start()
    lights.start()
    log("AgentMicro bridge auto mode — Codex and Claude Desktop are visible on iPhone")
    log("VS Code socket: \(vscodeSocket)")
    bridge.start()
} else if target == .vscode {
    let client = VSCodeClient(path: vscodeSocket)
    let pinMap = PinMap(path: NSHomeDirectory() + "/.codexbridge/pins.json")
    let controller = VSCodeController(client: client, pins: pinMap)
    client.start()
    let statusPath = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Caches/CodexMicro/status.json")
    let lights = StatusLights(path: statusPath)

    if emulate {
        lights.push = { obj in
            if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
               let s = String(data: d, encoding: .utf8) { log("lights \(s)") }
        }
        lights.start()
        log("VSCode target ready (emulate). Socket to extension: \(vscodeSocket)")
        startVSCodeStdinLoop(controller)
    } else {
        let bridge = Bridge(server: server) // shim socket intentionally not started
        // Accept VS Code key events on both the legacy channel-2 interception
        // path and the new private channel, so an updated iPhone app (channel 5)
        // and any older build keep working against this dedicated target.
        bridge.onDeviceEvent = { method, params in controller.handleEvent(method, params) }
        // This dedicated helper drives VS Code only. Ignore any T3-surface event
        // rather than leaking it onto the VS Code controller — surfaces stay
        // isolated even in the fixed-target mode. (Full T3 support is auto mode.)
        bridge.onVSCodeKey = { method, params, surface in
            guard surface == "vscode" else { return }
            controller.handleEvent(method, params)
        }
        bridge.onVSCodeControl = { object in
            guard (object["surface"] as? String ?? "vscode") == "vscode" else { return }
            controller.handleBridgeCommand(object)
        }
        lights.push = { [weak bridge] obj in DispatchQueue.main.async { bridge?.sendHostRPC(obj) } }
        lights.onBuild = { object in controller.forwardStatusToExtension(object) }
        controller.onSelectedSlotChange = { slot in lights.setSelectedSlot(slot) }
        controller.onStateChange = { [weak bridge] targets, pins, selected, connected in
            lights.setAssignments(pins: pins, targets: targets)
            DispatchQueue.main.async {
                bridge?.sendVSCodeState(targets: targets, pins: pins, selected: selected, connected: connected)
            }
        }
        bridge.onSubscribed = { controller.refreshState(); lights.emit() }
        bridge.onRefreshRequest = { controller.refreshState(); lights.emit() }
        // NOTE: the legacy `setPins` path from the retired orange editor-pins
        // screen is intentionally NOT wired. It wrote pins.json as version 1,
        // which PinMap.reload() treats as stale and wipes — a latent way to
        // erase every pin. No current iPhone build sends `setPins`; leaving
        // Bridge.onSetPins nil makes the command a harmless no-op.
        lights.start()
        log("AgentMicro bridge (VS Code target) — keep the AgentMicro app open on your iPhone")
        log("Socket to extension: \(vscodeSocket)")
        bridge.start()
    }
} else {
    server.start()
    if emulate {
        let device = EmuDevice(server: server)
        server.onOutput = device.handleOutput
        server.setPresent(true)
        log("emulated Codex Micro (VID 0x303A, PID 0x8360) is live — no iPhone needed")
        startStdinLoop(device)
    } else {
        let bridge = Bridge(server: server)
        server.onOutput = bridge.forwardToPhone
        // Key binding sync: watch ChatGPT's persisted layout and push it to the
        // phone (on connect and on every change). Emulate mode has no phone, so
        // the watcher only runs here.
        let configHome = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"
        let layoutWatcher = LayoutWatcher(path: (configHome as NSString).expandingTildeInPath + "/config.toml")
        layoutWatcher.onUpdate = { [weak bridge] layout in
            DispatchQueue.main.async { bridge?.sendLayout(layout) }
        }
        bridge.onSubscribed = { layoutWatcher.onUpdate(layoutWatcher.current) }
        layoutWatcher.start()
        log("AgentMicro bridge starting — keep the AgentMicro app open on your iPhone")
        bridge.start()
    }
}

RunLoop.main.run()
#endif
