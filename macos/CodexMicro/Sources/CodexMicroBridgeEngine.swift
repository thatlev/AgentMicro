import Foundation
import Darwin

/// Owns the existing AgentMicro bridge graph inside the menu-bar process.
/// The BLE and ChatGPT wire protocols intentionally remain unchanged.
final class CodexMicroBridgeEngine {
    private let server: SocketServer
    private let socketPath: String
    private let bridge: Bridge
    private let vscodeClient: VSCodeClient
    private let pinMap: PinMap
    private let vscodeController: VSCodeController
    private let claudeDesktopController: ClaudeDesktopController
    private let t3Controller: T3Controller
    private let lights: StatusLights
    private let layoutWatcher: LayoutWatcher
    private let controlTargetDefaults = UserDefaults.standard
    private let controlTargetDefaultsKey = "CodexMicroBridge.activeControlTarget"
    private let knownControlTargets: Set<String> = [
        "chatgpt", "vscode", "t3code", "claude-desktop",
    ]

    private var activeControlTarget: String
    private var hasStarted = false
    private(set) var isPaused = false

    var onStatusChange: (CodexMicroBridgeStatus) -> Void = { _ in } {
        didSet {
            bridge.onStatusChange = onStatusChange
        }
    }

    init(
        socketPath: String = defaultCodexBridgeSocketPath(),
        vscodeSocket: String = NSTemporaryDirectory() + "codexbridge-vscode.sock"
    ) {
        self.socketPath = socketPath
        server = SocketServer(path: socketPath)
        bridge = Bridge(server: server)
        vscodeClient = VSCodeClient(path: vscodeSocket)
        pinMap = PinMap(path: NSHomeDirectory() + "/.codexbridge/pins.json")
        vscodeController = VSCodeController(client: vscodeClient, pins: pinMap)
        claudeDesktopController = ClaudeDesktopController(
            path: NSHomeDirectory() + "/.codexbridge/claude-desktop-pins.json"
        )
        t3Controller = T3Controller()

        let statusPath = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Caches/CodexMicro/status.json")
        lights = StatusLights(path: statusPath)

        let configHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? NSHomeDirectory() + "/.codex"
        layoutWatcher = LayoutWatcher(
            path: (configHome as NSString).expandingTildeInPath + "/config.toml"
        )

        let storedTarget = controlTargetDefaults.string(forKey: controlTargetDefaultsKey)
        if let storedTarget, knownControlTargets.contains(storedTarget) {
            activeControlTarget = storedTarget
        } else {
            activeControlTarget = "chatgpt"
        }

        configureGraph()
    }

    func start() {
        guard !hasStarted else {
            resume()
            return
        }
        hasStarted = true
        isPaused = false
        server.start()
        LegacySocketAlias.install(target: socketPath)
        layoutWatcher.start()
        vscodeClient.start()
        lights.start()
        bridge.start()
        log("AgentMicro menu-bar bridge started")
    }

    func pause() {
        guard hasStarted, !isPaused else { return }
        isPaused = true
        bridge.stop()
        log("AgentMicro bridge paused")
    }

    func resume() {
        guard hasStarted, isPaused else { return }
        isPaused = false
        bridge.start()
        log("AgentMicro bridge resumed")
    }

    func reconnect() {
        guard hasStarted else {
            start()
            return
        }
        isPaused = false
        bridge.reconnect()
        log("AgentMicro connection restart requested")
    }

    func ensureConnection() {
        guard hasStarted else {
            start()
            return
        }
        guard !isPaused else { return }
        bridge.ensureConnected()
    }

    func shutdown() {
        guard hasStarted else { return }
        bridge.stop()
        server.stop()
        LegacySocketAlias.removeIfOwned(target: socketPath)
        hasStarted = false
        isPaused = true
    }

