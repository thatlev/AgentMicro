import AppKit
import Darwin

enum CodexMicroMenuApplication {
    private static var retainedDelegate: CodexMicroAppDelegate?

    static func run() -> Never {
        MainActor.assumeIsolated {
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)

            let delegate = CodexMicroAppDelegate()
            retainedDelegate = delegate
            application.delegate = delegate
            application.run()
            exit(EXIT_SUCCESS)
        }
    }
}

@MainActor
final class CodexMicroAppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var menuBarController: MenuBarController?
    private var quitRequested = false
    private var didShutDown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard isRunningFromStableInstallLocation else {
            showMoveToApplicationsAlert()
            NSApp.terminate(nil)
            return
        }
        guard enforceSingleInstance() else {
            NSApp.terminate(nil)
            return
        }

        AppLogStore.shared.installBridgeSink()
        AppLogStore.shared.append("AgentMicro \(versionDescription) launched")

        let migration = LegacyMigrationManager.disableInvisibleHelperIfNeeded()
        let model = AppModel(legacyMigration: migration)
        self.model = model
        menuBarController = MenuBarController(
            model: model,
            onQuit: { [weak self] in self?.requestQuit() }
        )

        model.start()
        menuBarController?.showOnboardingIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        shutdownIfNeeded()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model?.isBusy == true else { return .terminateNow }

        // A critical patch/restore may have started between the popover click
        // and this next-run-loop termination request. Keep the safety gate and
        // allow a fresh Quit request after the operation finishes.
        quitRequested = false
        sender.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "ChatGPT operation in progress"
        alert.informativeText =
            "AgentMicro must stay open until the current patch or restore finishes safely."
        alert.addButton(withTitle: "Keep AgentMicro Open")
        alert.runModal()
        return .terminateCancel
    }

    private func requestQuit() {
        guard !quitRequested else { return }
        quitRequested = true
        NSApp.terminate(nil)
    }

    private func shutdownIfNeeded() {
        guard !didShutDown else { return }
        didShutDown = true
        model?.shutdown()
        AppLogStore.shared.flush()
    }

    private func enforceSingleInstance() -> Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return true }
        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: identifier
        )
        guard running.count > 1 else { return true }

        if let existing = running.first(where: { $0.processIdentifier != getpid() }) {
            existing.activate(options: [.activateAllWindows])
        }
        return false
    }

    private var versionDescription: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "development"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
            as? String ?? "local"
        return "\(version) (\(build))"
    }

    private var isRunningFromStableInstallLocation: Bool {
        if ProcessInfo.processInfo.environment["CODEX_MICRO_ALLOW_UNINSTALLED"] == "1" {
            return true
        }
        let bundlePath = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let homeApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .resolvingSymlinksInPath()
            .path
        return bundlePath.hasPrefix("/Applications/")
            || bundlePath.hasPrefix(homeApplications + "/")
    }

    private func showMoveToApplicationsAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Move AgentMicro to Applications"
        alert.informativeText =
            "Drag AgentMicro to the Applications folder before opening it. "
            + "Launch at Login and helper migration are not changed while the app is on a disk image."
        alert.addButton(withTitle: "Quit")
        alert.runModal()
    }
}
