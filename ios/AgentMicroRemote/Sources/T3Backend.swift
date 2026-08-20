// T3Backend.swift
//
// Standalone bridge support for the official T3 Code environment HTTP API.
// This file deliberately has no dependency on AgentMicroBridge's main.swift so
// it can be compiled and tested in isolation, then wired into the helper with:
//
//   swiftc -O main.swift T3Backend.swift -o codexbridge
//
// T3 is not patched. The backend discovers T3's atomically-written
// `server-runtime.json`, pairs through the documented OAuth token exchange,
// stores the resulting bearer in the macOS Keychain, polls the authoritative
// orchestration shell, and sends turns through `/api/orchestration/dispatch`.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Public wire-independent model

public enum T3ConnectionPhase: String, Codable, Sendable {
    case stopped
    case discovering
    case connecting
    case needsPairing
    case connected
    case reconnecting
}

public enum T3AgentStatus: String, Codable, Sendable {
    case idle
    case working
    case done
    case needsApproval
    case error
    case unavailable
}

public enum T3IssueCode: String, Codable, Sendable {
    case runtimeUnavailable
    case invalidRuntime
    case transport
    case invalidResponse
    case needsPairing
    case insufficientScope
    case credentialExpired
    case threadMissing
    case noSelectedThread
    case pinSlotsFull
    case invalidTarget
    case persistence
    case server
}

public struct T3BackendIssue: Error, Codable, Equatable, Sendable, CustomStringConvertible {
    public let code: T3IssueCode
    public let message: String
    public let isRecoverable: Bool
    public let traceID: String?

    public init(
        code: T3IssueCode,
        message: String,
        isRecoverable: Bool = true,
        traceID: String? = nil
    ) {
        self.code = code
        self.message = message
        self.isRecoverable = isRecoverable
        self.traceID = traceID
    }

    public var description: String { message }
}

public struct T3Environment: Codable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let serverVersion: String

    public init(id: String, label: String, serverVersion: String) {
        self.id = id
        self.label = label
        self.serverVersion = serverVersion
    }
}

/// Stable identity used everywhere outside T3's wire format. Thread IDs are
/// environment-scoped, which prevents equal-looking threads in two projects or
/// two T3 servers from stealing one another's key.
public struct T3TargetID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let environmentID: String
    public let threadID: String

    public init(environmentID: String, threadID: String) throws {
        let environmentID = environmentID.trimmingCharacters(in: .whitespacesAndNewlines)
        let threadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !environmentID.isEmpty, !threadID.isEmpty,
              !environmentID.contains(":"), !threadID.contains(":") else {
            throw T3BackendIssue(
                code: .invalidTarget,
                message: "T3 target IDs require non-empty environment and thread IDs without colons.",
                isRecoverable: false
            )
        }
        self.environmentID = environmentID
        self.threadID = threadID
    }

    public init?(rawValue: String) {
        guard rawValue.hasPrefix("t3:") else { return nil }
        let remainder = rawValue.dropFirst(3)
        guard let separator = remainder.firstIndex(of: ":") else { return nil }
        let environmentID = String(remainder[..<separator])
        let threadID = String(remainder[remainder.index(after: separator)...])
        guard let parsed = try? T3TargetID(environmentID: environmentID, threadID: threadID) else {
            return nil
        }
        self = parsed
    }

    public var rawValue: String { "t3:\(environmentID):\(threadID)" }
    public var description: String { rawValue }
}

public struct T3Target: Codable, Equatable, Sendable {
    public let id: String
    public let environmentID: String
    public let threadID: String
    public let projectID: String
    public let projectTitle: String
    public let workspaceRoot: String
    public let title: String
    public let status: T3AgentStatus
    public let updatedAt: String
    public let detail: String?

    public init(
        id: String,
        environmentID: String,
        threadID: String,
        projectID: String,
        projectTitle: String,
        workspaceRoot: String,
        title: String,
        status: T3AgentStatus,
        updatedAt: String,
        detail: String? = nil
    ) {
        self.id = id
        self.environmentID = environmentID
        self.threadID = threadID
        self.projectID = projectID
        self.projectTitle = projectTitle
        self.workspaceRoot = workspaceRoot
        self.title = title
        self.status = status
        self.updatedAt = updatedAt
        self.detail = detail
    }
}

public struct T3PinLayout: Codable, Equatable, Sendable {
    public static let slotCount = 6

    public private(set) var slots: [String?]
    public private(set) var selectedTargetID: String?

    public init(slots: [String?] = [], selectedTargetID: String? = nil) {
        var normalized = Array(slots.prefix(Self.slotCount))
        normalized.append(contentsOf: repeatElement(nil, count: max(0, Self.slotCount - normalized.count)))

        // Old/corrupt state must never make one thread occupy two keys.
        var seen = Set<String>()
        for index in normalized.indices {
            guard let value = normalized[index], T3TargetID(rawValue: value) != nil,
                  seen.insert(value).inserted else {
                normalized[index] = nil
                continue
            }
        }

        self.slots = normalized
        self.selectedTargetID = selectedTargetID.flatMap { T3TargetID(rawValue: $0) == nil ? nil : $0 }
    }

    public mutating func select(_ targetID: String?) throws {
        if let targetID, T3TargetID(rawValue: targetID) == nil {
            throw T3BackendIssue(code: .invalidTarget, message: "Invalid T3 target: \(targetID)")
        }
        selectedTargetID = targetID
    }

    /// Toggles exactly one target. A pin never infers a neighboring tab and a
    /// repeated tap can only remove the same target, never add a second copy.
    @discardableResult
    public mutating func toggle(
        targetID: String,
        preferredSlot: Int? = nil
    ) throws -> Int? {
        guard T3TargetID(rawValue: targetID) != nil else {
            throw T3BackendIssue(code: .invalidTarget, message: "Invalid T3 target: \(targetID)")
        }

        if let existing = slots.firstIndex(where: { $0 == targetID }) {
            slots[existing] = nil
            return existing
        }

        let destination: Int?
        if let preferredSlot {
            guard slots.indices.contains(preferredSlot) else {
                throw T3BackendIssue(
                    code: .invalidTarget,
                    message: "T3 pin slot \(preferredSlot) is outside 0...\(Self.slotCount - 1)."
                )
            }
            destination = slots[preferredSlot] == nil ? preferredSlot : nil
        } else {
            destination = slots.firstIndex(where: { $0 == nil })
        }

        guard let destination else {
            throw T3BackendIssue(
                code: .pinSlotsFull,
                message: preferredSlot == nil
                    ? "All six T3 agent keys are assigned. Unpin one first."
                    : "That T3 agent key is already assigned."
            )
        }

        slots[destination] = targetID
        selectedTargetID = targetID
        return destination
    }
}

public struct T3BackendSnapshot: Codable, Equatable, Sendable {
    public let phase: T3ConnectionPhase
    public let environment: T3Environment?
    public let runtimeOrigin: String?
    public let snapshotSequence: Int?
    public let targets: [T3Target]
    public let pins: T3PinLayout
    public let issue: T3BackendIssue?

    public init(
        phase: T3ConnectionPhase,
        environment: T3Environment? = nil,
        runtimeOrigin: String? = nil,
        snapshotSequence: Int? = nil,
        targets: [T3Target] = [],
        pins: T3PinLayout = T3PinLayout(),
        issue: T3BackendIssue? = nil
    ) {
        self.phase = phase
        self.environment = environment
        self.runtimeOrigin = runtimeOrigin
        self.snapshotSequence = snapshotSequence
        self.targets = targets
        self.pins = pins
        self.issue = issue
    }
}

public struct T3PromptReceipt: Codable, Equatable, Sendable {
    public let targetID: String
    public let commandID: String
    public let messageID: String
    public let sequence: Int

    public init(targetID: String, commandID: String, messageID: String, sequence: Int) {
        self.targetID = targetID
        self.commandID = commandID
        self.messageID = messageID
        self.sequence = sequence
    }
}

// MARK: - Credential persistence

public struct T3BearerCredential: Codable, Equatable, Sendable {
    public let accessToken: String
    public let expiresAt: Date?
    public let scopes: [String]

    public init(accessToken: String, expiresAt: Date? = nil, scopes: [String] = []) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.scopes = scopes
    }

    public func isExpired(at date: Date = Date(), leeway: TimeInterval = 30) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(date) <= leeway
    }
}

public protocol T3CredentialStoring: AnyObject {
    func load(environmentID: String) throws -> T3BearerCredential?
    func save(_ credential: T3BearerCredential, environmentID: String) throws
    func remove(environmentID: String) throws
}

public final class T3MemoryCredentialStore: T3CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: T3BearerCredential] = [:]

    public init() {}

    public func load(environmentID: String) throws -> T3BearerCredential? {
        lock.lock(); defer { lock.unlock() }
        return values[environmentID]
    }

    public func save(_ credential: T3BearerCredential, environmentID: String) throws {
        lock.lock(); defer { lock.unlock() }
        values[environmentID] = credential
    }

    public func remove(environmentID: String) throws {
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: environmentID)
    }
}

