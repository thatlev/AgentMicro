//
//  ClaudeMobileIntegration.swift
//  AgentMicroRemote
//
//  A deliberately small integration with the public Claude iOS URL surface.
//  It does not inspect, scrape, automate, or make assumptions about Claude's
//  UI. The public links can open Claude Code, open an exact session, or prefill
//  a new-session composer. They cannot submit a prompt or report session
//  status, and this API intentionally does not pretend otherwise.
//

import Combine
import Foundation

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Errors

enum ClaudeMobileIntegrationError: Error, Equatable, LocalizedError {
    case invalidSessionIdentifier(String)
    case unsupportedDeepLink
    case unsafeDeepLink
    case emptyPrompt
    case unsafePrompt
    case promptTooLong(maximumUTF8Bytes: Int)
    case invalidPinSlot(Int)
    case emptyPinSlot(Int)
    case noFreePinSlot
    case persistenceFailed
    case appUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidSessionIdentifier:
            return "Enter the exact Claude Code session UUID."
        case .unsupportedDeepLink:
            return "Use an official Claude Code link: claude://code, claude://code/<session-uuid>, or claude://code/new?q=…"
        case .unsafeDeepLink:
            return "That Claude link contains unsupported credentials, fragments, paths, or parameters."
        case .emptyPrompt:
            return "Record or enter a prompt before opening a new Claude Code session."
        case .unsafePrompt:
            return "The prompt contains control characters that cannot be placed safely in a link."
        case let .promptTooLong(maximumUTF8Bytes):
            return "The prompt is too long for a reliable app link (maximum \(maximumUTF8Bytes) UTF-8 bytes)."
        case let .invalidPinSlot(index):
            return "Claude Code pin \(index + 1) does not exist."
        case let .emptyPinSlot(index):
            return "Claude Code pin \(index + 1) has no session assigned."
        case .noFreePinSlot:
            return "All six Claude Code pins are in use. Unpin a session before adding another."
        case .persistenceFailed:
            return "The Claude Code pins could not be saved."
        case .appUnavailable:
            return "Claude could not open the link. Install or update the Claude iPhone app and try again."
        }
    }
}

// MARK: - Exact session identity

/// A concrete Claude Code session, never a provider name or model name.
///
/// UUID normalization makes the same session compare equal regardless of the
/// casing used by a pasted link. `id` is its canonical exact-session deep link,
/// which is also safe to use as a SwiftUI identity.
struct ClaudeMobileSessionIdentity: Hashable, Codable, Sendable, Identifiable {
    let sessionID: UUID

    var id: String { exactSessionDeepLink.absoluteString }
    var canonicalSessionID: String { sessionID.uuidString.lowercased() }

    var exactSessionDeepLink: URL {
        ClaudeMobileDeepLink.exactSession(self)
    }

    init(sessionID: UUID) {
        self.sessionID = sessionID
    }

    init(sessionID rawValue: String) throws {
        guard rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines),
              let uuid = UUID(uuidString: rawValue)
        else {
            throw ClaudeMobileIntegrationError.invalidSessionIdentifier(rawValue)
        }
        self.sessionID = uuid
    }

    init(exactSessionDeepLink url: URL) throws {
        guard case let .exactSession(identity) = try ClaudeMobileDeepLink.intent(for: url) else {
            throw ClaudeMobileIntegrationError.unsupportedDeepLink
        }
        self = identity
    }

    init(exactSessionDeepLink rawValue: String) throws {
        guard let url = URL(string: rawValue) else {
            throw ClaudeMobileIntegrationError.unsupportedDeepLink
        }
        try self.init(exactSessionDeepLink: url)
    }
}

// MARK: - Deep links

/// The complete set of public operations this integration supports.
///
/// `newSessionPrefill` means exactly that: Claude receives text for its new
/// session composer. It is not an auto-submit request and does not imply that a
/// remote session started.
enum ClaudeMobileLaunchIntent: Equatable, Sendable {
    case codeHome
    case exactSession(ClaudeMobileSessionIdentity)
    case newSessionPrefill(prompt: String)

    enum Effect: Equatable, Sendable {
        case openOnly
        case prefillOnly
    }

