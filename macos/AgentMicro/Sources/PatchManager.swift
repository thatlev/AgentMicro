import Combine
import Foundation

enum ChatGPTPatchState: String, Codable, Sendable {
    case notInstalled = "not-installed"
    case runtimeUnavailable = "runtime-unavailable"
    case compatiblePristine = "compatible-pristine"
    case compatiblePatched = "compatible-patched"
    case integrationUpdateRequired = "integration-update-required"
    case incompatible

    var isPatched: Bool { self == .compatiblePatched }
    var isCompatible: Bool {
        self == .compatiblePristine || self == .compatiblePatched
    }
}

enum ChatGPTBackupKind: String, Codable, Sendable {
    case none
    case completeSigned = "complete-signed"
    case legacyResources = "legacy-resources"

    var restoresOpenAISignature: Bool { self == .completeSigned }
}

struct ChatGPTPatchSnapshot: Equatable, Sendable {
    var installed: Bool
    var running: Bool
    var appURL: URL
    var bundleIdentifier: String
    var version: String
    var build: String
    var state: ChatGPTPatchState
    var patched: Bool
    var compatible: Bool
    var backupAvailable: Bool
    var backupKind: ChatGPTBackupKind
    var canPatch: Bool
    var canRestore: Bool
    var reason: String

    static func initial(appURL: URL) -> Self {
        Self(
            installed: false,
            running: false,
            appURL: appURL,
            bundleIdentifier: "",
            version: "",
            build: "",
            state: .notInstalled,
            patched: false,
            compatible: false,
            backupAvailable: false,
            backupKind: .none,
            canPatch: false,
            canRestore: false,
            reason: "Checking ChatGPT…"
        )
    }
}

enum PatchOperation: String, Sendable {
    case patch
    case restore
}

struct PatchProgress: Equatable, Sendable {
    let operation: PatchOperation
    let stage: String
    let message: String
    let fraction: Double?
}

struct PatchOperationResult: Equatable, Sendable {
    let operation: PatchOperation
    let succeeded: Bool
    let message: String
    let exitCode: Int32
    let finishedAt: Date
}

enum PatchManagerError: LocalizedError {
    case busy
    case missingScript
    case invalidStatus
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .busy:
            return "Another ChatGPT patch operation is already running."
        case .missingScript:
            return "The AgentMicro patch runtime is incomplete."
        case .invalidStatus:
            return "AgentMicro received an invalid ChatGPT status response."
        case .launchFailed(let message):
            return "The ChatGPT patch manager could not start: \(message)"
        }
    }
}

/// Owns read-only ChatGPT patch detection plus explicit, user-confirmed patch
/// and restore operations. This object never force-quits ChatGPT. The bundled
/// script asks ChatGPT to terminate normally and aborts before replacement if
/// it does not close.
@MainActor
final class PatchManager: ObservableObject {
    @Published private(set) var snapshot: ChatGPTPatchSnapshot
    @Published private(set) var progress: PatchProgress?
    @Published private(set) var lastResult: PatchOperationResult?
    @Published private(set) var isBusy = false

    let appURL: URL
    let runtimeURL: URL

    private let scriptURL: URL
    private let baseEnvironment: [String: String]
    private var progressTicker: AnyCancellable?
    private var progressTarget = 0.0

    init(
        appURL: URL = URL(fileURLWithPath: "/Applications/ChatGPT.app"),
        runtimeURL: URL? = nil,
        scriptURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.appURL = appURL.standardizedFileURL

        let resolvedRuntime = runtimeURL
            ?? Self.resolveRuntimeURL(environment: environment)
        self.runtimeURL = resolvedRuntime
        self.scriptURL = scriptURL
            ?? Self.resolveScriptURL(runtimeURL: resolvedRuntime)

        var configuredEnvironment = environment
        configuredEnvironment["CHATGPT_APP"] = self.appURL.path
        configuredEnvironment["AGENT_MICRO_PATCH_RUNTIME"] = resolvedRuntime.path
        configuredEnvironment["AGENT_MICRO_DEVELOPER_FALLBACK"] =
            Self.isRunningFromApplicationBundle ? "0" : "1"

        Self.setPathIfPresent(
            key: "AGENT_MICRO_NODE",
            candidates: [
                resolvedRuntime.appendingPathComponent("node"),
                resolvedRuntime.appendingPathComponent("bin/node"),
            ],
            in: &configuredEnvironment
        )
        Self.setPathIfPresent(
            key: "AGENT_MICRO_ASAR_JS",
            candidates: [
                resolvedRuntime.appendingPathComponent(
                    "node_modules/@electron/asar/bin/asar.mjs"
                ),
                resolvedRuntime.appendingPathComponent(
                    "node_modules/@electron/asar/bin/asar.js"
                ),
            ],
            in: &configuredEnvironment
        )
        Self.setPathIfPresent(
            key: "AGENT_MICRO_INSPECTOR",
            candidates: [resolvedRuntime.appendingPathComponent("asar-inspect.cjs")],
            in: &configuredEnvironment
        )
        Self.setPathIfPresent(
            key: "AGENT_MICRO_SHIM",
            candidates: [resolvedRuntime.appendingPathComponent("codex-hid-shim.js")],
            in: &configuredEnvironment
        )

        baseEnvironment = configuredEnvironment
        snapshot = .initial(appURL: self.appURL)
    }