#if canImport(Security)
public final class T3KeychainCredentialStore: T3CredentialStoring, @unchecked Sendable {
    public let service: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(service: String = "com.agentmicro.bridge.t3.bearer") {
        self.service = service
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func load(environmentID: String) throws -> T3BearerCredential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: environmentID,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else {
            throw keychainIssue(operation: "read", status: status)
        }
        do {
            return try decoder.decode(T3BearerCredential.self, from: data)
        } catch {
            throw T3BackendIssue(
                code: .persistence,
                message: "The saved T3 credential is unreadable; pair this helper again.",
                isRecoverable: true
            )
        }
    }

    public func save(_ credential: T3BearerCredential, environmentID: String) throws {
        let data = try encoder.encode(credential)
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: environmentID,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: "AgentMicro T3 Code access",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let updateStatus = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw keychainIssue(operation: "update", status: updateStatus)
        }

        var item = identity
        attributes.forEach { item[$0.key] = $0.value }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw keychainIssue(operation: "save", status: addStatus)
        }
    }

    public func remove(environmentID: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: environmentID,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainIssue(operation: "delete", status: status)
        }
    }

    private func keychainIssue(operation: String, status: OSStatus) -> T3BackendIssue {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return T3BackendIssue(
            code: .persistence,
            message: "Could not \(operation) the T3 credential in Keychain: \(detail)",
            isRecoverable: true
        )
    }
}
#endif

public protocol T3PinStoring: AnyObject {
    func load() throws -> T3PinLayout
    func save(_ layout: T3PinLayout) throws
}

public final class T3MemoryPinStore: T3PinStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var layout: T3PinLayout

    public init(layout: T3PinLayout = T3PinLayout()) { self.layout = layout }

    public func load() throws -> T3PinLayout {
        lock.lock(); defer { lock.unlock() }
        return layout
    }

    public func save(_ layout: T3PinLayout) throws {
        lock.lock(); defer { lock.unlock() }
        self.layout = layout
    }
}

public final class T3FilePinStore: T3PinStoring, @unchecked Sendable {
    private struct Document: Codable {
        let version: Int
        let layout: T3PinLayout
    }

    public let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            self.fileURL = support
                .appendingPathComponent("AgentMicro", isDirectory: true)
                .appendingPathComponent("t3-pins.json", isDirectory: false)
        }
    }

    public func load() throws -> T3PinLayout {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return T3PinLayout() }
        do {
            let data = try Data(contentsOf: fileURL)
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.version == 1 else {
                throw T3BackendIssue(
                    code: .persistence,
                    message: "Unsupported T3 pin file version \(document.version)."
                )
            }
            // Re-initialize to normalize length, invalid IDs, and duplicates.
            return T3PinLayout(
                slots: document.layout.slots,
                selectedTargetID: document.layout.selectedTargetID
            )
        } catch let issue as T3BackendIssue {
            throw issue
        } catch {
            throw T3BackendIssue(
                code: .persistence,
                message: "Could not read T3 pins at \(fileURL.path): \(error.localizedDescription)"
            )
        }
    }

    public func save(_ layout: T3PinLayout) throws {
        lock.lock(); defer { lock.unlock() }
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(Document(version: 1, layout: layout))
            try data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            throw T3BackendIssue(
                code: .persistence,
                message: "Could not persist T3 pins at \(fileURL.path): \(error.localizedDescription)"
            )
        }
    }
}

// MARK: - Dynamic local runtime discovery

public struct T3PersistedRuntimeState: Codable, Equatable, Sendable {
    public let version: Int
    public let pid: Int32
    public let host: String?
    public let port: Int
    public let origin: String
    public let startedAt: String

    public init(version: Int, pid: Int32, host: String?, port: Int, origin: String, startedAt: String) {
        self.version = version
        self.pid = pid
        self.host = host
        self.port = port
        self.origin = origin
        self.startedAt = startedAt
    }
}

public struct T3RuntimeLocation: Equatable, Sendable {
    public let fileURL: URL
    public let state: T3PersistedRuntimeState

    public init(fileURL: URL, state: T3PersistedRuntimeState) {
        self.fileURL = fileURL
        self.state = state
    }

    public var fingerprint: String {
        "\(fileURL.standardizedFileURL.path)|\(state.pid)|\(state.startedAt)|\(state.origin)"
    }
}

public protocol T3RuntimeDiscovering: AnyObject {
    func discover() throws -> T3RuntimeLocation?
}

public final class T3FileRuntimeDiscovery: T3RuntimeDiscovering, @unchecked Sendable {
    public struct Configuration: Sendable {
        public var explicitRuntimeFiles: [URL]
        public var homeDirectory: URL
        public var environment: [String: String]
        public var requireLoopbackOrigin: Bool
        public var verifyProcessIsAlive: Bool

        public init(
            explicitRuntimeFiles: [URL] = [],
            homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()),
            environment: [String: String] = ProcessInfo.processInfo.environment,
            requireLoopbackOrigin: Bool = true,
            verifyProcessIsAlive: Bool = true
        ) {
            self.explicitRuntimeFiles = explicitRuntimeFiles
            self.homeDirectory = homeDirectory
            self.environment = environment
            self.requireLoopbackOrigin = requireLoopbackOrigin
            self.verifyProcessIsAlive = verifyProcessIsAlive
        }
    }

    private struct Candidate {
        let location: T3RuntimeLocation
        let modificationDate: Date
    }

    public let configuration: Configuration
    private let fileManager: FileManager

    public init(configuration: Configuration = Configuration(), fileManager: FileManager = .default) {
        self.configuration = configuration
        self.fileManager = fileManager
    }

    public func discover() throws -> T3RuntimeLocation? {
        var valid: [Candidate] = []
        var lastIssue: T3BackendIssue?

        for fileURL in candidateURLs() {
            guard fileManager.fileExists(atPath: fileURL.path) else { continue }
            do {
                valid.append(try readCandidate(fileURL))
            } catch let issue as T3BackendIssue {
                lastIssue = issue
            } catch {
                lastIssue = T3BackendIssue(
                    code: .invalidRuntime,
                    message: "Could not inspect T3 runtime state at \(fileURL.path): \(error.localizedDescription)"
                )
            }
        }

        if let newest = valid.max(by: { lhs, rhs in
            if lhs.modificationDate == rhs.modificationDate {
                return lhs.location.state.startedAt < rhs.location.state.startedAt
            }
            return lhs.modificationDate < rhs.modificationDate
        }) {
            return newest.location
        }
        if let lastIssue { throw lastIssue }
        return nil
    }

    private func candidateURLs() -> [URL] {
        var bases: [URL] = []
        if let configured = configuration.environment["T3CODE_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            bases.append(URL(fileURLWithPath: NSString(string: configured).expandingTildeInPath, isDirectory: true))
        }
        bases.append(configuration.homeDirectory.appendingPathComponent(".t3", isDirectory: true))

        var result = configuration.explicitRuntimeFiles
        for base in bases {
            result.append(base.appendingPathComponent("userdata/server-runtime.json"))
            result.append(base.appendingPathComponent("dev/server-runtime.json"))
            // Explicit T3CODE_HOME always uses userdata today, but accepting a
            // root-level descriptor makes custom server launchers future-safe.
            result.append(base.appendingPathComponent("server-runtime.json"))
        }

        var seen = Set<String>()
        return result.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private func readCandidate(_ fileURL: URL) throws -> Candidate {
        let resource = try fileURL.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey,
        ])
        guard resource.isRegularFile == true, resource.isSymbolicLink != true else {
            throw T3BackendIssue(
                code: .invalidRuntime,
                message: "Ignoring unsafe T3 runtime state at \(fileURL.path)."
            )
        }

        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        if let owner = attributes[.ownerAccountID] as? NSNumber,
           owner.uint32Value != currentUserID() {
            throw T3BackendIssue(
                code: .invalidRuntime,
                message: "T3 runtime state is not owned by the current user: \(fileURL.path)."
            )
        }
        if let permissions = attributes[.posixPermissions] as? NSNumber,
           (permissions.intValue & 0o022) != 0 {
            throw T3BackendIssue(
                code: .invalidRuntime,
                message: "T3 runtime state is writable by another user: \(fileURL.path)."
            )
        }

        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let state: T3PersistedRuntimeState
        do {
            state = try JSONDecoder().decode(T3PersistedRuntimeState.self, from: data)
        } catch {
            throw T3BackendIssue(
                code: .invalidRuntime,
                message: "T3 runtime state is malformed at \(fileURL.path)."
            )
        }
        try validate(state, fileURL: fileURL)

        return Candidate(
            location: T3RuntimeLocation(fileURL: fileURL, state: state),
            modificationDate: resource.contentModificationDate ?? .distantPast
        )
    }

    private func validate(_ state: T3PersistedRuntimeState, fileURL: URL) throws {
        guard state.version == 1, state.pid > 1, (1...65_535).contains(state.port),
              ISO8601DateFormatter().date(from: state.startedAt) != nil,
              let url = URL(string: state.origin),
              url.scheme?.lowercased() == "http",
              url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.port == state.port else {
            throw T3BackendIssue(
                code: .invalidRuntime,
                message: "T3 runtime state failed validation at \(fileURL.path)."
            )
        }

        if configuration.requireLoopbackOrigin {
            let host = url.host?.lowercased() ?? ""
            guard host == "localhost" || host == "127.0.0.1" || host == "::1" else {
                throw T3BackendIssue(
                    code: .invalidRuntime,
                    message: "Refusing to send a local T3 bearer to non-loopback origin \(state.origin)."
                )
            }
        }

        if configuration.verifyProcessIsAlive, !processIsAlive(state.pid) {
            throw T3BackendIssue(
                code: .runtimeUnavailable,
                message: "T3's runtime file is stale because process \(state.pid) is no longer running."
            )
        }
    }

    private func processIsAlive(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private func currentUserID() -> UInt32 { UInt32(getuid()) }
}