    var effect: Effect {
        switch self {
        case .codeHome, .exactSession: return .openOnly
        case .newSessionPrefill: return .prefillOnly
        }
    }
}

/// Pure URL construction and validation, suitable for unit tests without
/// launching an application.
enum ClaudeMobileDeepLink {
    static let scheme = "claude"
    static let codeHost = "code"
    static let maximumPromptUTF8Bytes = 8_192

    static var codeHome: URL {
        // Both pieces are fixed constants, so construction cannot fail.
        URL(string: "\(scheme)://\(codeHost)")!
    }

    static func exactSession(_ identity: ClaudeMobileSessionIdentity) -> URL {
        // UUID text contains only URL path-safe ASCII characters.
        URL(string: "\(scheme)://\(codeHost)/\(identity.canonicalSessionID)")!
    }

    static func newSessionPrefill(prompt rawPrompt: String) throws -> URL {
        let prompt = try normalizedPrompt(rawPrompt)
        var components = URLComponents()
        components.scheme = scheme
        components.host = codeHost
        components.path = "/new"
        // URLComponents encodes &, ?, #, +, Unicode, and line breaks as query
        // data rather than allowing them to change the link's structure.
        components.queryItems = [URLQueryItem(name: "q", value: prompt)]
        guard let url = components.url else {
            throw ClaudeMobileIntegrationError.unsafePrompt
        }
        return url
    }

    static func url(for intent: ClaudeMobileLaunchIntent) throws -> URL {
        switch intent {
        case .codeHome:
            return codeHome
        case let .exactSession(identity):
            return exactSession(identity)
        case let .newSessionPrefill(prompt):
            return try newSessionPrefill(prompt: prompt)
        }
    }

    /// Accepts only the documented custom-scheme shapes. In particular, a
    /// saved session link cannot contain query parameters, credentials,
    /// fragments, extra path components, or an encoded slash.
    static func intent(for url: URL) throws -> ClaudeMobileLaunchIntent {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == scheme,
              components.host?.lowercased() == codeHost
        else {
            throw ClaudeMobileIntegrationError.unsupportedDeepLink
        }

        guard components.user == nil,
              components.password == nil,
              components.port == nil,
              components.fragment == nil
        else {
            throw ClaudeMobileIntegrationError.unsafeDeepLink
        }

        let path = components.percentEncodedPath
        if path.isEmpty || path == "/" {
            guard components.percentEncodedQuery == nil else {
                throw ClaudeMobileIntegrationError.unsafeDeepLink
            }
            return .codeHome
        }

        if path == "/new" {
            guard let items = components.queryItems,
                  items.count == 1,
                  items[0].name == "q",
                  let rawPrompt = items[0].value
            else {
                throw ClaudeMobileIntegrationError.unsafeDeepLink
            }
            return .newSessionPrefill(prompt: try normalizedPrompt(rawPrompt))
        }

        let encodedSessionID = String(path.dropFirst())
        guard path.first == "/",
              !encodedSessionID.isEmpty,
              !encodedSessionID.contains("/"),
              !encodedSessionID.lowercased().contains("%2f"),
              components.percentEncodedQuery == nil,
              encodedSessionID.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "0123456789abcdefABCDEF-").contains($0)
              })
        else {
            throw ClaudeMobileIntegrationError.unsafeDeepLink
        }

        return .exactSession(try ClaudeMobileSessionIdentity(sessionID: encodedSessionID))
    }

    static func intent(for rawValue: String) throws -> ClaudeMobileLaunchIntent {
        guard let url = URL(string: rawValue) else {
            throw ClaudeMobileIntegrationError.unsupportedDeepLink
        }
        return try intent(for: url)
    }

    /// Normalizes harmless line-ending differences but rejects hidden control
    /// characters. Newlines and tabs remain valid prompt content.
    static func normalizedPrompt(_ rawValue: String) throws -> String {
        let lineNormalized = rawValue
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let prompt = lineNormalized.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !prompt.isEmpty else {
            throw ClaudeMobileIntegrationError.emptyPrompt
        }

        let containsUnsafeControl = prompt.unicodeScalars.contains { scalar in
            scalar.value < 0x20 && scalar != "\n" && scalar != "\t"
        }
        guard !containsUnsafeControl else {
            throw ClaudeMobileIntegrationError.unsafePrompt
        }

        guard prompt.utf8.count <= maximumPromptUTF8Bytes else {
            throw ClaudeMobileIntegrationError.promptTooLong(
                maximumUTF8Bytes: maximumPromptUTF8Bytes
            )
        }
        return prompt
    }
}