    /// Refreshes installed/running/version/compatibility/backup state without
    /// changing ChatGPT. This is safe to call whenever the popover opens.
    func refresh() async {
        guard !isBusy else { return }
        do {
            let execution = try await runScript(arguments: ["--status", "--json"])
            snapshot = try Self.decodeStatus(
                from: execution.output,
                fallbackAppURL: appURL
            )
        } catch {
            snapshot = ChatGPTPatchSnapshot(
                installed: FileManager.default.fileExists(atPath: appURL.path),
                running: false,
                appURL: appURL,
                bundleIdentifier: "",
                version: "",
                build: "",
                state: .runtimeUnavailable,
                patched: false,
                compatible: false,
                backupAvailable: false,
                backupKind: .none,
                canPatch: false,
                canRestore: false,
                reason: error.localizedDescription
            )
            AppLogStore.shared.append("Patch status failed: \(error.localizedDescription)")
        }
    }

    /// Applies the patch only after the caller has obtained explicit user
    /// confirmation. ChatGPT is reopened by default after a successful swap.
    @discardableResult
    func patch(relaunch: Bool = true) async -> PatchOperationResult {
        await perform(.patch, relaunch: relaunch)
    }

    /// Restores the complete pristine, version-matched backup only after the
    /// caller has obtained explicit user confirmation.
    @discardableResult
    func restore(relaunch: Bool = true) async -> PatchOperationResult {
        await perform(.restore, relaunch: relaunch)
    }

    /// Convenience entry point for AppKit/SwiftUI callbacks.
    func startPatch(relaunch: Bool = true) {
        guard !isBusy else { return }
        Task {
            _ = await patch(relaunch: relaunch)
        }
    }

    /// Convenience entry point for AppKit/SwiftUI callbacks.
    func startRestore(relaunch: Bool = true) {
        guard !isBusy else { return }
        Task {
            _ = await restore(relaunch: relaunch)
        }
    }

    private func perform(
        _ operation: PatchOperation,
        relaunch: Bool
    ) async -> PatchOperationResult {
        guard !isBusy else {
            let result = PatchOperationResult(
                operation: operation,
                succeeded: false,
                message: PatchManagerError.busy.localizedDescription,
                exitCode: 75,
                finishedAt: Date()
            )
            lastResult = result
            return result
        }

        isBusy = true
        beginProgress(PatchProgress(
            operation: operation,
            stage: "starting",
            message: operation == .patch
                ? "Preparing to patch ChatGPT…"
                : "Preparing to restore ChatGPT…",
            fraction: 0
        ))
        defer {
            progressTicker?.cancel()
            progressTicker = nil
            isBusy = false
            progress = nil
        }

        var arguments = [
            operation == .patch ? "--patch" : "--restore",
        ]
        if relaunch {
            arguments.append("--relaunch")
        }

        let result: PatchOperationResult
        do {
            let execution = try await runScript(arguments: arguments) {
                [weak self] event in
                guard let self else { return }
                if event.event == "progress" {
                    self.updateProgress(PatchProgress(
                        operation: operation,
                        stage: event.stage,
                        message: event.message,
                        fraction: event.progress.flatMap { $0 >= 0 ? $0 : nil }
                    ))
                }
            }

            let succeeded = execution.exitCode == 0
            let finalEvent = Self.lastResultEvent(in: execution.output)
            let fallback = succeeded
                ? "\(operation == .patch ? "Patch" : "Restore") completed."
                : execution.lastNonEventLine
                    ?? "\(operation == .patch ? "Patch" : "Restore") failed."
            result = PatchOperationResult(
                operation: operation,
                succeeded: succeeded,
                message: finalEvent?.message ?? fallback,
                exitCode: execution.exitCode,
                finishedAt: Date()
            )
        } catch {
            result = PatchOperationResult(
                operation: operation,
                succeeded: false,
                message: error.localizedDescription,
                exitCode: -1,
                finishedAt: Date()
            )
        }

        if result.succeeded {
            await finishProgress(message: result.message)
        }

        lastResult = result
        AppLogStore.shared.append(
            "\(operation.rawValue.capitalized) "
                + (result.succeeded ? "succeeded: " : "failed: ")
                + result.message
        )

        // Refresh inline instead of calling refresh(), which intentionally
        // ignores requests while an operation owns the manager.
        do {
            let execution = try await runScript(arguments: ["--status", "--json"])
            snapshot = try Self.decodeStatus(
                from: execution.output,
                fallbackAppURL: appURL
            )
        } catch {
            AppLogStore.shared.append(
                "Post-\(operation.rawValue) status failed: \(error.localizedDescription)"
            )
        }
        return result
    }