// MARK: - JSON and official T3 HTTP wire shapes

public enum T3JSONValue: Codable, Equatable, Sendable {
    case object([String: T3JSONValue])
    case array([T3JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode([T3JSONValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: T3JSONValue].self) { self = .object(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid JSON value") }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

private struct T3WireEnvironmentDescriptor: Decodable {
    let environmentId: String
    let label: String
    let serverVersion: String
}

private struct T3WireProject: Decodable {
    let id: String
    let title: String
    let workspaceRoot: String
}

private struct T3WireLatestTurn: Decodable {
    let turnId: String
    let state: String
    let requestedAt: String
    let startedAt: String?
    let completedAt: String?
}

private struct T3WireSession: Decodable {
    let status: String
    let lastError: String?
}

private struct T3WireThreadShell: Decodable {
    let id: String
    let projectId: String
    let title: String
    let runtimeMode: String
    let interactionMode: String
    let latestTurn: T3WireLatestTurn?
    let updatedAt: String
    let session: T3WireSession?
    let latestUserMessageAt: String?
    let hasPendingApprovals: Bool
    let hasPendingUserInput: Bool
    let hasActionableProposedPlan: Bool

    private enum CodingKeys: String, CodingKey {
        case id, projectId, title, runtimeMode, interactionMode, latestTurn, updatedAt
        case session, latestUserMessageAt, hasPendingApprovals, hasPendingUserInput
        case hasActionableProposedPlan
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        projectId = try values.decode(String.self, forKey: .projectId)
        title = try values.decode(String.self, forKey: .title)
        runtimeMode = try values.decodeIfPresent(String.self, forKey: .runtimeMode) ?? "full-access"
        interactionMode = try values.decodeIfPresent(String.self, forKey: .interactionMode) ?? "default"
        latestTurn = try values.decodeIfPresent(T3WireLatestTurn.self, forKey: .latestTurn)
        updatedAt = try values.decode(String.self, forKey: .updatedAt)
        session = try values.decodeIfPresent(T3WireSession.self, forKey: .session)
        latestUserMessageAt = try values.decodeIfPresent(String.self, forKey: .latestUserMessageAt)
        hasPendingApprovals = try values.decodeIfPresent(Bool.self, forKey: .hasPendingApprovals) ?? false
        hasPendingUserInput = try values.decodeIfPresent(Bool.self, forKey: .hasPendingUserInput) ?? false
        hasActionableProposedPlan = try values.decodeIfPresent(Bool.self, forKey: .hasActionableProposedPlan) ?? false
    }
}

private struct T3WireShellSnapshot: Decodable {
    let snapshotSequence: Int
    let projects: [T3WireProject]
    let threads: [T3WireThreadShell]
    let updatedAt: String
}

private struct T3WireThreadDetail: Decodable {
    let id: String
    let title: String
    let modelSelection: T3JSONValue
    let runtimeMode: String
    let interactionMode: String
}

private struct T3WireThreadDetailSnapshot: Decodable {
    let snapshotSequence: Int
    let thread: T3WireThreadDetail
}

private struct T3WireDispatchResult: Decodable {
    let sequence: Int
}

private struct T3WireTokenResult: Decodable {
    let access_token: String
    let token_type: String
    let expires_in: Double
    let scope: String
}

private struct T3WireServerError: Decodable {
    let code: String?
    let reason: String?
    let requiredScope: String?
    let traceId: String?
}

// MARK: - Injectable HTTP transport

public struct T3HTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public protocol T3HTTPTask: AnyObject {
    func cancel()
}

public protocol T3HTTPTransport: AnyObject {
    @discardableResult
    func perform(
        _ request: URLRequest,
        completion: @escaping @Sendable (Result<T3HTTPResponse, Error>) -> Void
    ) -> T3HTTPTask
}

extension URLSessionDataTask: T3HTTPTask {}

private final class T3RejectRedirectsDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // The official environment API never redirects. Refusing redirects
        // guarantees an Authorization header cannot escape the discovered
        // origin through a compromised/stale local endpoint.
        completionHandler(nil)
    }
}

public final class T3URLSessionTransport: T3HTTPTransport, @unchecked Sendable {
    private let session: URLSession
    private let redirectDelegate: T3RejectRedirectsDelegate?

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
            self.redirectDelegate = nil
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = false
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            let delegate = T3RejectRedirectsDelegate()
            self.redirectDelegate = delegate
            self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        }
    }

    @discardableResult
    public func perform(
        _ request: URLRequest,
        completion: @escaping @Sendable (Result<T3HTTPResponse, Error>) -> Void
    ) -> T3HTTPTask {
        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let response = response as? HTTPURLResponse else {
                completion(.failure(T3BackendIssue(
                    code: .invalidResponse,
                    message: "T3 returned a non-HTTP response."
                )))
                return
            }
            var headers: [String: String] = [:]
            for (key, value) in response.allHeaderFields {
                headers[String(describing: key).lowercased()] = String(describing: value)
            }
            completion(.success(T3HTTPResponse(
                statusCode: response.statusCode,
                headers: headers,
                body: data ?? Data()
            )))
        }
        task.resume()
        return task
    }
}

// MARK: - Pure policy helpers (also used by self-tests)

public struct T3StatusFacts: Equatable, Sendable {
    public var sessionStatus: String?
    public var sessionError: String?
    public var latestTurnState: String?
    public var latestTurnRequestedAt: String?
    public var latestTurnStartedAt: String?
    public var latestTurnCompletedAt: String?
    public var latestUserMessageAt: String?
    public var hasPendingApprovals: Bool
    public var hasPendingUserInput: Bool
    public var hasActionableProposedPlan: Bool

    public init(
        sessionStatus: String? = nil,
        sessionError: String? = nil,
        latestTurnState: String? = nil,
        latestTurnRequestedAt: String? = nil,
        latestTurnStartedAt: String? = nil,
        latestTurnCompletedAt: String? = nil,
        latestUserMessageAt: String? = nil,
        hasPendingApprovals: Bool = false,
        hasPendingUserInput: Bool = false,
        hasActionableProposedPlan: Bool = false
    ) {
        self.sessionStatus = sessionStatus
        self.sessionError = sessionError
        self.latestTurnState = latestTurnState
        self.latestTurnRequestedAt = latestTurnRequestedAt
        self.latestTurnStartedAt = latestTurnStartedAt
        self.latestTurnCompletedAt = latestTurnCompletedAt
        self.latestUserMessageAt = latestUserMessageAt
        self.hasPendingApprovals = hasPendingApprovals
        self.hasPendingUserInput = hasPendingUserInput
        self.hasActionableProposedPlan = hasActionableProposedPlan
    }
}

public enum T3StatusMapper {
    /// Mirrors T3's own shell-settled ordering: actionable requests win over
    /// running/error states, a just-dispatched message is working during the
    /// session adoption window, and only an actually completed turn is done.
    public static func status(
        for facts: T3StatusFacts,
        now: Date = Date(),
        queuedTurnGrace: TimeInterval = 120
    ) -> (status: T3AgentStatus, detail: String?) {
        if facts.hasPendingApprovals || facts.hasPendingUserInput || facts.hasActionableProposedPlan {
            return (.needsApproval, facts.hasPendingUserInput ? "Waiting for input" : "Needs approval")
        }
        if facts.sessionStatus == "error" || facts.latestTurnState == "error" {
            return (.error, facts.sessionError ?? "T3 turn failed")
        }
        if facts.sessionStatus == "starting" || facts.sessionStatus == "running"
            || facts.latestTurnState == "running" || hasQueuedTurn(facts, now: now, grace: queuedTurnGrace) {
            return (.working, nil)
        }
        if facts.latestTurnState == "completed" { return (.done, nil) }
        return (.idle, nil)
    }

