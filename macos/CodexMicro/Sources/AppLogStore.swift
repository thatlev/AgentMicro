import Foundation

final class AppLogStore {
    static let shared = AppLogStore()

    let directoryURL: URL
    let logURL: URL

    private let queue = DispatchQueue(label: "io.github.thislev.codexmicro.logs")
    private let maximumBytes: UInt64 = 10 * 1024 * 1024
    private var lastMessage: String?
    private var repeatedCount = 0

    private init() {
        directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/CodexMicro", isDirectory: true)
        logURL = directoryURL.appendingPathComponent("codexmicro.log")
        try? FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    func installBridgeSink() {
        bridgeLogObserver = { [weak self] message in
            self?.append(message)
        }
    }

    func append(_ message: String) {
        queue.async { [weak self] in
            self?.appendOnQueue(message)
        }
    }

    func flush() {
        queue.sync {
            flushRepeatedOnQueue()
        }
    }

    func recentText(maximumBytes: Int = 64 * 1024) -> String {
        flush()
        guard let handle = try? FileHandle(forReadingFrom: logURL) else {
            return "No AgentMicro log has been written yet."
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maximumBytes) ? size - UInt64(maximumBytes) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private func appendOnQueue(_ message: String) {
        if message == lastMessage {
            repeatedCount += 1
            return
        }
        flushRepeatedOnQueue()
        lastMessage = message
        writeLine(message)
    }

    private func flushRepeatedOnQueue() {
        guard repeatedCount > 0 else { return }
        writeLine("Previous message repeated \(repeatedCount) time\(repeatedCount == 1 ? "" : "s")")
        repeatedCount = 0
    }

    private func writeLine(_ message: String) {
        rotateIfNeeded()
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: data)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Logging must never interrupt the bridge.
        }
    }

    private func rotateIfNeeded() {
        let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        guard size >= maximumBytes else { return }

        let previous = directoryURL.appendingPathComponent("codexmicro.previous.log")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: logURL, to: previous)
    }
}
