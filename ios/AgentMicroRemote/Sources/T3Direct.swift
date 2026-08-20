//
//  T3Direct.swift
//  AgentMicroRemote
//
//  The T3 Code page is the one surface that does NOT ride the Mac bridge. T3
//  Code is open source, so instead of reverse-engineering a desktop app the
//  iPhone speaks T3's own HTTP API directly over the LAN — "an app talking to
//  its own thing". This file adapts the standalone `T3Backend` (the same
//  discovery/pairing/poll/dispatch engine the bridge uses) to run *inside the
//  app*:
//
//    • `T3NetworkRuntimeDiscovery` replaces the Mac-only filesystem discovery of
//      `server-runtime.json` with a paired network origin (e.g.
//      http://192.168.x.x:3773 from a `…/pair#token=…` link).
//    • `T3DirectController` ports the bridge's `T3Controller` translation:
//      macropad key/command events → `backend.select/togglePin/sendPrompt`, and
//      each `T3BackendSnapshot` → the same `workspace-state` dictionary the
//      peripheral already applies for the `t3code` surface. The board UI is
//      unchanged; only the plumbing behind `t3code` moved off the bridge.
//
//  Nothing here touches ChatGPT, VS Code, or Claude Desktop, so the T3 page
//  stays fully isolated from the other surfaces.
//

import Foundation

// MARK: - Network runtime discovery (LAN, replaces filesystem discovery)

/// Supplies the paired T3 server origin to `T3Backend` in place of the Mac-only
/// `server-runtime.json` file discovery. The origin comes from a pairing URL
/// the user pastes/scans and is persisted so the app reconnects on launch.
///
/// `discover()` is invoked on the backend's private queue while `setOrigin` is
/// called from the main actor, so access is guarded by a lock.
final class T3NetworkRuntimeDiscovery: T3RuntimeDiscovering, @unchecked Sendable {
    private let lock = NSLock()
    private var location: T3RuntimeLocation?

    /// A fixed synthetic file URL keeps `T3RuntimeLocation.fingerprint`
    /// (`path|pid|startedAt|origin`) stable across reconnects — the origin is
    /// the only part that varies, so re-pairing to a different server correctly
    /// resets the backend while the same server does not.
    private static let syntheticFile = URL(fileURLWithPath: "/agentmicro/t3/network-runtime")

    init(origin: URL? = nil) {
        setOrigin(origin)
    }

    /// Set (or clear) the paired origin. Passing `nil` puts the backend into its
    /// "waiting for T3" state until the user pairs.
    func setOrigin(_ origin: URL?) {
        lock.lock(); defer { lock.unlock() }
        guard
            let origin,
            let scheme = origin.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = origin.host, !host.isEmpty
        else {
            location = nil
            return
        }
        let port = origin.port ?? (scheme == "https" ? 443 : 80)
        // Normalize to a bare origin (scheme://host[:port]) with no path. IPv6
        // literals must be bracketed so the origin re-parses (note: a server
        // started with `--host 0.0.0.0` only listens on IPv4, so prefer an IPv4
        // pairing URL — this just keeps an IPv6 origin well-formed).
        let hostLiteral = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        let normalized = "\(scheme)://\(hostLiteral):\(port)"
        let state = T3PersistedRuntimeState(
            version: 1,
            pid: 1, // synthetic; the network discoverer never checks pid liveness
            host: host,
            port: port,
            origin: normalized,
            startedAt: "network"
        )
        location = T3RuntimeLocation(fileURL: Self.syntheticFile, state: state)
    }

    var currentOrigin: String? {
        lock.lock(); defer { lock.unlock() }
        return location?.state.origin
    }

    func discover() throws -> T3RuntimeLocation? {
        lock.lock(); defer { lock.unlock() }
        return location
    }
}

// MARK: - Pin toggle debounce (ported from the bridge)

/// Debounces PIN edges so a BLE/touch double-fire can't immediately toggle a pin
/// twice. Mirrors `PinToggleGate` in the Mac bridge.
final class T3PinToggleGate {
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

// MARK: - Direct controller (ported from the bridge's T3Controller)

/// Owns one `T3Backend` configured for a networked (LAN) T3 server and turns its
/// snapshots into the `workspace-state` dictionary the peripheral applies for
/// the `t3code` surface, and macropad events into backend calls. Runs entirely
/// on the main actor; the backend's own callbacks land on `.main`.
@MainActor
final class T3DirectController {
    private let backend: T3Backend
    private let discovery: T3NetworkRuntimeDiscovery
    private let pinToggleGate = T3PinToggleGate()
    private var latest: T3BackendSnapshot?
    private var started = false
    /// One-time-per-activation guard so the board seeds its pins from the live
    /// threads exactly once, then leaves them sticky (pinned, not most-recent).
    private var bootstrappedPins = false
    /// The last workspace-state we pushed. The backend re-emits a snapshot every
    /// poll tick (~1s) even when nothing changed; without this guard each tick
    /// reassigns the peripheral's @Published state and re-renders the settings
    /// sheet, making it lag and jump. We only push when the payload differs.
    private var lastPublishSignature: Data?
    /// Completion version acknowledged by opening each target. A completed
    /// target stays white after it has been checked and turns green again only
    /// when a newer completion arrives.
    private var acknowledgedCompletionByTarget: [String: String] = [:]