// MARK: - Six isolated session pins

/// User-facing metadata for one exact session. The identity is the pin; the
/// label is only presentation and is sanitized on construction and decoding.
struct ClaudeMobilePinnedSession: Codable, Equatable, Sendable, Identifiable {
    let identity: ClaudeMobileSessionIdentity
    let label: String

    var id: String { identity.id }
    var deepLink: URL { identity.exactSessionDeepLink }

    init(identity: ClaudeMobileSessionIdentity, label rawLabel: String? = nil) {
        self.identity = identity
        self.label = Self.sanitizedLabel(rawLabel, identity: identity)
    }

    init(exactSessionDeepLink: String, label: String? = nil) throws {
        let identity = try ClaudeMobileSessionIdentity(exactSessionDeepLink: exactSessionDeepLink)
        self.init(identity: identity, label: label)
    }

    private enum CodingKeys: String, CodingKey {
        case identity
        case label
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let identity = try container.decode(ClaudeMobileSessionIdentity.self, forKey: .identity)
        let label = try container.decodeIfPresent(String.self, forKey: .label)
        self.init(identity: identity, label: label)
    }

    private static func sanitizedLabel(
        _ rawValue: String?,
        identity: ClaudeMobileSessionIdentity
    ) -> String {
        var printable = ""
        for scalar in (rawValue ?? "").unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                printable.append(" ")
            } else if !CharacterSet.controlCharacters.contains(scalar) {
                printable.unicodeScalars.append(scalar)
            }
        }
        let collapsed = printable
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !collapsed.isEmpty {
            return String(collapsed.prefix(80))
        }
        return "Claude session \(identity.canonicalSessionID.prefix(8))"
    }
}

enum ClaudeMobilePinChange: Equatable, Sendable {
    case pinned(slot: Int)
    case alreadyPinned(slot: Int)
    case unpinned(slot: Int)
    case assigned(slot: Int)
}

/// A pure six-element pin map. Its decoder repairs short/long archives and
/// removes duplicate session identities, so one tap can never create two pins.
struct ClaudeMobilePinSlots: Codable, Equatable, Sendable {
    static let slotCount = 6

    private(set) var slots: [ClaudeMobilePinnedSession?]

    init() {
        slots = Array(repeating: nil, count: Self.slotCount)
    }

    init(slots rawSlots: [ClaudeMobilePinnedSession?]) {
        var normalized = Array<ClaudeMobilePinnedSession?>(repeating: nil, count: Self.slotCount)
        var seen = Set<ClaudeMobileSessionIdentity>()
        for index in 0..<min(rawSlots.count, Self.slotCount) {
            guard let target = rawSlots[index], seen.insert(target.identity).inserted else { continue }
            normalized[index] = target
        }
        slots = normalized
    }

    subscript(slot index: Int) -> ClaudeMobilePinnedSession? {
        guard slots.indices.contains(index) else { return nil }
        return slots[index]
    }

    func slot(of identity: ClaudeMobileSessionIdentity) -> Int? {
        slots.firstIndex { $0?.identity == identity }
    }

    /// Allocates the first unoccupied key. Calling it repeatedly for the same
    /// exact session is idempotent and never consumes another key.
    mutating func pinFirstAvailable(_ target: ClaudeMobilePinnedSession) throws -> ClaudeMobilePinChange {
        if let existing = slot(of: target.identity) {
            return .alreadyPinned(slot: existing)
        }
        guard let available = slots.firstIndex(where: { $0 == nil }) else {
            throw ClaudeMobileIntegrationError.noFreePinSlot
        }
        slots[available] = target
        return .pinned(slot: available)
    }