    private func beginProgress(_ value: PatchProgress) {
        progress = value
        progressTarget = PatchProgressTimeline.target(
            for: value.operation,
            stage: value.stage,
            reported: value.fraction
        )
        progressTicker?.cancel()
        progressTicker = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.tickProgress()
            }
    }

    private func updateProgress(_ value: PatchProgress) {
        let current = progress?.fraction ?? 0
        progressTarget = max(
            current,
            PatchProgressTimeline.target(
                for: value.operation,
                stage: value.stage,
                reported: value.fraction
            )
        )
        progress = PatchProgress(
            operation: value.operation,
            stage: value.stage,
            message: value.message,
            fraction: current
        )
    }

    private func tickProgress() {
        guard let value = progress, let current = value.fraction else { return }
        let next = PatchProgressTimeline.nextFraction(
            current: current,
            target: progressTarget
        )
        guard next != current else { return }
        progress = PatchProgress(
            operation: value.operation,
            stage: value.stage,
            message: value.message,
            fraction: next
        )
    }

    private func finishProgress(message: String) async {
        progressTicker?.cancel()
        progressTicker = nil
        guard let value = progress else { return }
        let start = value.fraction ?? 0
        let frames = 15
        for frame in 1...frames {
            try? await Task.sleep(for: .milliseconds(20))
            let fraction = start + (1 - start) * Double(frame) / Double(frames)
            progress = PatchProgress(
                operation: value.operation,
                stage: "complete",
                message: frame == frames ? message : value.message,
                fraction: fraction
            )
        }
        try? await Task.sleep(for: .milliseconds(180))
    }

    private func runScript(
        arguments: [String],
        onEvent: @escaping @MainActor (ScriptEvent) -> Void = { _ in }
    ) async throws -> ScriptExecution {
        guard FileManager.default.isExecutableFile(atPath: scriptURL.path)
                || FileManager.default.fileExists(atPath: scriptURL.path)
        else {
            throw PatchManagerError.missingScript
        }

        let command = ProcessCommand(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: [scriptURL.path] + arguments,
            environment: baseEnvironment
        )

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let execution = try Self.execute(command: command) { event in
                        Task { @MainActor in
                            onEvent(event)
                        }
                    }
                    continuation.resume(returning: execution)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    nonisolated private static func execute(
        command: ProcessCommand,
        onEvent: @escaping (ScriptEvent) -> Void
    ) throws -> ScriptExecution {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = command.executableURL
        process.arguments = command.arguments
        process.environment = command.environment
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            throw PatchManagerError.launchFailed(error.localizedDescription)
        }

        var accumulated = Data()
        var pending = Data()
        var lastNonEventLine: String?
        let handle = pipe.fileHandleForReading

        while let chunk = try handle.read(upToCount: 16 * 1024), !chunk.isEmpty {
            accumulated.append(chunk)
            pending.append(chunk)

            while let newline = pending.firstIndex(of: 0x0A) {
                let lineData = pending[..<newline]
                pending.removeSubrange(...newline)
                let line = String(decoding: lineData, as: UTF8.self)
                if let event = decodeEvent(from: line) {
                    onEvent(event)
                } else if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lastNonEventLine = line
                    AppLogStore.shared.append("Patch runtime: \(line)")
                }
            }
        }

        if !pending.isEmpty {
            let line = String(decoding: pending, as: UTF8.self)
            if let event = decodeEvent(from: line) {
                onEvent(event)
            } else if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lastNonEventLine = line
                AppLogStore.shared.append("Patch runtime: \(line)")
            }
        }

        process.waitUntilExit()
        return ScriptExecution(
            exitCode: process.terminationStatus,
            output: String(decoding: accumulated, as: UTF8.self),
            lastNonEventLine: lastNonEventLine
        )
    }

    nonisolated private static func decodeEvent(from line: String) -> ScriptEvent? {
        let prefix = "AGENT_MICRO_EVENT\t"
        guard line.hasPrefix(prefix),
              let data = String(line.dropFirst(prefix.count)).data(using: .utf8)
        else {
            return nil
        }
        return try? JSONDecoder().decode(ScriptEvent.self, from: data)
    }

    nonisolated private static func lastResultEvent(in output: String) -> ScriptEvent? {
        output
            .split(whereSeparator: \.isNewline)
            .reversed()
            .compactMap { decodeEvent(from: String($0)) }
            .first(where: { $0.event == "result" || $0.event == "error" })
    }

    nonisolated private static func decodeStatus(
        from output: String,
        fallbackAppURL: URL
    ) throws -> ChatGPTPatchSnapshot {
        let statusLine = output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .last(where: { $0.first == "{" && !$0.contains("\"event\"") })
        guard let statusLine,
              let data = statusLine.data(using: .utf8),
              let status = try? JSONDecoder().decode(StatusResponse.self, from: data)
        else {
            throw PatchManagerError.invalidStatus
        }

        return ChatGPTPatchSnapshot(
            installed: status.installed,
            running: status.running,
            appURL: URL(fileURLWithPath: status.path).standardizedFileURL,
            bundleIdentifier: status.bundleIdentifier,
            version: status.version,
            build: status.build,
            state: ChatGPTPatchState(rawValue: status.patchState) ?? .incompatible,
            patched: status.patched,
            compatible: status.compatible,
            backupAvailable: status.backupAvailable,
            backupKind: ChatGPTBackupKind(rawValue: status.backupKind) ?? .none,
            canPatch: status.canPatch,
            canRestore: status.canRestore,
            reason: status.reason
        )
    }

    nonisolated private static func resolveRuntimeURL(
        environment: [String: String]
    ) -> URL {
        if let configured = environment["AGENT_MICRO_PATCH_RUNTIME"],
           !configured.isEmpty
        {
            return URL(fileURLWithPath: configured).standardizedFileURL
        }
        if let resourceURL = Bundle.main.resourceURL {
            let bundled = resourceURL.appendingPathComponent(
                "PatchRuntime",
                isDirectory: true
            )
            if FileManager.default.fileExists(atPath: bundled.path) {
                return bundled
            }
        }

        // #filePath keeps command-line development self-contained without
        // placing repository paths into distributed builds.
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("PatchRuntime", isDirectory: true)
            .standardizedFileURL
    }

    nonisolated private static func resolveScriptURL(runtimeURL: URL) -> URL {
        let bundled = runtimeURL.appendingPathComponent("patch-chatgpt.sh")
        if FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("tools/patch-chatgpt.sh")
            .standardizedFileURL
    }

    nonisolated private static var isRunningFromApplicationBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    nonisolated private static func setPathIfPresent(
        key: String,
        candidates: [URL],
        in environment: inout [String: String]
    ) {
        guard environment[key] == nil,
              let value = candidates.first(where: {
                  FileManager.default.fileExists(atPath: $0.path)
              })
        else {
            return
        }
        environment[key] = value.path
    }
}

private struct ProcessCommand: Sendable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
}

private struct ScriptExecution: Sendable {
    let exitCode: Int32
    let output: String
    let lastNonEventLine: String?
}

private struct ScriptEvent: Codable, Sendable {
    let event: String
    let stage: String
    let message: String
    let progress: Double?
}

private struct StatusResponse: Decodable {
    let installed: Bool
    let running: Bool
    let path: String
    let bundleIdentifier: String
    let version: String
    let build: String
    let patchState: String
    let patched: Bool
    let compatible: Bool
    let backupAvailable: Bool
    let backupKind: String
    let canPatch: Bool
    let canRestore: Bool
    let reason: String
}