    private static let originDefaultsKey = "codexMicro.t3.origin"

    /// Called on the main actor with a fresh `workspace-state` dict whenever the
    /// backend publishes. The peripheral wires this to `applyWorkspaceState`.
    var onWorkspaceState: (([String: Any]) -> Void)?
    /// Called on the main actor with a human-readable line when the T3 connection
    /// phase changes. The peripheral routes this into its Protocol log.
    var onLog: ((String) -> Void)?
    private var lastLoggedPhase: T3ConnectionPhase?

    init() {
        let config = T3Backend.Configuration(allowNonLoopbackPairingOrigins: true)
        let discovery = T3NetworkRuntimeDiscovery()
        self.discovery = discovery
        self.backend = T3Backend(configuration: config, runtimeDiscovery: discovery)

        // Restore a previously paired origin so the app reconnects on launch
        // (the bearer itself already lives in the Keychain).
        if let saved = UserDefaults.standard.string(forKey: Self.originDefaultsKey),
           let url = URL(string: saved) {
            discovery.setOrigin(url)
        }

        backend.setUpdateHandler { [weak self] snapshot in
            // callbackQueue is `.main`, so this executes on the main thread.
            MainActor.assumeIsolated { self?.ingest(snapshot) }
        }
    }

    /// True once the user has paired to a server (an origin is stored).
    var isPaired: Bool { discovery.currentOrigin != nil }

    // MARK: Lifecycle

    /// Called when the user switches to the T3 page. Lazily starts polling the
    /// first time and refreshes on later switches, then republishes immediately.
    func activate() {
        bootstrappedPins = false
        lastPublishSignature = nil
        if !started {
            started = true
            backend.start()
        } else {
            backend.refreshNow()
        }
        publish()
    }

    /// Called when the user leaves the T3 page or the app backgrounds. Stops the
    /// poll loop to save battery/network; the paired credential is untouched.
    func deactivate() {
        guard started else { return }
        started = false
        lastPublishSignature = nil
        backend.stop()
    }

    func refresh() {
        if started { backend.refreshNow() }
        publish()
    }

    // MARK: Pairing

    /// Pair to a T3 server from a `…/pair#token=…` (or host+code) link. On
    /// success the origin is stored and polling begins.
    func pair(pairingURL: String, completion: @escaping @Sendable (Result<T3Environment, T3BackendIssue>) -> Void) {
        let origin: URL?
        if let target = try? T3PairingURLParser.parse(pairingURL) {
            origin = target.origin
        } else {
            origin = nil
        }
        // Point discovery at the paired origin up front so polling can begin the
        // moment the token exchange succeeds.
        if let origin { discovery.setOrigin(origin) }

        backend.pair(pairingURL: pairingURL) { [weak self] result in
            // Runs on `.main`.
            MainActor.assumeIsolated {
                guard let self else { completion(result); return }
                switch result {
                case .success:
                    if let normalized = self.discovery.currentOrigin {
                        UserDefaults.standard.set(normalized, forKey: Self.originDefaultsKey)
                    }
                    // Ensure the poll loop is running post-pair.
                    if !self.started {
                        self.started = true
                        self.backend.start()
                    } else {
                        self.backend.refreshNow()
                    }
                case .failure:
                    break
                }
                completion(result)
            }
        }
    }

    /// Forget the paired server (clears the stored origin; the poll loop stops on
    /// the next page switch). The Keychain bearer is left in place.
    func unpair() {
        discovery.setOrigin(nil)
        UserDefaults.standard.removeObject(forKey: Self.originDefaultsKey)
        latest = nil
        lastPublishSignature = nil
        acknowledgedCompletionByTarget.removeAll()
        publish()
    }

    // MARK: Macropad events (t3code surface only)

    /// An agent-key press focuses the pinned thread in that slot.
    func handleKey(_ key: String, action: Int, agent: Int?) {
        guard key.hasPrefix("AG"), action == 1 else { return }
        let idx = agent ?? Int(key.dropFirst(2)) ?? -1
        guard let snapshot = latest,
              snapshot.pins.slots.indices.contains(idx),
              let id = snapshot.pins.slots[idx] else { return }
        backend.select(targetID: id)
    }

    /// PIN/UNPIN the exact thread the board shows selected.
    func togglePin(targetID: String?) {
        guard pinToggleGate.accept() else { return }
        let requested = targetID.flatMap { $0.isEmpty ? nil : $0 }
        guard let id = requested ?? latest?.pins.selectedTargetID else { return }
        backend.togglePin(targetID: id)
    }

    /// Send a prompt/turn — from the NEW launcher or from dictated/typed text.
    func sendPrompt(_ text: String, to targetID: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let target = targetID.flatMap { $0.isEmpty ? nil : $0 }
        backend.sendPrompt(trimmed, to: target) { _ in }
    }

    // MARK: Snapshot → workspace-state dict