    private static func hasQueuedTurn(_ facts: T3StatusFacts, now: Date, grace: TimeInterval) -> Bool {
        guard let message = facts.latestUserMessageAt.flatMap(T3Date.parse) else { return false }
        guard abs(now.timeIntervalSince(message)) <= grace else { return false }
        let turnDates = [
            facts.latestTurnRequestedAt,
            facts.latestTurnStartedAt,
            facts.latestTurnCompletedAt,
        ].compactMap { $0.flatMap(T3Date.parse) }
        return turnDates.allSatisfy { $0 < message }
    }
}

public struct T3SequenceGate: Equatable, Sendable {
    public private(set) var runtimeFingerprint: String?
    public private(set) var lastAcceptedSequence: Int?

    public init(runtimeFingerprint: String? = nil, lastAcceptedSequence: Int? = nil) {
        self.runtimeFingerprint = runtimeFingerprint
        self.lastAcceptedSequence = lastAcceptedSequence
    }

    /// Returns true once for a new sequence. A new server process resets the
    /// gate; duplicates and out-of-order HTTP completions are ignored.
    public mutating func accept(sequence: Int, runtimeFingerprint: String) -> Bool {
        guard sequence >= 0 else { return false }
        if self.runtimeFingerprint != runtimeFingerprint {
            self.runtimeFingerprint = runtimeFingerprint
            lastAcceptedSequence = sequence
            return true
        }
        guard lastAcceptedSequence.map({ sequence > $0 }) ?? true else { return false }
        lastAcceptedSequence = sequence
        return true
    }

    public mutating func reset() {
        runtimeFingerprint = nil
        lastAcceptedSequence = nil
    }
}

public struct T3PairingTarget: Equatable, Sendable {
    public let origin: URL
    public let bootstrapCredential: String

    public init(origin: URL, bootstrapCredential: String) {
        self.origin = origin
        self.bootstrapCredential = bootstrapCredential
    }
}