    /// Pins one exact session to one exact key. If that session was assigned to
    /// another key, it is moved instead of duplicated.
    mutating func assign(
        _ target: ClaudeMobilePinnedSession,
        toSlot index: Int
    ) throws -> ClaudeMobilePinChange {
        guard slots.indices.contains(index) else {
            throw ClaudeMobileIntegrationError.invalidPinSlot(index)
        }
        if let existing = slot(of: target.identity), existing != index {
            slots[existing] = nil
        }
        slots[index] = target
        return .assigned(slot: index)
    }

    mutating func toggle(_ target: ClaudeMobilePinnedSession) throws -> ClaudeMobilePinChange {
        if let existing = slot(of: target.identity) {
            slots[existing] = nil
            return .unpinned(slot: existing)
        }
        return try pinFirstAvailable(target)
    }

    @discardableResult
    mutating func unpin(slot index: Int) throws -> ClaudeMobilePinnedSession? {
        guard slots.indices.contains(index) else {
            throw ClaudeMobileIntegrationError.invalidPinSlot(index)
        }
        let previous = slots[index]
        slots[index] = nil
        return previous
    }

    mutating func removeAll() {
        slots = Array(repeating: nil, count: Self.slotCount)
    }

    private enum CodingKeys: String, CodingKey {
        case slots
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(slots: try container.decode([ClaudeMobilePinnedSession?].self, forKey: .slots))
    }
}

// MARK: - Opening abstraction

/// Injectable so URL handoff behavior can be tested without Claude or UIKit.
@MainActor
protocol ClaudeMobileURLOpening {
    /// Returns only whether the operating system accepted the URL handoff.
    /// It does not mean a session loaded or a prompt was submitted.
    func open(_ url: URL) async -> Bool
}

#if canImport(UIKit)
@MainActor
struct ClaudeMobileSystemURLOpener: ClaudeMobileURLOpening {
    func open(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            UIApplication.shared.open(url, options: [:]) { accepted in
                continuation.resume(returning: accepted)
            }
        }
    }
}
#endif

/// Receipt that means only that iOS accepted a handoff to Claude. It carries no
/// claim about submission, execution, connection, or session status.
struct ClaudeMobileOpenReceipt: Equatable, Sendable {
    let intent: ClaudeMobileLaunchIntent
    let acceptedBySystemAt: Date
}

// MARK: - Persistent integration facade

@MainActor
final class ClaudeMobileIntegration: ObservableObject {
    nonisolated static let defaultPinsStorageKey = "io.github.thislev.codexmicroremote.claudeMobile.sessionPins.v1"

    @Published private(set) var pins: ClaudeMobilePinSlots
    @Published private(set) var recoveryNotice: String?
    @Published private(set) var lastError: ClaudeMobileIntegrationError?

    private let defaults: UserDefaults
    private let pinsStorageKey: String
    private let opener: any ClaudeMobileURLOpening

    private struct PinsArchive: Codable {
        let schemaVersion: Int
        let pins: ClaudeMobilePinSlots
    }

    init(
        defaults: UserDefaults,
        pinsStorageKey: String = ClaudeMobileIntegration.defaultPinsStorageKey,
        opener: any ClaudeMobileURLOpening
    ) {
        self.defaults = defaults
        self.pinsStorageKey = pinsStorageKey
        self.opener = opener
        self.pins = ClaudeMobilePinSlots()
        reloadPins()
    }

#if canImport(UIKit)
    convenience init(
        defaults: UserDefaults = .standard,
        pinsStorageKey: String = ClaudeMobileIntegration.defaultPinsStorageKey
    ) {
        self.init(
            defaults: defaults,
            pinsStorageKey: pinsStorageKey,
            opener: ClaudeMobileSystemURLOpener()
        )
    }
#endif

    func clearError() {
        lastError = nil
    }

