import Foundation
import Darwin

struct LegacyMigrationResult {
    var disabledLaunchAgents: [String] = []
    var notes: [String] = []
    var requiresAttention = false
}

enum LegacyMigrationManager {
    /// Disables the old invisible KeepAlive helper by identifying its executable
    /// path rather than carrying its former product branding into this app.
    static func disableInvisibleHelperIfNeeded() -> LegacyMigrationResult {
        guard ProcessInfo.processInfo.environment["CODEX_MICRO_SKIP_LEGACY_MIGRATION"] != "1"
        else {
            return LegacyMigrationResult(notes: ["Legacy helper migration skipped by environment."])
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let launchAgents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let retained = home
            .appendingPathComponent("Library/Application Support/AgentMicro", isDirectory: true)
            .appendingPathComponent("Legacy", isDirectory: true)
        let executableMarker =
            "/Library/Application Support/AgentMicro/CodexBridge.app/Contents/MacOS/codexbridge"

        guard let candidates = try? FileManager.default.contentsOfDirectory(
            at: launchAgents,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return LegacyMigrationResult()
        }

        var result = LegacyMigrationResult()
        for plistURL in candidates where plistURL.pathExtension == "plist" {
            guard let data = try? Data(contentsOf: plistURL),
                  let object = try? PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: nil
                  ) as? [String: Any],
                  let arguments = object["ProgramArguments"] as? [String],
                  arguments.contains(where: { $0.contains(executableMarker) })
            else {
                continue
            }

            let domain = "gui/\(getuid())"
            guard let label = object["Label"] as? String, !label.isEmpty else {
                result.requiresAttention = true
                result.notes.append(
                    "A previous helper launch item had no verifiable label and was left unchanged."
                )
                continue
            }
            let loadedState = launchctl(["print", "\(domain)/\(label)"])
            if loadedState.status == 0 {
                let bootout = launchctl(["bootout", domain, plistURL.path])
                guard bootout.status == 0 else {
                    result.requiresAttention = true
                    result.notes.append(
                        "The previous helper is still loaded and was not migrated: "
                            + bootout.output
                    )
                    continue
                }
                guard launchctl(["print", "\(domain)/\(label)"]).status == 113 else {
                    result.requiresAttention = true
                    result.notes.append(
                        "The previous helper remained loaded after macOS accepted the stop request."
                    )
                    continue
                }
            } else if loadedState.status != 113 {
                result.requiresAttention = true
                result.notes.append(
                    "The previous helper state could not be verified and its launch item was left unchanged: "
                        + loadedState.output
                )
                continue
            }

            do {
                try FileManager.default.createDirectory(
                    at: retained,
                    withIntermediateDirectories: true
                )
                let destination = uniqueDestination(
                    retained.appendingPathComponent(plistURL.lastPathComponent + ".disabled")
                )
                try FileManager.default.moveItem(at: plistURL, to: destination)
                result.disabledLaunchAgents.append(plistURL.lastPathComponent)
                AppLogStore.shared.append(
                    "Disabled previous invisible helper; retained its launch file at \(destination.path)"
                )
            } catch {
                result.requiresAttention = true
                result.notes.append(
                    "The previous helper was stopped but its launch file could not be retained: "
                        + error.localizedDescription
                )
            }
        }
        return result
    }

    private static func launchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let text = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (process.terminationStatus, text)
        } catch {
            return (-1, error.localizedDescription)
        }
    }

    private static func uniqueDestination(_ proposed: URL) -> URL {
        guard FileManager.default.fileExists(atPath: proposed.path) else { return proposed }
        let stem = proposed.deletingPathExtension().lastPathComponent
        let ext = proposed.pathExtension
        let timestamp = Int(Date().timeIntervalSince1970)
        return proposed.deletingLastPathComponent()
            .appendingPathComponent("\(stem)-\(timestamp)")
            .appendingPathExtension(ext)
    }
}