public enum T3PairingURLParser {
    /// Matches T3's official direct and hosted pairing URL formats. Tokens are
    /// read from the fragment first so hosted links do not leak them to a web
    /// server, with query tokens accepted for backward compatibility.
    public static func parse(_ rawValue: String) throws -> T3PairingTarget {
        guard let pairingURL = URL(string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              isSupported(pairingURL.scheme) else {
            throw T3BackendIssue(code: .invalidTarget, message: "The T3 pairing URL is invalid.")
        }
        guard let token = token(from: pairingURL), !token.isEmpty else {
            throw T3BackendIssue(code: .needsPairing, message: "The T3 pairing URL has no token.")
        }

        let components = URLComponents(url: pairingURL, resolvingAgainstBaseURL: false)
        let hostedOrigin = components?.queryItems?.first(where: { $0.name == "host" })?.value
        let rawOrigin = hostedOrigin ?? pairingURL.absoluteString
        guard let origin = normalizedHTTPOrigin(rawOrigin) else {
            throw T3BackendIssue(code: .invalidTarget, message: "The T3 pairing URL has an invalid backend origin.")
        }
        return T3PairingTarget(origin: origin, bootstrapCredential: token)
    }

    private static func token(from url: URL) -> String? {
        if let fragment = url.fragment,
           let value = URLComponents(string: "?\(fragment)")?.queryItems?.first(where: { $0.name == "token" })?.value,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "token" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedHTTPOrigin(_ rawValue: String) -> URL? {
        var trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasPrefix("/") { trimmed.removeFirst() }
        if !trimmed.contains("://") { trimmed = "https://\(trimmed)" }
        guard var components = URLComponents(string: trimmed), isSupported(components.scheme),
              components.host != nil, components.user == nil, components.password == nil else { return nil }
        if components.scheme?.lowercased() == "ws" { components.scheme = "http" }
        if components.scheme?.lowercased() == "wss" { components.scheme = "https" }
        components.path = "/"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func isSupported(_ scheme: String?) -> Bool {
        guard let scheme = scheme?.lowercased() else { return false }
        return ["http", "https", "ws", "wss"].contains(scheme)
    }
}

private enum T3Date {
    static func parse(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    static func now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

private enum T3StableUUID {
    // Fixed namespace allocated only for AgentMicro's T3 command IDs.
    private static let namespace = UUID(uuidString: "a5e02d72-7cd7-4d66-bab6-f98319793212")!

    static func make(_ value: String) -> UUID {
        var namespaceBytes = withUnsafeBytes(of: namespace.uuid) { Array($0) }
        namespaceBytes.append(contentsOf: value.utf8)

        #if canImport(CryptoKit)
        var bytes = Array(SHA256.hash(data: Data(namespaceBytes)).prefix(16))
        #else
        // Stable fallback for toolchains without CryptoKit. This is an
        // idempotency identifier, not a secret or authentication primitive.
        var a: UInt64 = 0xcbf29ce484222325
        var b: UInt64 = 0x84222325cbf29ce4
        for byte in namespaceBytes {
            a = (a ^ UInt64(byte)) &* 0x100000001b3
            b = (b ^ UInt64(byte &+ 0x9d)) &* 0x100000001b3
        }
        var bytes = withUnsafeBytes(of: a.bigEndian) { Array($0) }
        bytes.append(contentsOf: withUnsafeBytes(of: b.bigEndian) { Array($0) })
        #endif

        // RFC 9562 UUIDv8: application-defined deterministic hash payload.
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let tuple: uuid_t = (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: tuple)
    }
}

// MARK: - Backend

public final class T3Backend: @unchecked Sendable {
    public struct Configuration {
        public var pollInterval: TimeInterval
        public var requestTimeout: TimeInterval
        public var reconnectMinimumDelay: TimeInterval
        public var reconnectMaximumDelay: TimeInterval
        public var maximumDispatchRetries: Int
        public var allowNonLoopbackPairingOrigins: Bool
        public var callbackQueue: DispatchQueue

        public init(
            pollInterval: TimeInterval = 1,
            requestTimeout: TimeInterval = 6,
            reconnectMinimumDelay: TimeInterval = 0.5,
            reconnectMaximumDelay: TimeInterval = 15,
            maximumDispatchRetries: Int = 2,
            allowNonLoopbackPairingOrigins: Bool = false,
            callbackQueue: DispatchQueue = .main
        ) {
            self.pollInterval = max(0.25, pollInterval)
            self.requestTimeout = max(1, requestTimeout)
            self.reconnectMinimumDelay = max(0.1, reconnectMinimumDelay)
            self.reconnectMaximumDelay = max(reconnectMinimumDelay, reconnectMaximumDelay)
            self.maximumDispatchRetries = max(0, maximumDispatchRetries)
            self.allowNonLoopbackPairingOrigins = allowNonLoopbackPairingOrigins
            self.callbackQueue = callbackQueue
        }
    }

    public typealias UpdateHandler = @Sendable (T3BackendSnapshot) -> Void

    private let configuration: Configuration
    private let runtimeDiscovery: T3RuntimeDiscovering
    private let credentials: T3CredentialStoring
    private let pinStore: T3PinStoring
    private let transport: T3HTTPTransport
    private let queue = DispatchQueue(label: "com.agentmicro.bridge.t3-backend")

    private var handler: UpdateHandler?
    private var running = false
    private var generation: UInt64 = 0
    private var scheduledPoll: DispatchWorkItem?
    private var pollTask: T3HTTPTask?
    private var runtime: T3RuntimeLocation?
    private var wireEnvironment: T3WireEnvironmentDescriptor?
    private var sequenceGate = T3SequenceGate()
    private var consecutiveFailures = 0
    private var pendingUntilSequence: [String: Int] = [:]
    private var pendingLocalTargets = Set<String>()
    private var preOptimisticTargets: [String: T3Target] = [:]
    private var snapshotState: T3BackendSnapshot

    public init(
        configuration: Configuration = Configuration(),
        runtimeDiscovery: T3RuntimeDiscovering = T3FileRuntimeDiscovery(),
        credentialStore: T3CredentialStoring? = nil,
        pinStore: T3PinStoring = T3FilePinStore(),
        transport: T3HTTPTransport = T3URLSessionTransport()
    ) {
        self.configuration = configuration
        self.runtimeDiscovery = runtimeDiscovery
        #if canImport(Security)
        self.credentials = credentialStore ?? T3KeychainCredentialStore()
        #else
        self.credentials = credentialStore ?? T3MemoryCredentialStore()
        #endif
        self.pinStore = pinStore
        self.transport = transport

        let pins: T3PinLayout
        let issue: T3BackendIssue?
        do {
            pins = try pinStore.load()
            issue = nil
        } catch let storedIssue as T3BackendIssue {
            pins = T3PinLayout()
            issue = storedIssue
        } catch {
            pins = T3PinLayout()
            issue = T3BackendIssue(code: .persistence, message: error.localizedDescription)
        }
        snapshotState = T3BackendSnapshot(phase: .stopped, pins: pins, issue: issue)
    }

    deinit {
        scheduledPoll?.cancel()
        pollTask?.cancel()
    }

    public func setUpdateHandler(_ handler: UpdateHandler?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.handler = handler
            self.emit(self.snapshotState)
        }
    }

    public func snapshot(_ completion: @escaping @Sendable (T3BackendSnapshot) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let value = self.snapshotState
            self.configuration.callbackQueue.async { completion(value) }
        }
    }

    public func start() {
        queue.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true
            self.generation &+= 1
            self.consecutiveFailures = 0
            self.replaceSnapshot(phase: .discovering, issue: .some(nil))
            self.poll(generation: self.generation)
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.running = false
            self.generation &+= 1
            self.scheduledPoll?.cancel()
            self.scheduledPoll = nil
            self.pollTask?.cancel()
            self.pollTask = nil
            self.replaceSnapshot(
                phase: .stopped,
                targets: self.unavailableTargets(),
                issue: .some(nil)
            )
        }
    }

    public func refreshNow() {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            self.scheduledPoll?.cancel()
            self.scheduledPoll = nil
            self.pollTask?.cancel()
            self.pollTask = nil
            self.generation &+= 1
            self.poll(generation: self.generation)
        }
    }

    /// Selection is explicit and persisted. It never guesses the frontmost,
    /// nearest, first, or most-recent T3 thread.
    public func select(
        targetID: String?,
        completion: (@Sendable (Result<T3PinLayout, T3BackendIssue>) -> Void)? = nil
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                if let targetID {
                    guard self.snapshotState.targets.contains(where: { $0.id == targetID })
                            || self.snapshotState.pins.slots.contains(where: { $0 == targetID }) else {
                        throw T3BackendIssue(code: .threadMissing, message: "That exact T3 thread is not available.")
                    }
                }
                var pins = self.snapshotState.pins
                try pins.select(targetID)
                try self.pinStore.save(pins)
                self.replaceSnapshot(pins: pins, issue: .some(nil))
                self.complete(completion, with: .success(pins))
            } catch let issue as T3BackendIssue {
                self.complete(completion, with: .failure(issue))
            } catch {
                self.complete(completion, with: .failure(T3BackendIssue(
                    code: .persistence,
                    message: error.localizedDescription
                )))
            }
        }
    }

    public func togglePin(
        targetID explicitTargetID: String? = nil,
        preferredSlot: Int? = nil,
        completion: (@Sendable (Result<T3PinLayout, T3BackendIssue>) -> Void)? = nil
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                guard let targetID = explicitTargetID ?? self.snapshotState.pins.selectedTargetID else {
                    throw T3BackendIssue(
                        code: .noSelectedThread,
                        message: "Select the exact T3 thread before pinning it."
                    )
                }
                guard self.snapshotState.targets.contains(where: { $0.id == targetID })
                        || self.snapshotState.pins.slots.contains(where: { $0 == targetID }) else {
                    throw T3BackendIssue(code: .threadMissing, message: "That exact T3 thread is not available.")
                }
                var pins = self.snapshotState.pins
                try pins.toggle(targetID: targetID, preferredSlot: preferredSlot)
                try self.pinStore.save(pins)
                self.replaceSnapshot(pins: pins, issue: .some(nil))
                self.complete(completion, with: .success(pins))
            } catch let issue as T3BackendIssue {
                self.complete(completion, with: .failure(issue))
            } catch {
                self.complete(completion, with: .failure(T3BackendIssue(
                    code: .persistence,
                    message: error.localizedDescription
                )))
            }
        }
    }

    /// Exchanges an official one-time pairing credential against the currently
    /// discovered local T3 process and saves only the resulting bearer.
    public func pair(
        bootstrapCredential: String,
        completion: @escaping @Sendable (Result<T3Environment, T3BackendIssue>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            let credential = bootstrapCredential.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !credential.isEmpty else {
                self.complete(completion, with: .failure(T3BackendIssue(
                    code: .needsPairing,
                    message: "Enter a T3 pairing code."
                )))
                return
            }
            do {
                guard let location = try self.runtimeDiscovery.discover(),
                      let origin = URL(string: location.state.origin) else {
                    throw T3BackendIssue(
                        code: .runtimeUnavailable,
                        message: "Start T3 Code before pairing AgentMicro."
                    )
                }
                self.bootstrap(origin: origin, credential: credential, completion: completion)
            } catch let issue as T3BackendIssue {
                self.complete(completion, with: .failure(issue))
            } catch {
                self.complete(completion, with: .failure(T3BackendIssue(
                    code: .invalidRuntime,
                    message: error.localizedDescription
                )))
            }
        }
    }

    /// Accepts both direct `.../pair#token=...` links and hosted
    /// `app.t3.codes/pair?host=...#token=...` links.
    public func pair(
        pairingURL: String,
        completion: @escaping @Sendable (Result<T3Environment, T3BackendIssue>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let target = try T3PairingURLParser.parse(pairingURL)
                var safeOrigin = target.origin
                if !self.configuration.allowNonLoopbackPairingOrigins, !Self.isLoopback(safeOrigin) {
                    // T3's default copied link may advertise the Mac's LAN or
                    // Tailscale address. Since this helper runs on that same
                    // Mac, exchange the credential against the discovered
                    // loopback runtime instead of rejecting it or sending the
                    // token over the network.
                    guard let localRuntime = try self.runtimeDiscovery.discover(),
                          let localOrigin = URL(string: localRuntime.state.origin),
                          Self.isLoopback(localOrigin) else {
                        throw T3BackendIssue(
                            code: .runtimeUnavailable,
                            message: "Start the local T3 Code app before using its pairing link."
                        )
                    }
                    safeOrigin = localOrigin
                }
                self.bootstrap(
                    origin: safeOrigin,
                    credential: target.bootstrapCredential,
                    completion: completion
                )
            } catch let issue as T3BackendIssue {
                self.complete(completion, with: .failure(issue))
            } catch {
                self.complete(completion, with: .failure(T3BackendIssue(
                    code: .invalidTarget,
                    message: error.localizedDescription
                )))
            }
        }
    }

    /// Migration/test hook for an already-issued bearer. Production pairing
    /// should normally call `pair(...)` so scopes and expiry are recorded.
    public func storeBearer(
        _ credential: T3BearerCredential,
        environmentID: String,
        completion: (@Sendable (Result<Void, T3BackendIssue>) -> Void)? = nil
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                guard !credential.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw T3BackendIssue(code: .needsPairing, message: "The T3 bearer is empty.")
                }
                try self.credentials.save(credential, environmentID: environmentID)
                self.complete(completion, with: .success(()))
                if self.running { self.refreshNow() }
            } catch let issue as T3BackendIssue {
                self.complete(completion, with: .failure(issue))
            } catch {
                self.complete(completion, with: .failure(T3BackendIssue(
                    code: .persistence,
                    message: error.localizedDescription
                )))
            }
        }
    }

    /// Sends a prompt only to the requested/persisted exact target. Thread
    /// detail is reloaded just before dispatch so T3's current model selection,
    /// runtime mode, and interaction mode travel together in the command.
    public func sendPrompt(
        _ text: String,
        to explicitTargetID: String? = nil,
        idempotencyKey: String? = nil,
        completion: @escaping @Sendable (Result<T3PromptReceipt, T3BackendIssue>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !prompt.isEmpty else {
                    throw T3BackendIssue(code: .invalidTarget, message: "The T3 prompt is empty.")
                }
                guard let rawTarget = explicitTargetID ?? self.snapshotState.pins.selectedTargetID,
                      let target = T3TargetID(rawValue: rawTarget) else {
                    throw T3BackendIssue(
                        code: .noSelectedThread,
                        message: "Select an exact T3 thread before sending."
                    )
                }
                guard let environment = self.wireEnvironment,
                      environment.environmentId == target.environmentID,
                      let runtime = self.runtime,
                      self.snapshotState.targets.contains(where: { $0.id == rawTarget }) else {
                    throw T3BackendIssue(
                        code: .threadMissing,
                        message: "The selected T3 thread is not present in the connected environment."
                    )
                }
                let bearer = try self.requireCredential(environmentID: environment.environmentId)
                guard !self.pendingLocalTargets.contains(rawTarget) else {
                    throw T3BackendIssue(
                        code: .server,
                        message: "A prompt is already being dispatched to that T3 thread."
                    )
                }
                if let current = self.snapshotState.targets.first(where: { $0.id == rawTarget }) {
                    self.preOptimisticTargets[rawTarget] = current
                }
                self.pendingLocalTargets.insert(rawTarget)
                self.publishOptimisticWorking(targetID: rawTarget)
                let requestSeed = idempotencyKey?.trimmingCharacters(in: .whitespacesAndNewlines)
                let seed = (requestSeed?.isEmpty == false ? requestSeed! : UUID().uuidString.lowercased())
                let commandID = T3StableUUID.make("command|\(rawTarget)|\(seed)").uuidString.lowercased()
                let messageID = T3StableUUID.make("message|\(rawTarget)|\(seed)").uuidString.lowercased()
                let createdAt = T3Date.now()

                self.loadThreadDetail(
                    origin: runtime.state.origin,
                    bearer: bearer.accessToken,
                    target: target,
                    retry: 0
                ) { result in
                    switch result {
                    case .failure(let issue):
                        self.promptFailed(targetID: rawTarget)
                        self.complete(completion, with: .failure(issue))
                    case .success(let detail):
                        guard detail.thread.id == target.threadID else {
                            self.promptFailed(targetID: rawTarget)
                            self.complete(completion, with: .failure(T3BackendIssue(
                                code: .threadMissing,
                                message: "T3 returned a different thread than the one selected."
                            )))
                            return
                        }
                        let command = T3JSONValue.object([
                            "type": .string("thread.turn.start"),
                            "commandId": .string(commandID),
                            "threadId": .string(target.threadID),
                            "message": .object([
                                "messageId": .string(messageID),
                                "role": .string("user"),
                                "text": .string(prompt),
                                "attachments": .array([]),
                            ]),
                            "modelSelection": detail.thread.modelSelection,
                            "titleSeed": .string(detail.thread.title),
                            "runtimeMode": .string(detail.thread.runtimeMode),
                            "interactionMode": .string(detail.thread.interactionMode),
                            "createdAt": .string(createdAt),
                        ])
                        self.dispatchPrompt(
                            command,
                            origin: runtime.state.origin,
                            bearer: bearer.accessToken,
                            targetID: rawTarget,
                            commandID: commandID,
                            messageID: messageID,
                            retry: 0,
                            completion: completion
                        )
                    }
                }
            } catch let issue as T3BackendIssue {
                self.complete(completion, with: .failure(issue))
            } catch {
                self.complete(completion, with: .failure(T3BackendIssue(
                    code: .server,
                    message: error.localizedDescription
                )))
            }
        }
    }

    // MARK: Pairing internals

    private func bootstrap(
        origin: URL,
        credential: String,
        completion: @escaping @Sendable (Result<T3Environment, T3BackendIssue>) -> Void
    ) {
        loadEnvironment(origin: origin.absoluteString) { result in
            switch result {
            case .failure(let issue):
                self.complete(completion, with: .failure(issue))
            case .success(let descriptor):
                guard let endpoint = Self.endpoint(origin: origin.absoluteString, path: "/oauth/token") else {
                    self.complete(completion, with: .failure(T3BackendIssue(
                        code: .invalidTarget,
                        message: "The T3 token endpoint is invalid."
                    )))
                    return
                }
                let form: [(String, String)] = [
                    ("grant_type", "urn:ietf:params:oauth:grant-type:token-exchange"),
                    ("subject_token", credential),
                    ("subject_token_type", "urn:t3:params:oauth:token-type:environment-bootstrap"),
                    ("requested_token_type", "urn:ietf:params:oauth:token-type:access_token"),
                    ("scope", "orchestration:read orchestration:operate"),
                    ("client_label", "AgentMicro Bridge"),
                    ("client_device_type", "bot"),
                    ("client_os", "macOS"),
                ]
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.timeoutInterval = self.configuration.requestTimeout
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.httpBody = Self.formEncode(form).data(using: .utf8)

                _ = self.transport.perform(request) { transportResult in
                    self.queue.async {
                        switch self.decode(transportResult, as: T3WireTokenResult.self) {
                        case .failure(let issue):
                            self.complete(completion, with: .failure(issue))
                        case .success(let token):
                            guard token.token_type.caseInsensitiveCompare("Bearer") == .orderedSame,
                                  !token.access_token.isEmpty else {
                                self.complete(completion, with: .failure(T3BackendIssue(
                                    code: .invalidResponse,
                                    message: "T3 did not issue a bearer token."
                                )))
                                return
                            }
                            let stored = T3BearerCredential(
                                accessToken: token.access_token,
                                expiresAt: Date().addingTimeInterval(max(0, token.expires_in)),
                                scopes: token.scope.split(separator: " ").map(String.init)
                            )
                            do {
                                try self.credentials.save(stored, environmentID: descriptor.environmentId)
                                let environment = T3Environment(
                                    id: descriptor.environmentId,
                                    label: descriptor.label,
                                    serverVersion: descriptor.serverVersion
                                )
                                self.complete(completion, with: .success(environment))
                                if self.running { self.refreshNow() }
                            } catch {
                                self.complete(completion, with: .failure(T3BackendIssue(
                                    code: .persistence,
                                    message: "T3 paired, but its bearer could not be saved: \(error.localizedDescription)"
                                )))
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Polling and reconnect

    private func poll(generation: UInt64) {
        guard running, generation == self.generation else { return }
        do {
            guard let discovered = try runtimeDiscovery.discover() else {
                runtimeDidDisappear()
                failPoll(T3BackendIssue(
                    code: .runtimeUnavailable,
                    message: "Waiting for T3 Code. Start the T3 desktop app to connect."
                ), generation: generation)
                return
            }

            if runtime?.fingerprint != discovered.fingerprint {
                runtime = discovered
                wireEnvironment = nil
                sequenceGate.reset()
                pendingUntilSequence.removeAll()
                pendingLocalTargets.removeAll()
                preOptimisticTargets.removeAll()
            }
            replaceSnapshot(
                phase: wireEnvironment == nil ? .connecting : snapshotState.phase,
                runtimeOrigin: discovered.state.origin,
                issue: .some(nil)
            )

            if let environment = wireEnvironment {
                pollShell(runtime: discovered, environment: environment, generation: generation)
            } else {
                loadEnvironment(origin: discovered.state.origin, pollGeneration: generation) { result in
                    guard self.running, generation == self.generation else { return }
                    switch result {
                    case .failure(let issue): self.failPoll(issue, generation: generation)
                    case .success(let environment):
                        self.wireEnvironment = environment
                        self.replaceSnapshot(
                            phase: .connecting,
                            environment: T3Environment(
                                id: environment.environmentId,
                                label: environment.label,
                                serverVersion: environment.serverVersion
                            ),
                            issue: .some(nil)
                        )
                        self.pollShell(runtime: discovered, environment: environment, generation: generation)
                    }
                }
            }
        } catch let issue as T3BackendIssue {
            runtimeDidDisappear()
            failPoll(issue, generation: generation)
        } catch {
            runtimeDidDisappear()
            failPoll(T3BackendIssue(code: .invalidRuntime, message: error.localizedDescription), generation: generation)
        }
    }

    private func pollShell(
        runtime: T3RuntimeLocation,
        environment: T3WireEnvironmentDescriptor,
        generation: UInt64
    ) {
        let bearer: T3BearerCredential
        do {
            bearer = try requireCredential(environmentID: environment.environmentId)
        } catch let issue as T3BackendIssue {
            let phase: T3ConnectionPhase = issue.code == .credentialExpired || issue.code == .needsPairing
                ? .needsPairing : .reconnecting
            replaceSnapshot(phase: phase, targets: unavailableTargets(), issue: issue)
            schedulePoll(generation: generation, after: reconnectDelay())
            return
        } catch {
            failPoll(T3BackendIssue(code: .persistence, message: error.localizedDescription), generation: generation)
            return
        }

        guard let endpoint = Self.endpoint(origin: runtime.state.origin, path: "/api/orchestration/shell") else {
            failPoll(T3BackendIssue(code: .invalidRuntime, message: "T3 shell endpoint is invalid."), generation: generation)
            return
        }
        var request = authenticatedRequest(url: endpoint, bearer: bearer.accessToken, method: "GET")
        request.timeoutInterval = configuration.requestTimeout
        pollTask = transport.perform(request) { result in
            self.queue.async {
                self.pollTask = nil
                guard self.running, generation == self.generation,
                      self.runtime?.fingerprint == runtime.fingerprint else { return }
                switch self.decode(result, as: T3WireShellSnapshot.self) {
                case .failure(let issue):
                    if issue.code == .needsPairing || issue.code == .insufficientScope {
                        self.replaceSnapshot(
                            phase: .needsPairing,
                            targets: self.unavailableTargets(),
                            issue: issue
                        )
                        self.schedulePoll(generation: generation, after: self.reconnectDelay())
                    } else {
                        self.failPoll(issue, generation: generation)
                    }
                case .success(let shell):
                    self.consecutiveFailures = 0
                    let accepted = self.sequenceGate.accept(
                        sequence: shell.snapshotSequence,
                        runtimeFingerprint: runtime.fingerprint
                    )
                    if accepted || self.snapshotState.phase != .connected {
                        self.apply(shell: shell, environment: environment)
                    } else {
                        // A duplicate snapshot still proves the connection is
                        // alive, but cannot regress any target state.
                        self.replaceSnapshot(phase: .connected, issue: .some(nil))
                    }
                    self.schedulePoll(generation: generation, after: self.configuration.pollInterval)
                }
            }
        }
    }

    private func apply(shell: T3WireShellSnapshot, environment: T3WireEnvironmentDescriptor) {
        let projects = Dictionary(uniqueKeysWithValues: shell.projects.map { ($0.id, $0) })
        pendingUntilSequence = pendingUntilSequence.filter { shell.snapshotSequence < $0.value }

        let targets = shell.threads.compactMap { thread -> T3Target? in
            guard let targetID = try? T3TargetID(
                environmentID: environment.environmentId,
                threadID: thread.id
            ) else { return nil }
            let project = projects[thread.projectId]
            let facts = T3StatusFacts(
                sessionStatus: thread.session?.status,
                sessionError: thread.session?.lastError,
                latestTurnState: thread.latestTurn?.state,
                latestTurnRequestedAt: thread.latestTurn?.requestedAt,
                latestTurnStartedAt: thread.latestTurn?.startedAt,
                latestTurnCompletedAt: thread.latestTurn?.completedAt,
                latestUserMessageAt: thread.latestUserMessageAt,
                hasPendingApprovals: thread.hasPendingApprovals,
                hasPendingUserInput: thread.hasPendingUserInput,
                hasActionableProposedPlan: thread.hasActionableProposedPlan
            )
            let mapped = T3StatusMapper.status(for: facts)
            let isLocallyPending = pendingLocalTargets.contains(targetID.rawValue)
                || pendingUntilSequence[targetID.rawValue] != nil
            let status: T3AgentStatus = isLocallyPending ? .working : mapped.status
            return T3Target(
                id: targetID.rawValue,
                environmentID: environment.environmentId,
                threadID: thread.id,
                projectID: thread.projectId,
                projectTitle: project?.title ?? "Unknown project",
                workspaceRoot: project?.workspaceRoot ?? "",
                title: thread.title,
                status: status,
                updatedAt: thread.updatedAt,
                detail: mapped.detail
            )
        }.sorted {
            if $0.updatedAt == $1.updatedAt { return $0.id < $1.id }
            return $0.updatedAt > $1.updatedAt
        }

        replaceSnapshot(
            phase: .connected,
            environment: T3Environment(
                id: environment.environmentId,
                label: environment.label,
                serverVersion: environment.serverVersion
            ),
            snapshotSequence: shell.snapshotSequence,
            targets: targets,
            issue: .some(nil)
        )
    }

    private func runtimeDidDisappear() {
        guard runtime != nil || wireEnvironment != nil else { return }
        runtime = nil
        wireEnvironment = nil
        sequenceGate.reset()
        pendingUntilSequence.removeAll()
        pendingLocalTargets.removeAll()
        preOptimisticTargets.removeAll()
    }

    private func failPoll(_ issue: T3BackendIssue, generation: UInt64) {
        consecutiveFailures += 1
        replaceSnapshot(phase: .reconnecting, targets: unavailableTargets(), issue: issue)
        schedulePoll(generation: generation, after: reconnectDelay())
    }

    private func reconnectDelay() -> TimeInterval {
        let exponent = min(consecutiveFailures, 8)
        let base = min(
            configuration.reconnectMaximumDelay,
            configuration.reconnectMinimumDelay * pow(2, Double(exponent))
        )
        // Small jitter prevents several helpers from hammering a restarted T3
        // process in lock-step; it never exceeds the configured maximum.
        return min(configuration.reconnectMaximumDelay, base * Double.random(in: 0.85...1.15))
    }

    private func schedulePoll(generation: UInt64, after delay: TimeInterval) {
        guard running, generation == self.generation else { return }
        scheduledPoll?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.poll(generation: generation) }
        scheduledPoll = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: HTTP operations

    private func loadEnvironment(
        origin: String,
        pollGeneration: UInt64? = nil,
        completion: @escaping @Sendable (Result<T3WireEnvironmentDescriptor, T3BackendIssue>) -> Void
    ) {
        guard let endpoint = Self.endpoint(origin: origin, path: "/.well-known/t3/environment") else {
            completion(.failure(T3BackendIssue(
                code: .invalidRuntime,
                message: "T3 environment endpoint is invalid."
            )))
            return
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = configuration.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let task = transport.perform(request) { result in
            self.queue.async {
                if let pollGeneration,
                   (!self.running || self.generation != pollGeneration) { return }
                completion(self.decode(result, as: T3WireEnvironmentDescriptor.self))
            }
        }
        if pollGeneration != nil { pollTask = task }
    }

    private func loadThreadDetail(
        origin: String,
        bearer: String,
        target: T3TargetID,
        retry: Int,
        completion: @escaping @Sendable (Result<T3WireThreadDetailSnapshot, T3BackendIssue>) -> Void
    ) {
        let encoded = Self.pathSegment(target.threadID)
        guard let endpoint = Self.endpoint(
            origin: origin,
            path: "/api/orchestration/threads/\(encoded)"
        ) else {
            completion(.failure(T3BackendIssue(code: .invalidRuntime, message: "T3 thread endpoint is invalid.")))
            return
        }
        var request = authenticatedRequest(url: endpoint, bearer: bearer, method: "GET")
        request.timeoutInterval = configuration.requestTimeout
        _ = transport.perform(request) { result in
            self.queue.async {
                let decoded: Result<T3WireThreadDetailSnapshot, T3BackendIssue> = self.decode(result, as: T3WireThreadDetailSnapshot.self)
                switch decoded {
                case .success:
                    completion(decoded)
                case .failure(let issue) where self.shouldRetry(issue) && retry < self.configuration.maximumDispatchRetries:
                    self.queue.asyncAfter(deadline: .now() + self.operationRetryDelay(retry)) {
                        self.loadThreadDetail(
                            origin: origin,
                            bearer: bearer,
                            target: target,
                            retry: retry + 1,
                            completion: completion
                        )
                    }
                case .failure(let issue):
                    completion(.failure(issue.code == .server && issue.message.contains("not_found")
                        ? T3BackendIssue(code: .threadMissing, message: "The selected T3 thread no longer exists.")
                        : issue))
                }
            }
        }
    }

    private func dispatchPrompt(
        _ command: T3JSONValue,
        origin: String,
        bearer: String,
        targetID: String,
        commandID: String,
        messageID: String,
        retry: Int,
        completion: @escaping @Sendable (Result<T3PromptReceipt, T3BackendIssue>) -> Void
    ) {
        guard let endpoint = Self.endpoint(origin: origin, path: "/api/orchestration/dispatch") else {
            complete(completion, with: .failure(T3BackendIssue(
                code: .invalidRuntime,
                message: "T3 dispatch endpoint is invalid."
            )))
            return
        }
        var request = authenticatedRequest(url: endpoint, bearer: bearer, method: "POST")
        request.timeoutInterval = configuration.requestTimeout
        do {
            request.httpBody = try JSONEncoder().encode(command)
        } catch {
            complete(completion, with: .failure(T3BackendIssue(
                code: .invalidResponse,
                message: "Could not encode the T3 command."
            )))
            return
        }

        _ = transport.perform(request) { result in
            self.queue.async {
                let decoded: Result<T3WireDispatchResult, T3BackendIssue> = self.decode(result, as: T3WireDispatchResult.self)
                switch decoded {
                case .success(let dispatch):
                    // T3 persists command receipts by commandId. If the first
                    // response was lost, retrying this exact body returns the
                    // original sequence instead of creating a second turn.
                    self.pendingLocalTargets.remove(targetID)
                    self.preOptimisticTargets.removeValue(forKey: targetID)
                    self.pendingUntilSequence[targetID] = dispatch.sequence
                    self.publishOptimisticWorking(targetID: targetID)
                    self.complete(completion, with: .success(T3PromptReceipt(
                        targetID: targetID,
                        commandID: commandID,
                        messageID: messageID,
                        sequence: dispatch.sequence
                    )))
                    if self.running { self.refreshNow() }
                case .failure(let issue) where self.shouldRetry(issue) && retry < self.configuration.maximumDispatchRetries:
                    self.queue.asyncAfter(deadline: .now() + self.operationRetryDelay(retry)) {
                        self.dispatchPrompt(
                            command,
                            origin: origin,
                            bearer: bearer,
                            targetID: targetID,
                            commandID: commandID,
                            messageID: messageID,
                            retry: retry + 1,
                            completion: completion
                        )
                    }
                case .failure(let issue):
                    self.promptFailed(targetID: targetID)
                    self.complete(completion, with: .failure(issue))
                }
            }
        }
    }

    private func authenticatedRequest(url: URL, bearer: String, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if method != "GET" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func decode<Value: Decodable>(
        _ result: Result<T3HTTPResponse, Error>,
        as type: Value.Type
    ) -> Result<Value, T3BackendIssue> {
        switch result {
        case .failure(let issue as T3BackendIssue): return .failure(issue)
        case .failure(let error):
            return .failure(T3BackendIssue(
                code: .transport,
                message: "T3 is temporarily unreachable: \(error.localizedDescription)"
            ))
        case .success(let response):
            guard (200..<300).contains(response.statusCode) else {
                return .failure(issue(for: response))
            }
            do {
                return .success(try JSONDecoder().decode(type, from: response.body))
            } catch {
                return .failure(T3BackendIssue(
                    code: .invalidResponse,
                    message: "T3 returned an incompatible response for \(type)."
                ))
            }
        }
    }

    private func issue(for response: T3HTTPResponse) -> T3BackendIssue {
        let wire = try? JSONDecoder().decode(T3WireServerError.self, from: response.body)
        let trace = wire?.traceId
        switch response.statusCode {
        case 401:
            return T3BackendIssue(
                code: .needsPairing,
                message: "T3 rejected this helper's credential. Create a new pairing link in T3 Code.",
                traceID: trace
            )
        case 403:
            let required = wire?.requiredScope.map { " (requires \($0))" } ?? ""
            return T3BackendIssue(
                code: .insufficientScope,
                message: "The saved T3 credential lacks permission\(required). Pair it again.",
                traceID: trace
            )
        case 404:
            return T3BackendIssue(
                code: .threadMissing,
                message: "The selected T3 thread no longer exists.",
                traceID: trace
            )
        case 408, 425, 429:
            return T3BackendIssue(
                code: .server,
                message: "T3 asked the helper to retry (HTTP \(response.statusCode)).",
                isRecoverable: true,
                traceID: trace
            )
        case 400..<500:
            let detail = [wire?.code, wire?.reason].compactMap { $0 }.joined(separator: "/")
            return T3BackendIssue(
                code: .server,
                message: detail.isEmpty ? "T3 rejected the request (HTTP \(response.statusCode))." : "T3 rejected the request: \(detail).",
                isRecoverable: false,
                traceID: trace
            )
        default:
            return T3BackendIssue(
                code: .server,
                message: "T3 server error (HTTP \(response.statusCode)).",
                traceID: trace
            )
        }
    }

    private func requireCredential(environmentID: String) throws -> T3BearerCredential {
        guard let credential = try credentials.load(environmentID: environmentID) else {
            throw T3BackendIssue(
                code: .needsPairing,
                message: "T3 is running, but AgentMicro has not been paired with it."
            )
        }
        guard !credential.isExpired() else {
            throw T3BackendIssue(
                code: .credentialExpired,
                message: "The T3 pairing expired. Create a fresh pairing link in T3 Code."
            )
        }
        return credential
    }

    private func shouldRetry(_ issue: T3BackendIssue) -> Bool {
        issue.code == .transport || (issue.code == .server && issue.isRecoverable)
    }

    private func operationRetryDelay(_ retry: Int) -> TimeInterval {
        min(2, 0.25 * pow(2, Double(retry)))
    }

    private func unavailableTargets() -> [T3Target] {
        snapshotState.targets.map { target in
            T3Target(
                id: target.id,
                environmentID: target.environmentID,
                threadID: target.threadID,
                projectID: target.projectID,
                projectTitle: target.projectTitle,
                workspaceRoot: target.workspaceRoot,
                title: target.title,
                status: .unavailable,
                updatedAt: target.updatedAt,
                detail: "T3 disconnected"
            )
        }
    }

    private func publishOptimisticWorking(targetID: String) {
        let optimisticTargets = snapshotState.targets.map { target -> T3Target in
            guard target.id == targetID else { return target }
            return T3Target(
                id: target.id,
                environmentID: target.environmentID,
                threadID: target.threadID,
                projectID: target.projectID,
                projectTitle: target.projectTitle,
                workspaceRoot: target.workspaceRoot,
                title: target.title,
                status: .working,
                updatedAt: target.updatedAt,
                detail: nil
            )
        }
        replaceSnapshot(targets: optimisticTargets, issue: .some(nil))
    }

    private func promptFailed(targetID: String) {
        pendingLocalTargets.remove(targetID)
        pendingUntilSequence.removeValue(forKey: targetID)
        if let original = preOptimisticTargets.removeValue(forKey: targetID) {
            let restored = snapshotState.targets.map { $0.id == targetID ? original : $0 }
            replaceSnapshot(targets: restored)
        }
        if running { refreshNow() }
    }

    // MARK: State publication

    private func replaceSnapshot(
        phase: T3ConnectionPhase? = nil,
        environment: T3Environment?? = nil,
        runtimeOrigin: String?? = nil,
        snapshotSequence: Int?? = nil,
        targets: [T3Target]? = nil,
        pins: T3PinLayout? = nil,
        issue: T3BackendIssue?? = nil
    ) {
        snapshotState = T3BackendSnapshot(
            phase: phase ?? snapshotState.phase,
            environment: environment ?? snapshotState.environment,
            runtimeOrigin: runtimeOrigin ?? snapshotState.runtimeOrigin,
            snapshotSequence: snapshotSequence ?? snapshotState.snapshotSequence,
            targets: targets ?? snapshotState.targets,
            pins: pins ?? snapshotState.pins,
            issue: issue ?? snapshotState.issue
        )
        emit(snapshotState)
    }

    private func emit(_ snapshot: T3BackendSnapshot) {
        guard let handler else { return }
        configuration.callbackQueue.async { handler(snapshot) }
    }

    private func complete<Value: Sendable>(
        _ completion: (@Sendable (Result<Value, T3BackendIssue>) -> Void)?,
        with result: Result<Value, T3BackendIssue>
    ) {
        guard let completion else { return }
        configuration.callbackQueue.async { completion(result) }
    }

    // MARK: URL helpers

    private static func endpoint(origin: String, path: String) -> URL? {
        guard var components = URLComponents(string: origin),
              components.scheme != nil, components.host != nil else { return nil }
        components.percentEncodedPath = path
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func pathSegment(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func formEncode(_ values: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return values.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
    }

    private static func isLoopback(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}

// MARK: - XCTest-free deterministic self-tests

public enum T3BackendSelfTests {
    public static func run() throws {
        try expect(
            T3TargetID(rawValue: "t3:environment-a:thread-9")?.threadID == "thread-9",
            "target IDs round-trip"
        )
        try expect(T3TargetID(rawValue: "vscode:thread-9") == nil, "foreign target IDs are rejected")

        var pins = T3PinLayout(slots: [
            "t3:e:a", "t3:e:a", nil, "bad", nil, nil,
        ], selectedTargetID: "t3:e:a")
        try expect(pins.slots.compactMap { $0 }.count == 1, "pin restore removes duplicates")
        _ = try pins.toggle(targetID: "t3:e:b")
        try expect(pins.slots.compactMap { $0 }.count == 2, "one toggle adds one pin")
        _ = try pins.toggle(targetID: "t3:e:b")
        try expect(pins.slots.compactMap { $0 }.count == 1, "second toggle removes that pin")

        var gate = T3SequenceGate()
        try expect(gate.accept(sequence: 8, runtimeFingerprint: "one"), "first sequence is accepted")
        try expect(!gate.accept(sequence: 8, runtimeFingerprint: "one"), "duplicate sequence is ignored")
        try expect(!gate.accept(sequence: 7, runtimeFingerprint: "one"), "older sequence is ignored")
        try expect(gate.accept(sequence: 1, runtimeFingerprint: "two"), "new runtime resets sequence")

        let working = T3StatusMapper.status(for: T3StatusFacts(sessionStatus: "running"))
        try expect(working.status == .working, "running maps to working")
        let approval = T3StatusMapper.status(for: T3StatusFacts(
            sessionStatus: "running",
            hasPendingApprovals: true
        ))
        try expect(approval.status == .needsApproval, "approval wins over running")
        let failed = T3StatusMapper.status(for: T3StatusFacts(
            sessionStatus: "error",
            sessionError: "boom"
        ))
        try expect(failed.status == .error && failed.detail == "boom", "errors retain detail")

        let firstID = T3StableUUID.make("same input")
        try expect(firstID == T3StableUUID.make("same input"), "idempotency UUID is stable")
        try expect(firstID != T3StableUUID.make("different input"), "idempotency UUID separates inputs")

        let direct = try T3PairingURLParser.parse("http://127.0.0.1:3773/pair#token=secret")
        try expect(direct.origin.absoluteString == "http://127.0.0.1:3773/", "direct pairing origin")
        try expect(direct.bootstrapCredential == "secret", "direct pairing token")
        let hosted = try T3PairingURLParser.parse(
            "https://app.t3.codes/pair?host=http%3A%2F%2F127.0.0.1%3A3773%2F#token=secret-2"
        )
        try expect(hosted.origin.absoluteString == "http://127.0.0.1:3773/", "hosted pairing origin")

        let runtimeJSON = #"{"version":1,"pid":123,"port":3773,"origin":"http://127.0.0.1:3773","startedAt":"2026-07-22T00:00:00.000Z"}"#
        let runtime = try JSONDecoder().decode(
            T3PersistedRuntimeState.self,
            from: Data(runtimeJSON.utf8)
        )
        try expect(runtime.port == 3773 && runtime.version == 1, "runtime JSON decodes")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw T3BackendIssue(
                code: .invalidResponse,
                message: "T3Backend self-test failed: \(message)",
                isRecoverable: false
            )
        }
    }
}