    private func configureGraph() {
        server.onOutput = bridge.forwardToPhone
        bridge.shouldInterceptDeviceEvents = { false }

        bridge.onVSCodeKey = { [weak self] method, params, surface in
            guard let self else { return }
            switch surface {
            case "t3code":
                self.t3Controller.handleEvent(method, params)
            case "claude-desktop":
                self.claudeDesktopController.handleEvent(method, params)
            default:
                self.vscodeController.handleEvent(method, params)
            }
        }

        bridge.onVSCodeControl = { [weak self] object in
            guard let self else { return }
            switch object["surface"] as? String ?? "vscode" {
            case "t3code":
                self.t3Controller.handleBridgeCommand(object)
            case "claude-desktop":
                self.claudeDesktopController.handleBridgeCommand(object)
            default:
                self.vscodeController.handleBridgeCommand(object)
            }
        }

        bridge.onControlTargetChange = { [weak self] requested in
            self?.selectControlTarget(requested)
        }

        vscodeController.onSelectedSlotChange = { [weak self] slot in
            self?.lights.setSelectedSlot(slot)
        }

        vscodeController.onStateChange = {
            [weak self] targets, pins, selected, connected in
            guard let self else { return }
            self.lights.setAssignments(pins: pins, targets: targets)
            DispatchQueue.main.async {
                self.bridge.sendVSCodeState(
                    targets: targets,
                    pins: pins,
                    selected: selected,
                    connected: connected
                )
            }
        }

        t3Controller.onPublish = {
            [weak self] targets, pins, selected, connected, slots, issue, nativeVoiceActive in
            guard let self else { return }
            DispatchQueue.main.async {
                self.bridge.sendWorkspaceState(
                    surface: "t3code",
                    targets: targets,
                    pins: pins,
                    selected: selected,
                    connected: connected,
                    slots: slots,
                    issue: issue,
                    nativeVoiceActive: nativeVoiceActive
                )
            }
        }

        claudeDesktopController.onPublish = {
            [weak self] targets, pins, selected, connected, slots, issue, nativeVoiceActive in
            guard let self else { return }
            DispatchQueue.main.async {
                self.bridge.sendWorkspaceState(
                    surface: "claude-desktop",
                    targets: targets,
                    pins: pins,
                    selected: selected,
                    connected: connected,
                    slots: slots,
                    issue: issue,
                    nativeVoiceActive: nativeVoiceActive
                )
            }
        }

        lights.onBuild = { [weak self] object in
            self?.vscodeController.forwardStatusToExtension(object)
        }
        lights.push = { [weak self] object in
            guard let self, self.activeControlTarget == "vscode" else { return }
            DispatchQueue.main.async {
                self.bridge.sendHostRPC(object)
            }
        }

        layoutWatcher.onUpdate = { [weak self] layout in
            DispatchQueue.main.async {
                self?.bridge.sendLayout(layout)
            }
        }

        bridge.onSubscribed = { [weak self] in
            guard let self else { return }
            self.layoutWatcher.onUpdate(self.layoutWatcher.current)
            self.vscodeController.refreshState()
            self.claudeDesktopController.refreshState()
            self.reemitActiveSurface()
        }
        bridge.onRefreshRequest = { [weak self] in
            self?.reemitActiveSurface()
        }
    }

    private func selectControlTarget(_ requested: String) {
        guard knownControlTargets.contains(requested) else { return }
        let changed = activeControlTarget != requested
        activeControlTarget = requested
        controlTargetDefaults.set(requested, forKey: controlTargetDefaultsKey)
        if changed {
            log("control page switched to \(requested)")
        }
        reemitActiveSurface()
    }

    private func reemitActiveSurface() {
        switch activeControlTarget {
        case "vscode":
            vscodeController.refreshState()
            lights.emit()
        case "t3code":
            t3Controller.activate()
        case "claude-desktop":
            claudeDesktopController.refreshState()
        default:
            bridge.sendCachedState()
        }
    }
}

/// Existing installations may still contain the previous shim, whose socket
/// path was `/tmp/codexbridge.sock`. A temporary symlink lets those already
/// patched builds reach the new per-user socket without modifying ChatGPT
/// again. Fresh patches use the per-user path directly.
private enum LegacySocketAlias {
    private static let path = "/tmp/codexbridge.sock"

    static func install(target: String) {
        guard target != path else { return }

        var information = stat()
        if lstat(path, &information) == 0 {
            let type = information.st_mode & S_IFMT
            if type == S_IFLNK {
                if currentTarget() == target { return }
                guard unlink(path) == 0 else {
                    log("legacy socket alias could not replace an unrelated symlink")
                    return
                }
            } else if type == S_IFSOCK {
                guard !socketAcceptsConnections(path) else {
                    log("legacy socket path is owned by another running helper; alias not installed")
                    return
                }
                guard unlink(path) == 0 else {
                    log("stale legacy socket could not be removed")
                    return
                }
            } else {
                log("legacy socket alias not installed because the path is not a socket")
                return
            }
        }

        guard symlink(target, path) == 0 else {
            log("legacy socket alias could not be installed: \(String(cString: strerror(errno)))")
            return
        }
        log("legacy ChatGPT socket compatibility enabled")
    }

    static func removeIfOwned(target: String) {
        guard currentTarget() == target else { return }
        unlink(path)
    }

    private static func currentTarget() -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let count = readlink(path, &buffer, buffer.count - 1)
        guard count > 0 else { return nil }
        buffer[Int(count)] = 0
        return String(cString: buffer)
    }

    private static func socketAcceptsConnections(_ socketPath: String) -> Bool {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let maximumPathLength = MemoryLayout.size(ofValue: address.sun_path) - 1
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            socketPath.withCString { source in
                strncpy(
                    UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self),
                    source,
                    maximumPathLength
                )
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                connect(
                    descriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        return result == 0
    }
}