    func reloadPins() {
        guard let data = defaults.data(forKey: pinsStorageKey) else {
            pins = ClaudeMobilePinSlots()
            recoveryNotice = nil
            return
        }

        do {
            let archive = try JSONDecoder().decode(PinsArchive.self, from: data)
            guard archive.schemaVersion == 1 else {
                pins = ClaudeMobilePinSlots()
                recoveryNotice = "Saved Claude Code pins used an unsupported format and were not loaded."
                return
            }
            // Re-normalize even a successfully decoded archive to preserve the
            // six-slot and no-duplicates invariants across future schema work.
            pins = ClaudeMobilePinSlots(slots: archive.pins.slots)
            recoveryNotice = nil
        } catch {
            pins = ClaudeMobilePinSlots()
            recoveryNotice = "Saved Claude Code pins were damaged and were safely reset."
        }
    }

    @discardableResult
    func pinFirstAvailable(_ target: ClaudeMobilePinnedSession) throws -> ClaudeMobilePinChange {
        try updatePins { try $0.pinFirstAvailable(target) }
    }

    @discardableResult
    func assign(
        _ target: ClaudeMobilePinnedSession,
        toSlot index: Int
    ) throws -> ClaudeMobilePinChange {
        try updatePins { try $0.assign(target, toSlot: index) }
    }

    @discardableResult
    func togglePin(_ target: ClaudeMobilePinnedSession) throws -> ClaudeMobilePinChange {
        try updatePins { try $0.toggle(target) }
    }

    @discardableResult
    func unpin(slot index: Int) throws -> ClaudeMobilePinnedSession? {
        try updatePins { try $0.unpin(slot: index) }
    }

    func removeAllPins() throws {
        try updatePins { slots in
            slots.removeAll()
        }
    }

    func openCodeHome() async throws -> ClaudeMobileOpenReceipt {
        try await handOff(.codeHome)
    }

    func openExactSession(_ identity: ClaudeMobileSessionIdentity) async throws -> ClaudeMobileOpenReceipt {
        try await handOff(.exactSession(identity))
    }

    func openExactSession(deepLink: String) async throws -> ClaudeMobileOpenReceipt {
        let identity = try ClaudeMobileSessionIdentity(exactSessionDeepLink: deepLink)
        return try await openExactSession(identity)
    }

    func openPinnedSession(slot index: Int) async throws -> ClaudeMobileOpenReceipt {
        guard pins.slots.indices.contains(index) else {
            throw remember(.invalidPinSlot(index))
        }
        guard let target = pins[slot: index] else {
            throw remember(.emptyPinSlot(index))
        }
        return try await openExactSession(target.identity)
    }

    /// Opens Claude's new-session composer with text already filled in. The
    /// user still reviews and submits it inside Claude.
    func openNewSessionPrefill(prompt: String) async throws -> ClaudeMobileOpenReceipt {
        let normalized: String
        do {
            normalized = try ClaudeMobileDeepLink.normalizedPrompt(prompt)
        } catch let error as ClaudeMobileIntegrationError {
            throw remember(error)
        }
        return try await handOff(.newSessionPrefill(prompt: normalized))
    }

    private func handOff(_ intent: ClaudeMobileLaunchIntent) async throws -> ClaudeMobileOpenReceipt {
        let url: URL
        do {
            url = try ClaudeMobileDeepLink.url(for: intent)
        } catch let error as ClaudeMobileIntegrationError {
            throw remember(error)
        } catch {
            throw remember(.unsafeDeepLink)
        }

        guard await opener.open(url) else {
            throw remember(.appUnavailable)
        }
        lastError = nil
        return ClaudeMobileOpenReceipt(intent: intent, acceptedBySystemAt: Date())
    }

    private func updatePins<Result>(
        _ mutation: (inout ClaudeMobilePinSlots) throws -> Result
    ) throws -> Result {
        let previous = pins
        var updated = previous
        do {
            let result = try mutation(&updated)
            let archive = PinsArchive(schemaVersion: 1, pins: updated)
            let data = try JSONEncoder().encode(archive)
            defaults.set(data, forKey: pinsStorageKey)
            pins = updated
            recoveryNotice = nil
            lastError = nil
            return result
        } catch let error as ClaudeMobileIntegrationError {
            pins = previous
            throw remember(error)
        } catch {
            pins = previous
            throw remember(.persistenceFailed)
        }
    }

    @discardableResult
    private func remember(_ error: ClaudeMobileIntegrationError) -> ClaudeMobileIntegrationError {
        lastError = error
        return error
    }
}
