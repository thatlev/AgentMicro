import AppKit
import Combine
import Foundation
import ServiceManagement
import UserNotifications

enum OverallState: Equatable {
    case healthy
    case connecting
    case actionRequired
    case failed
    case idle
}

/// The single source of truth shared by the status item, popover, settings,
/// onboarding, bridge engine, and ChatGPT patch manager.
///
/// `.healthy` is intentionally strict: the ChatGPT integration must be a
/// compatible patch and the bridge must have observed a real
/// ChatGPT → iPhone → ChatGPT round trip.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var overallState: OverallState = .connecting
    @Published private(set) var headline = "Starting AgentMicro"
    @Published private(set) var detail = "Checking the iPhone and ChatGPT integration."
    @Published private(set) var phoneStatus = "Starting"
    @Published private(set) var chatGPTStatus = "Checking"
    @Published private(set) var patchStatusText = "Checking"
    @Published private(set) var lastRoundTripText = "Not verified yet"
    @Published private(set) var isPaused = false
    @Published private(set) var launchAtLogin = false
    @Published private(set) var showOnboarding: Bool
    @Published private(set) var isBusy = false
    @Published private(set) var canPatch = false
    @Published private(set) var canRestore = false
    @Published private(set) var integrationNeedsUpdate = false

    private let bridgeEngine: CodexMicroBridgeEngine
    private let patchManager: PatchManager
    private let legacyMigration: LegacyMigrationResult
    private let defaults: UserDefaults
    private var bridgeStatus = CodexMicroBridgeStatus()
    private var refreshTask: Task<Void, Never>?
    private var presentationTask: Task<Void, Never>?
    private var operationFailure: String?
    private var operationMessage: String?
    private var hasStarted = false
    private var subscriptions = Set<AnyCancellable>()
    private var workspaceObservationTokens: [NSObjectProtocol] = []
    private let healthyRoundTripMaximumAge: TimeInterval = 45
    private let patchFallbackRefreshInterval: Duration = .seconds(300)

    private enum DefaultsKey {
        static let completedOnboarding = "CodexMicro.completedOnboarding.v1"
        static let requestedLaunchAtLogin = "CodexMicro.requestedLaunchAtLogin.v1"
        static let lastUnpatchedNotification = "CodexMicro.lastUnpatchedNotification.v1"
    }

    init(
        legacyMigration: LegacyMigrationResult = LegacyMigrationResult(),
        bridgeEngine: CodexMicroBridgeEngine = CodexMicroBridgeEngine(),
        patchManager: PatchManager? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.legacyMigration = legacyMigration
        self.bridgeEngine = bridgeEngine
        self.patchManager = patchManager ?? PatchManager()
        self.defaults = defaults
        showOnboarding = !defaults.bool(forKey: DefaultsKey.completedOnboarding)
        launchAtLogin = SMAppService.mainApp.status == .enabled

        bridgeEngine.onStatusChange = { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.bridgeStatus = status
                self.recomputePresentation()
            }
        }

        self.patchManager.$progress
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.operationMessage != nil else { return }
                self.recomputePresentation()
            }
            .store(in: &subscriptions)
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        bridgeEngine.start()

        if !defaults.bool(forKey: DefaultsKey.requestedLaunchAtLogin) {
            defaults.set(true, forKey: DefaultsKey.requestedLaunchAtLogin)
            setLaunchAtLogin(true)
        } else {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }

        if !legacyMigration.disabledLaunchAgents.isEmpty {
            AppLogStore.shared.append(
                "Migrated \(legacyMigration.disabledLaunchAgents.count) previous helper launch item(s)"
            )
        }
        for note in legacyMigration.notes {
            AppLogStore.shared.append("Migration note: \(note)")
        }

        requestNotificationPermission()
        observeChatGPTLifecycle()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshPatchStatus()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: self.patchFallbackRefreshInterval)
                } catch {
                    return
                }
                await self.refreshPatchStatus()
            }
        }
        presentationTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    return
                }
                self?.recomputePresentation()
            }
        }
        recomputePresentation()
    }

    func shutdown() {
        refreshTask?.cancel()
        refreshTask = nil
        presentationTask?.cancel()
        presentationTask = nil
        let notificationCenter = NSWorkspace.shared.notificationCenter
        for token in workspaceObservationTokens {
            notificationCenter.removeObserver(token)
        }
        workspaceObservationTokens.removeAll()
        bridgeEngine.shutdown()
        hasStarted = false
    }

    func togglePause() {
        operationFailure = nil
        operationMessage = nil
        if isPaused {
            isPaused = false
            bridgeEngine.resume()
            bridgeEngine.reconnect()
        } else {
            isPaused = true
            bridgeEngine.pause()
        }
        recomputePresentation()
    }

    func reconnect() {
        guard !isBusy else { return }
        operationFailure = nil
        operationMessage = nil
        if isPaused {
            isPaused = false
            bridgeEngine.resume()
        }
        bridgeEngine.reconnect()
        recomputePresentation()
        Task { [weak self] in
            await self?.refreshPatchStatus()
        }
    }

    func refreshStatus() {
        guard !isBusy else { return }
        bridgeEngine.ensureConnection()
        Task { [weak self] in
            await self?.refreshPatchStatus()
        }
    }

    func openChatGPT() {
        operationFailure = nil
        operationMessage = nil
        let appURL = patchManager.snapshot.appURL
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            recomputePresentation()
            return
        }
        NSWorkspace.shared.openApplication(
            at: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { [weak self] _, error in
            Task { @MainActor [weak self] in
                if let error {
                    self?.operationFailure = "ChatGPT could not be opened: \(error.localizedDescription)"
                }
                self?.recomputePresentation()
            }
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await self?.refreshPatchStatus()
        }
    }

    func patchChatGPT() {
        guard !isBusy else { return }
        Task { [weak self] in
            guard let self else { return }
            self.isBusy = true
            self.operationFailure = nil
            self.operationMessage = "Preparing the ChatGPT integration."
            self.recomputePresentation()

            let result = await self.patchManager.patch(relaunch: true)
            self.isBusy = false
            self.operationMessage = nil
            if result.succeeded {
                self.operationFailure = nil
                self.bridgeEngine.reconnect()
            } else {
                self.operationFailure = result.message
            }
            self.recomputePresentation()
        }
    }

    func restoreChatGPT() {
        guard !isBusy else { return }
        Task { [weak self] in
            guard let self else { return }
            self.isBusy = true
            self.operationFailure = nil
            self.operationMessage = "Preparing the pristine ChatGPT backup."
            self.recomputePresentation()

            let result = await self.patchManager.restore(relaunch: true)
            self.isBusy = false
            self.operationMessage = nil
            if result.succeeded {
                self.operationFailure = nil
                self.bridgeEngine.reconnect()
            } else {
                self.operationFailure = result.message
            }
            self.recomputePresentation()
        }
    }

    func copyDiagnostics() {
        let snapshot = patchManager.snapshot
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "development"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "local"
        let roundTrip = bridgeStatus.lastSuccessfulRoundTrip
            .map { ISO8601DateFormatter().string(from: $0) }
            ?? "never"
        let report = """
        AgentMicro diagnostics
        Generated: \(ISO8601DateFormatter().string(from: Date()))
        App: \(version) (\(build))
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Architecture: arm64
        Overall: \(String(describing: overallState))
        Paused: \(isPaused)
        Bluetooth: \(bridgeStatus.bluetooth.rawValue)
        Phone linked: \(bridgeStatus.phoneLinked)
        Report stream ready: \(bridgeStatus.reportStreamReady)
        ChatGPT bridge linked: \(bridgeStatus.chatGPTLinked)
        End-to-end: \(bridgeStatus.endToEnd.rawValue)
        Last successful round trip: \(roundTrip)
        ChatGPT installed: \(snapshot.installed)
        ChatGPT running: \(snapshot.running)
        ChatGPT version/build: \(snapshot.version) / \(snapshot.build)
        Integration: \(snapshot.state.rawValue)
        Backup available: \(snapshot.backupAvailable)
        """

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        AppLogStore.shared.append("Copied redacted diagnostics")
    }

    func openLogs() {
        let logURL = AppLogStore.shared.logURL
        if FileManager.default.fileExists(atPath: logURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([logURL])
        } else {
            NSWorkspace.shared.open(AppLogStore.shared.directoryURL)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            AppLogStore.shared.append(
                "Launch at Login could not be \(enabled ? "enabled" : "disabled"): "
                    + error.localizedDescription
            )
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func completeOnboarding() {
        defaults.set(true, forKey: DefaultsKey.completedOnboarding)
        showOnboarding = false
    }

    private func refreshPatchStatus() async {
        guard !isBusy else { return }
        await patchManager.refresh()
        notifyIfNewUnpatchedBuild()
        recomputePresentation()
    }

    private func recomputePresentation() {
        let patch = patchManager.snapshot
        canPatch = patch.canPatch
        canRestore = patch.canRestore
        integrationNeedsUpdate = patch.state == .integrationUpdateRequired
        phoneStatus = phoneStatusText
        patchStatusText = patchStatus
        chatGPTStatus = chatGPTStatusText
        lastRoundTripText = lastRoundTripDescription

        if let operationFailure {
            overallState = .failed
            headline = "Action failed"
            detail = operationFailure
            return
        }
        if let operationMessage {
            overallState = .connecting
            headline = patchManager.progress?.message ?? operationMessage
            detail = "AgentMicro is waiting for the current operation to finish safely."
            return
        }
        if isPaused {
            overallState = .idle
            headline = "Bridge paused"
            detail = "Resume AgentMicro to reconnect the iPhone and ChatGPT."
            return
        }
        if legacyMigration.requiresAttention {
            overallState = .actionRequired
            headline = "Previous helper needs attention"
            detail = legacyMigration.notes.first
                ?? "AgentMicro could not safely finish migrating the previous helper."
            return
        }

        switch patch.state {
        case .notInstalled:
            overallState = .idle
            headline = "ChatGPT not found"
            detail = "Install ChatGPT in Applications, then check again."
            return
        case .runtimeUnavailable:
            overallState = .failed
            headline = "Integration runtime unavailable"
            detail = patch.reason
            return
        case .compatiblePristine:
            overallState = .actionRequired
            headline = "ChatGPT needs the integration"
            detail = "Use Patch ChatGPT once, then AgentMicro can verify the complete route."
            return
        case .integrationUpdateRequired:
            overallState = .actionRequired
            headline = "ChatGPT integration needs update"
            detail = patch.reason
            return
        case .incompatible:
            overallState = .actionRequired
            headline = patch.patched ? "ChatGPT integration needs attention" : "ChatGPT build not supported"
            detail = patch.reason
            return
        case .compatiblePatched:
            break
        }

        switch bridgeStatus.bluetooth {
        case .denied:
            overallState = .actionRequired
            headline = "Bluetooth permission required"
            detail = "Allow AgentMicro in System Settings › Privacy & Security › Bluetooth."
        case .poweredOff:
            overallState = .actionRequired
            headline = "Bluetooth is off"
            detail = "Turn on Bluetooth to connect the iPhone."
        case .unavailable:
            overallState = .failed
            headline = "Bluetooth unavailable"
            detail = "This Mac cannot start the Bluetooth connection."
        case .unknown, .scanning:
            overallState = .connecting
            headline = "Looking for your iPhone"
            detail = "Open AgentMicro on the iPhone and keep it nearby."
        case .connecting:
            overallState = .connecting
            headline = "Connecting to iPhone"
            detail = "Bluetooth found the iPhone and is establishing the bridge."
        case .linked:
            presentLinkedBridgeState(patch: patch)
        }
    }

    private func presentLinkedBridgeState(patch: ChatGPTPatchSnapshot) {
        if bridgeStatus.isOperational,
           let verifiedAt = bridgeStatus.lastSuccessfulRoundTrip,
           Date().timeIntervalSince(verifiedAt) <= healthyRoundTripMaximumAge {
            overallState = .healthy
            headline = "Fully connected"
            detail = "ChatGPT and the iPhone exchanged data successfully."
            return
        }
        if bridgeStatus.isOperational {
            overallState = .connecting
            headline = "Rechecking the complete route"
            detail = "The last successful round trip is stale; green will return after a fresh check."
            return
        }
        if !bridgeStatus.reportStreamReady {
            overallState = .connecting
            headline = "Preparing the iPhone link"
            detail = "Bluetooth is connected; waiting for the control report stream."
            return
        }
        if !patch.running {
            overallState = .idle
            headline = "ChatGPT is not running"
            detail = "Open ChatGPT to complete the end-to-end check."
            return
        }
        if !bridgeStatus.chatGPTLinked || bridgeStatus.endToEnd == .waitingForChatGPT {
            overallState = .connecting
            headline = "Waiting for ChatGPT"
            detail = "The iPhone is ready; ChatGPT has not opened the local bridge yet."
            return
        }
        if bridgeStatus.endToEnd == .handshaking {
            overallState = .connecting
            headline = "Checking ChatGPT now"
            detail = bridgeStatus.detail
            return
        }
        if bridgeStatus.endToEnd == .recovering {
            let value = bridgeStatus.detail.lowercased()
            if value.contains("did not complete") || value.contains("failed") {
                overallState = .failed
                headline = "End-to-end check failed"
            } else {
                overallState = .connecting
                headline = "Reconnecting"
            }
            detail = bridgeStatus.detail
            return
        }

        overallState = .connecting
        headline = "Verifying the complete route"
        detail = bridgeStatus.detail
    }

    private var phoneStatusText: String {
        if isPaused { return "Paused" }
        switch bridgeStatus.bluetooth {
        case .unknown:
            return "Starting"
        case .unavailable:
            return "Unavailable"
        case .denied:
            return "Permission required"
        case .poweredOff:
            return "Bluetooth off"
        case .scanning:
            return "Searching"
        case .connecting:
            return "Connecting"
        case .linked:
            if bridgeStatus.reportStreamReady {
                return "Ready"
            }
            return "Linked"
        }
    }

    private var chatGPTStatusText: String {
        let patch = patchManager.snapshot
        guard patch.installed else { return "Not found" }
        guard patch.running else { return "Not running" }
        guard patch.state == .compatiblePatched else {
            switch patch.state {
            case .compatiblePristine:
                return "Patch required"
            case .integrationUpdateRequired:
                return "Update required"
            default:
                return "Integration unavailable"
            }
        }
        if bridgeStatus.isOperational { return "Verified" }
        if bridgeStatus.chatGPTLinked { return "Checking" }
        return "Waiting"
    }

    private var patchStatus: String {
        switch patchManager.snapshot.state {
        case .notInstalled:
            return "Not found"
        case .runtimeUnavailable:
            return "Runtime unavailable"
        case .compatiblePristine:
            return "Patch required"
        case .compatiblePatched:
            return "Compatible & patched"
        case .integrationUpdateRequired:
            return "Update required"
        case .incompatible:
            return patchManager.snapshot.patched
                ? "Patch needs update"
                : "Unsupported build"
        }
    }

    private var lastRoundTripDescription: String {
        guard let date = bridgeStatus.lastSuccessfulRoundTrip else {
            return "Not verified yet"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { granted, error in
            if let error {
                AppLogStore.shared.append(
                    "Notification permission check failed: \(error.localizedDescription)"
                )
            } else {
                AppLogStore.shared.append(
                    "Local integration notifications \(granted ? "enabled" : "disabled")"
                )
            }
        }
    }

    private func observeChatGPTLifecycle() {
        guard workspaceObservationTokens.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ]
        for name in names {
            let token = center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let application = notification.userInfo?[
                    NSWorkspace.applicationUserInfoKey
                ] as? NSRunningApplication,
                    application.bundleIdentifier == "com.openai.codex"
                        || application.bundleIdentifier == "com.openai.chat"
                else {
                    return
                }
                Task { @MainActor [weak self] in
                    await self?.refreshPatchStatus()
                }
            }
            workspaceObservationTokens.append(token)
        }
    }

    private func notifyIfNewUnpatchedBuild() {
        let snapshot = patchManager.snapshot
        guard snapshot.installed,
              snapshot.state == .compatiblePristine
                || snapshot.state == .integrationUpdateRequired
                || snapshot.state == .incompatible
        else {
            return
        }
        let identity = [
            snapshot.bundleIdentifier,
            snapshot.version,
            snapshot.build,
            snapshot.state.rawValue,
        ].joined(separator: ":")
        guard defaults.string(forKey: DefaultsKey.lastUnpatchedNotification) != identity else {
            return
        }
        defaults.set(identity, forKey: DefaultsKey.lastUnpatchedNotification)

        let content = UNMutableNotificationContent()
        content.title = "ChatGPT integration needs attention"
        switch snapshot.state {
        case .compatiblePristine:
            content.body = "A ChatGPT build without the AgentMicro integration was detected."
        case .integrationUpdateRequired:
            content.body = "Restore ChatGPT, then patch it to update the AgentMicro integration."
        default:
            content.body = "This ChatGPT build no longer matches the supported integration."
        }
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "codex-micro-chatgpt-\(identity.hashValue)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                AppLogStore.shared.append(
                    "Could not show the ChatGPT integration notification: "
                        + error.localizedDescription
                )
            }
        }
    }
}