    private func ingest(_ snapshot: T3BackendSnapshot) {
        if let selected = snapshot.pins.selectedTargetID,
           let target = snapshot.targets.first(where: { $0.id == selected }),
           target.status == .done {
            acknowledgedCompletionByTarget[selected] = target.updatedAt
        }
        for target in snapshot.targets where target.status == .working {
            acknowledgedCompletionByTarget[target.id] = nil
        }
        latest = snapshot
        // Surface phase changes in the app's Protocol log so a disconnect is
        // diagnosable. T3Backend already retries with backoff on its own, so we
        // deliberately do NOT stop the poll loop here — that made transient
        // hiccups (or an app relaunch) stick at "Waiting" instead of recovering.
        if snapshot.phase != lastLoggedPhase {
            lastLoggedPhase = snapshot.phase
            let issueText = snapshot.issue?.message
            let detail = issueText != nil ? ": \(issueText!)" : ""
            onLog?("T3 \(snapshot.phase.rawValue)\(detail)")
        }
        maybeBootstrapPins(snapshot)
        publish()
    }

    /// First time we see a connected server with threads but a completely empty
    /// pin layout, assign the current threads to the six agent keys as real,
    /// persisted pins. This makes the board usable immediately; because they are
    /// pins (not a live "most recent" list) a key keeps its thread even as other
    /// threads update. Runs at most once per activation and never overwrites
    /// existing pins, so the user's manual PIN/UNPIN choices are preserved.
    private func maybeBootstrapPins(_ snapshot: T3BackendSnapshot) {
        guard !bootstrappedPins,
              snapshot.phase == .connected,
              !snapshot.targets.isEmpty,
              snapshot.pins.slots.allSatisfy({ $0 == nil }) else { return }
        bootstrappedPins = true
        for (index, target) in snapshot.targets.prefix(T3PinLayout.slotCount).enumerated() {
            backend.togglePin(targetID: target.id, preferredSlot: index)
        }
    }

    private func normalizedPins(_ slots: [String?]) -> [String?] {
        var next = Array<String?>(repeating: nil, count: 6)
        for (index, value) in slots.prefix(6).enumerated() { next[index] = value }
        return next
    }

    private func publish() {
        let snapshot = latest
        let targets = snapshot?.targets ?? []
        let selected = snapshot?.pins.selectedTargetID
        let pins = normalizedPins(snapshot?.pins.slots ?? [])
        let connected = (snapshot?.phase == .connected)
        let issue = snapshot?.issue?.message

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

        var dict: [String: Any] = [
            "type": "workspace-state",
            "surface": "t3code",
            "connected": connected,
            "targets": targetDicts,
            "pins": pins.map { $0 ?? "" },
            "slots": slots,
        ]
        if let selected { dict["selected"] = selected }
        if let issue { dict["issue"] = issue }

        // Skip no-op republishes so a steady connection doesn't churn the UI.
        if let signature = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) {
            if signature == lastPublishSignature { return }
            lastPublishSignature = signature
        }
        onWorkspaceState?(dict)
    }

    private func buildSlots(pins: [String?], selected: String?, targets: [T3Target]) -> [[String: Any]] {
        (0..<6).map { key in
            guard let id = pins[key], let target = targets.first(where: { $0.id == id }) else {
                return ["id": key, "c": 0, "b": 0, "e": 0, "s": 0, "status": "off"]
            }
            let status = Self.statusName(target.status)
            let completionWasRead =
                status == "complete" && acknowledgedCompletionByTarget[id] == target.updatedAt
            // Breathing is reserved for the one case that means "this chat,
            // right now": the selected key while it is blue (working).
            // Everything else stays solid, including a working chat you are
            // not in and the selected-but-idle key.
            if id == selected {
                let isWorking = status == "working"
                let selectedColor = completionWasRead || status == "idle"
                    ? 0xFFFFFF
                    : (Self.statusColors[status]?.0 ?? 0xFFFFFF)
                return [
                    "id": key,
                    "c": selectedColor,
                    "b": 1,
                    "e": isWorking ? 4 : 1,
                    "s": isWorking ? 0.4 : 0,
                    "status": completionWasRead ? "selected" : status,
                ]
            }
            if completionWasRead {
                return ["id": key, "c": 0xFFFFFF, "b": 1, "e": 1, "s": 0, "status": "idle"]
            }
            if let color = Self.statusColors[status] {
                return ["id": key, "c": color.0, "b": 1, "e": 1, "s": 0, "status": status]
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

    /// status -> (packed 0xRRGGBB, effect id, effect speed), matching the Mac
    /// bridge's `StatusLights.map` so the T3 LEDs look identical to the other
    /// surfaces. Effects: 1 solid, 4 breath.
    private static let statusColors: [String: (Int, Int, Double)] = [
        "idle": (0xFFFFFF, 1, 0.0),
        "working": (0x304FFE, 4, 0.4),
        "complete": (0x00FF4C, 1, 0.0),
        "needs_input": (0xFF8F00, 4, 0.4),
        "error": (0xFF0033, 1, 0.0),
    ]
}
