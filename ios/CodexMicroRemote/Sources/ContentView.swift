//
//  ContentView.swift
//  CodexMicroRemote
//
//  A responsive, touch-first recreation of the Work Louder Codex Micro.
//

import SwiftUI
import UIKit

extension Color {
    /// Packed 0xRRGGBB as sent by the host in `v.oai.thstatus`.
    init(packedRGB: UInt32) {
        self.init(
            red: Double((packedRGB >> 16) & 0xFF) / 255,
            green: Double((packedRGB >> 8) & 0xFF) / 255,
            blue: Double(packedRGB & 0xFF) / 255
        )
    }
}

/// Persistent presentation choice for the control surface. The framed mode
/// preserves the physical Codex Micro recreation; maximized removes the
/// enclosure so the same 4×4 control map can consume almost the full width.
private enum ControlSurfaceMode: String, CaseIterable, Identifiable {
    case framed
    case maximized

    var id: String { rawValue }

    var title: String {
        switch self {
        case .framed: return "Framed"
        case .maximized: return "Maximized"
        }
    }

    var detail: String {
        switch self {
        case .framed: return "Physical enclosure, fasteners, and engraved legends."
        case .maximized: return "No enclosure; controls expand nearly edge-to-edge."
        }
    }
}

/// Which microphone the Codex page's MIC key dictates from. `computer` keeps
/// ChatGPT's own push-to-talk against the Mac's default input (the default and
/// prior behavior). `iphone` records + transcribes on this iPhone and types the
/// transcript into ChatGPT's composer, so you can speak into the phone you are
/// holding instead of the Mac's far-field microphone.
enum CodexMicSource: String, CaseIterable, Identifiable {
    case computer
    case iphone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .computer: return "Computer microphone"
        case .iphone: return "This iPhone"
        }
    }

    var detail: String {
        switch self {
        case .computer:
            return "ChatGPT records from the Mac's current input device (default)."
        case .iphone:
            return "Record and transcribe on this iPhone, then type it into Codex."
        }
    }
}

/// A stable, persisted identity for each isolated desktop control surface.
/// Keep the raw values fixed: `codexMicro.controlPage` stores them directly.
/// The host target is intentionally part of this pure model so routing can be
/// unit-tested without constructing a SwiftUI view.
enum ControlPage: Int, CaseIterable, Identifiable {
    case codex = 0
    case vscode = 1
    case t3Code = 2
    case claudeCode = 3

    var id: Int { rawValue }

    /// Pages actually shown in the swipe/dots. The T3 Code page is a first-class
    /// isolated surface that talks straight to the open-source T3 server over the
    /// LAN (no Mac bridge). VS Code remains implemented but parked.
    static let displayed: [ControlPage] = [.codex, .claudeCode, .t3Code]
    var isDisplayed: Bool { ControlPage.displayed.contains(self) }

    var title: String {
        switch self {
        case .codex: return "CODEX MICRO"
        case .vscode: return "VS CODE MICRO"
        case .t3Code: return "T3 CODE MICRO"
        case .claudeCode: return "CLAUDE DESKTOP"
        }
    }

    var surfaceName: String {
        switch self {
        case .codex: return "Codex"
        case .vscode: return "VS Code"
        case .t3Code: return "T3 Code"
        case .claudeCode: return "Claude Desktop"
        }
    }

    var hostTarget: String {
        switch self {
        case .codex: return "chatgpt"
        case .vscode: return "vscode"
        case .t3Code: return "t3code"
        case .claudeCode: return "claude-desktop"
        }
    }

    var usesWorkspaceBridge: Bool { self != .codex }

    /// Visual identity only. Connection/status colours still come from the
    /// semantic host state; these restrained accents distinguish swipe pages.
    var accentRGB: UInt32 {
        switch self {
        case .codex: return 0x74777A
        case .vscode: return 0x007ACC
        case .t3Code: return 0x4B4D52
        case .claudeCode: return 0xA9532F
        }
    }
}

/// New-session actions are grouped by surface, while each surface persists a
/// separate selection and custom value. This prevents changing T3 Code setup
/// from silently changing what NEW does on VS Code or Claude Code.
enum WorkspaceLauncher: String, CaseIterable, Identifiable {
    case claudeExtension, codexExtension, chatgptExtension, kimiExtension
    case claudeTerminal, codexTerminal, kimiTerminal
    case customCommand, customTerminal
    case t3NewSession, t3Open, t3CustomCommand
    case claudeNewSession, claudeCodeTab, claudeCustomLink

    var id: String { rawValue }

    var page: ControlPage {
        switch self {
        case .t3NewSession, .t3Open, .t3CustomCommand: return .t3Code
        case .claudeNewSession, .claudeCodeTab, .claudeCustomLink: return .claudeCode
        default: return .vscode
        }
    }

    static func options(for page: ControlPage) -> [WorkspaceLauncher] {
        allCases.filter { $0.page == page }
    }

    static func defaultLauncher(for page: ControlPage) -> WorkspaceLauncher {
        switch page {
        case .codex, .vscode: return .claudeExtension
        case .t3Code: return .t3NewSession
        case .claudeCode: return .claudeNewSession
        }
    }

    var title: String {
        switch self {
        case .claudeExtension: return "Claude Code extension"
        case .codexExtension: return "New Codex agent"
        case .chatgptExtension: return "ChatGPT sidebar chat"
        case .kimiExtension: return "Kimi Code extension"
        case .claudeTerminal: return "Claude terminal"
        case .codexTerminal: return "Codex terminal"
        case .kimiTerminal: return "Kimi terminal"
        case .customCommand: return "Custom VS Code command"
        case .customTerminal: return "Custom terminal command"
        case .t3NewSession: return "New T3 Code session"
        case .t3Open: return "Open T3 Code"
        case .t3CustomCommand: return "Custom T3 Code command"
        case .claudeNewSession: return "New Claude Desktop session"
        case .claudeCodeTab: return "Open Claude Desktop Code"
        case .claudeCustomLink: return "Custom Claude Desktop link"
        }
    }

    var kind: String {
        switch self {
        case .claudeTerminal, .codexTerminal, .kimiTerminal, .customTerminal: return "terminal"
        case .t3NewSession, .t3Open: return "t3code"
        case .t3CustomCommand: return "command"
        case .claudeNewSession, .claudeCodeTab, .claudeCustomLink: return "deeplink"
        default: return "command"
        }
    }

    var value: String {
        switch self {
        case .claudeExtension: return "claude-vscode.newConversation"
        case .codexExtension: return "chatgpt.newCodexPanel"
        case .chatgptExtension: return "chatgpt.newChat"
        case .kimiExtension: return "kimi.newConversation"
        case .claudeTerminal: return "claude"
        case .codexTerminal: return "codex"
        case .kimiTerminal: return "kimi"
        case .t3NewSession: return "new"
        case .t3Open: return "open"
        case .claudeNewSession: return "claude://code/new"
        case .claudeCodeTab: return "claude://code"
        case .customCommand, .customTerminal, .t3CustomCommand, .claudeCustomLink: return ""
        }
    }

    var requiresCustomValue: Bool { value.isEmpty }

    var customValuePlaceholder: String {
        switch self {
        case .customTerminal: return "Shell command"
        case .claudeCustomLink: return "claude://code/…"
        default: return "Command ID"
        }
    }
}

/// Reports physical-style press and release events instead of a single tap.
private struct PressableKey<Label: View>: View {
    let onChange: (Bool) -> Void
    @ViewBuilder let label: (Bool) -> Label

    @State private var isPressed = false

    var body: some View {
        label(isPressed)
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: .infinity, maximumDistance: .infinity) {
                setPressed(false)
            } onPressingChanged: { pressing in
                setPressed(pressing)
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                onChange(true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    onChange(false)
                }
            }
            .onDisappear {
                if isPressed {
                    isPressed = false
                    onChange(false)
                }
            }
    }

    private func setPressed(_ pressing: Bool) {
        guard isPressed != pressing else { return }
        isPressed = pressing
        onChange(pressing)
    }
}

/// Reaches into the paging TabView's backing UIScrollView and stops it from
/// withholding touch-down from the keys. `UIScrollView.appearance()` does not
/// reliably reach a SwiftUI-owned paging scroller, so this walks the live view
/// tree and sets it on the actual instance. Without this the scroller delays
/// every press while it decides whether the gesture is a page swipe, so keys
/// neither light up nor fire on a normal tap.
private struct ScrollTouchDelayDisabler: UIViewRepresentable {
    final class FinderView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            var ancestor = superview
            while let current = ancestor {
                if let scrollView = current as? UIScrollView {
                    scrollView.delaysContentTouches = false
                    break
                }
                ancestor = current.superview
            }
        }
    }

    func makeUIView(context: Context) -> FinderView {
        let view = FinderView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: FinderView, context: Context) {}
}

struct ContentView: View {
    @EnvironmentObject private var peripheral: CodexMicroPeripheral
    @AppStorage("codexMicro.controlSurfaceMode") private var surfaceModeRaw = ControlSurfaceMode.framed.rawValue
    @AppStorage("codexMicro.controlPage") private var pageRaw = ControlPage.codex.rawValue
    @AppStorage("codexMicro.vscodeLauncher") private var vscodeLauncherRaw = WorkspaceLauncher.claudeExtension.rawValue
    @AppStorage("codexMicro.vscodeCustomCommand") private var vscodeCustomLauncherValue = ""
    @AppStorage("codexMicro.t3CodeLauncher") private var t3CodeLauncherRaw = WorkspaceLauncher.t3NewSession.rawValue
    @AppStorage("codexMicro.t3CodeCustomCommand") private var t3CodeCustomLauncherValue = ""
    @AppStorage("codexMicro.claudeCodeLauncher") private var claudeCodeLauncherRaw = WorkspaceLauncher.claudeNewSession.rawValue
    @AppStorage("codexMicro.claudeCodeCustomLink") private var claudeCodeCustomLauncherValue = ""
    @AppStorage("codexMicro.voiceAutoSend") private var voiceAutoSend = false
    @AppStorage("codexMicro.useMacProviderVoice") private var useMacProviderVoice = false
    @AppStorage("codexMicro.codexMicSource") private var codexMicSourceRaw = CodexMicSource.computer.rawValue
    @State private var isShowingDetails = false
    @StateObject private var voiceRecorder = VoicePromptRecorder()

    private var codexMicSource: CodexMicSource {
        CodexMicSource(rawValue: codexMicSourceRaw) ?? .computer
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ControllerBackdrop(page: selectedPage, ambientColor: ambientColor)
                    .ignoresSafeArea()

                VStack(spacing: contentSpacing(for: geometry.size)) {
                    statusBar

                    GeometryReader { boardSpace in
                        // PageTabViewStyle supplies the system UIPageControl.
                        // Keep a small clear zone beneath the square controller
                        // so the native indicator never overlays the bottom row.
                        let indicatorClearance: CGFloat = 30
                        let side = min(
                            boardSpace.size.width,
                            max(1, boardSpace.size.height - indicatorClearance)
                        )

                        TabView(selection: pageBinding) {
                            ForEach(ControlPage.displayed) { page in
                                console(page: page, side: side)
                                    .padding(.bottom, indicatorClearance)
                                    .tag(page)
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .always))
                        .indexViewStyle(.page(backgroundDisplayMode: .always))
                        .frame(width: boardSpace.size.width, height: boardSpace.size.height)
                    }
                }
                .padding(.horizontal, horizontalPadding(for: geometry.size.width))
                .padding(.vertical, surfaceMode == .maximized ? 2 : 8)
            }
        }
        .tint(Color(packedRGB: selectedPage.accentRGB))
        // Both visible surfaces deliberately use medium-dark solid fields;
        // pin the chrome to dark appearance so header/status contrast does not
        // depend on the iPhone's global light/dark setting.
        .preferredColorScheme(.dark)
        .sheet(isPresented: $isShowingDetails) {
            DeviceDetailsSheet(page: selectedPage)
                .environmentObject(peripheral)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onAppear { peripheral.setControlTarget(selectedPage.hostTarget) }
        .onChange(of: pageRaw) { _, _ in peripheral.setControlTarget(selectedPage.hostTarget) }
    }

    private func console(page: ControlPage, side: CGFloat) -> some View {
        HardwareConsole(
            mode: surfaceMode,
            page: page,
            voiceRecorder: voiceRecorder,
            autoSendVoicePrompts: voiceAutoSend,
            useMacProviderVoice: useMacProviderVoice,
            codexMicSource: codexMicSource,
            workspaceLauncher: selectedLauncher(for: page),
            customLauncherValue: customLauncherValue(for: page),
            openConnectionDetails: { isShowingDetails = true }
        )
        .id("\(page.rawValue)-\(peripheral.foregroundRenderGeneration)")
        .dynamicTypeSize(.xSmall ... .large)
        .frame(width: side, height: side)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Sits inside the paging scroll content so it can reach the scroller and
        // stop it swallowing key press-downs.
        .background(ScrollTouchDelayDisabler())
    }

    private var ambientColor: Color {
        peripheral.ambient.color == 0
            ? Color(packedRGB: 0x57E89B)
            : Color(packedRGB: peripheral.ambient.color)
    }

    private var surfaceMode: ControlSurfaceMode {
        ControlSurfaceMode(rawValue: surfaceModeRaw) ?? .framed
    }

    private var selectedPage: ControlPage {
        let page = ControlPage(rawValue: pageRaw) ?? .codex
        // Never resolve to a hidden page (e.g. a persisted T3 selection).
        return page.isDisplayed ? page : .codex
    }

    private var pageBinding: Binding<ControlPage> {
        Binding(get: { selectedPage }, set: { pageRaw = $0.rawValue })
    }

    private func selectedLauncher(for page: ControlPage) -> WorkspaceLauncher {
        let rawValue: String
        switch page {
        case .codex, .vscode: rawValue = vscodeLauncherRaw
        case .t3Code: rawValue = t3CodeLauncherRaw
        case .claudeCode: rawValue = claudeCodeLauncherRaw
        }
        if let candidate = WorkspaceLauncher(rawValue: rawValue), candidate.page == page {
            return candidate
        }
        return WorkspaceLauncher.defaultLauncher(for: page)
    }

    private func customLauncherValue(for page: ControlPage) -> String {
        switch page {
        case .codex, .vscode: return vscodeCustomLauncherValue
        case .t3Code: return t3CodeCustomLauncherValue
        case .claudeCode: return claudeCodeCustomLauncherValue
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(selectedPage.title)
                    .font(.headline.weight(.bold))
                    .tracking(-0.25)
                    .lineLimit(1)

                Text(statusSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .layoutPriority(1)

            Spacer(minLength: 2)

            Button {
                isShowingDetails = true
            } label: {
                ViewThatFits(in: .horizontal) {
                    Label(connectionStatus.title, systemImage: connectionStatus.symbol)
                    Image(systemName: connectionStatus.symbol)
                        .accessibilityLabel(connectionStatus.title)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(connectionStatus.color)
                .lineLimit(1)
                .padding(.horizontal, 11)
                .frame(minWidth: 44, minHeight: 44)
                .background(connectionStatus.color.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows Bluetooth connection details")

            if (selectedPage == .codex && peripheral.canControlChatGPT)
                || (selectedPage == .claudeCode && peripheral.hostConnected) {
                Button {
                    if selectedPage == .codex {
                        peripheral.clearComposer()
                    } else {
                        peripheral.clearWorkspaceComposer(surface: selectedPage.hostTarget)
                    }
                } label: {
                    Image(systemName: "delete.left")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .background(.thinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    selectedPage == .codex
                        ? "Clear the ChatGPT message box"
                        : "Clear the Claude message box"
                )
                .accessibilityHint("Clears all text in the current composer")
            }

            Button {
                isShowingDetails = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(.thinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Setup and diagnostics")
        }
        .frame(minHeight: 44)
        // Keep the persistent controls compact enough to preserve 44 pt targets
        // in landscape; the scrollable details sheet honors the full size range.
        .dynamicTypeSize(.xSmall ... .large)
    }

    private var statusSubtitle: String {
        if let issue = peripheral.blockingIssue, !issue.isEmpty {
            return "Bluetooth issue"
        }
        if selectedPage == .codex {
            return peripheral.macConnectionDetail
        }
        if peripheral.hostConnected {
            if selectedPage.usesWorkspaceBridge {
                let state = peripheral.workspaceState(for: selectedPage.hostTarget)
                if !state.connected {
                    return "Mac linked · waiting for \(selectedPage.surfaceName)"
                }
                if let issue = state.issue, !issue.isEmpty { return issue }
                if let target = state.targets.first(where: { $0.id == state.selectedTargetID }) {
                    return "Selected · \(target.label)"
                }
                return "\(selectedPage.surfaceName) connected · choose a session"
            }
            if let focusedApp = peripheral.focusedApp, !focusedApp.isEmpty {
                return "Connected · \(focusedApp)"
            }
            return "Connected to your Mac"
        }
        if peripheral.bridgeMode, peripheral.isAdvertising {
            return "Waiting for the Mac helper"
        }
        return "iPhone control surface"
    }

    private var connectionStatus: (title: String, symbol: String, color: Color) {
        if peripheral.blockingIssue != nil {
            return ("Needs attention", "exclamationmark.triangle.fill", .red)
        }
        if selectedPage == .codex {
            switch peripheral.macConnectionState {
            case .operational:
                return ("Fully connected", "checkmark.circle.fill", Color(packedRGB: 0x168A55))
            case .handshaking:
                return ("Checking ChatGPT", "arrow.triangle.2.circlepath.circle.fill", .yellow)
            case .waitingForChatGPT:
                return ("Waiting for ChatGPT", "hourglass.circle.fill", .orange)
            case .transportConnected:
                return ("Mac linked", "link.circle.fill", .blue)
            case .recovering:
                return ("Reconnecting", "arrow.clockwise.circle.fill", .orange)
            case .waitingForMac:
                return ("Waiting for Mac", "dot.radiowaves.left.and.right", .blue)
            case .starting:
                return ("Starting", "ellipsis.circle.fill", .secondary)
            case .error:
                return ("Needs attention", "exclamationmark.triangle.fill", .red)
            }
        }
        if selectedPage.usesWorkspaceBridge, peripheral.hostConnected {
            let state = peripheral.workspaceState(for: selectedPage.hostTarget)
            return state.connected
                ? ("\(selectedPage.surfaceName) connected", "checkmark.circle.fill", Color(packedRGB: 0x168A55))
                : ("Mac linked", "link.circle.fill", .blue)
        }
        if peripheral.hostConnected {
            return ("Mac linked", "link.circle.fill", .blue)
        }
        if peripheral.managerState != .poweredOn {
            return ("Bluetooth off", "antenna.radiowaves.left.and.right.slash", .orange)
        }
        if !peripheral.publishedServicesReady {
            return ("Starting", "ellipsis.circle.fill", .secondary)
        }
        if peripheral.isAdvertising {
            return peripheral.bridgeMode
                ? ("Waiting for Mac helper", "dot.radiowaves.left.and.right", .blue)
                : ("Ready to pair", "dot.radiowaves.left.and.right", .blue)
        }
        return ("Ready", "checkmark.circle.fill", Color(packedRGB: 0x168A55))
    }

    private func horizontalPadding(for width: CGFloat) -> CGFloat {
        // The safe area already protects the rounded display corners. Keep a
        // narrow breathing edge in framed mode and let maximized controls come
        // within two points of the usable screen edge.
        surfaceMode == .maximized ? 2 : min(6, max(4, width * 0.012))
    }

    private func contentSpacing(for size: CGSize) -> CGFloat {
        size.height < 430 ? 5 : 10
    }
}

// MARK: - Hardware face

private struct ControllerBackdrop: View {
    let page: ControlPage
    let ambientColor: Color

    var body: some View {
        switch page {
        case .claudeCode:
            // Very dark burnt orange: distinct from Codex while staying quiet
            // behind the bright physical controls and semantic key lighting.
            Color(red: 0.28, green: 0.12, blue: 0.07)
        default:
            // Near-black graphite with just enough lift to retain the enclosure
            // silhouette without reading as a fully black void.
            Color(red: 0.10, green: 0.11, blue: 0.12)
        }
    }
}

private struct HardwareConsole: View {
    @EnvironmentObject private var peripheral: CodexMicroPeripheral
    let mode: ControlSurfaceMode
    let page: ControlPage
    @ObservedObject var voiceRecorder: VoicePromptRecorder
    let autoSendVoicePrompts: Bool
    let useMacProviderVoice: Bool
    let codexMicSource: CodexMicSource
    let workspaceLauncher: WorkspaceLauncher
    let customLauncherValue: String
    let openConnectionDetails: () -> Void

    /// Set while hands-free voice recording is latched — lights the whole
    /// case shell and engraved legends in the recording color.
    @State private var caseHighlight: Color? = nil

    private var workspaceState: WorkspaceBridgeState {
        peripheral.workspaceState(for: page.hostTarget)
    }

    private var selectedWorkspaceTarget: VSCodeTarget? {
        guard let id = workspaceState.selectedTargetID else { return nil }
        return workspaceState.targets.first(where: { $0.id == id })
    }

    private var effectiveWorkspacePins: [String?] { workspaceState.pins }

    private var effectiveWorkspaceTargets: [VSCodeTarget] { workspaceState.targets }

    private var effectiveSelectedTargetID: String? { workspaceState.selectedTargetID }
    /// Active voice colour. Rather than drawing a new outline over the board,
    /// this makes the existing passive casing light travel around its own edge.
    @State private var casingSnake: Color? = nil
    /// Local confirmation for encoder navigation/adjustment. Every dial step
    /// refreshes this green perimeter pulse, so it remains visible while a
    /// project, model, reasoning level, or any other composer control changes.
    @State private var dialPulseStrength = 0.0
    @State private var dialPulseTask: Task<Void, Never>?
    /// Bumped each time CODEX (send) is pressed, so the microphone can retire
    /// its "processing" snake exactly when the prompt is submitted — rather
    /// than guessing a duration and finishing before the text materializes.
    @State private var codexSendTick = 0
    /// Immediate local selection/submit feedback. ChatGPT remains the
    /// authoritative status source, but its lighting notification can trail a
    /// tap by a perceptible amount. Keeping this tiny optimistic layer prevents
    /// a just-opened unread chat from continuing to look green and prevents a
    /// submitted prompt from looking complete until the host's blue update
    /// arrives.
    @State private var localCodexSelection: Int?
    /// A key tap is authoritative immediately. ChatGPT can briefly replay the
    /// previous selected slot before its navigation update arrives; do not let
    /// that stale packet resurrect a green unread check on the chat just opened.
    @State private var pendingLocalCodexSelection = false
    @State private var codexSelectionReconciliationTask: Task<Void, Never>?
    @State private var optimisticCodexWorking: Int?
    @State private var optimisticCodexWorkingTask: Task<Void, Never>?
    /// Per-agent-key timestamp of the last press, used to detect a double-tap on
    /// a workspace agent key. A double-tap raises the owning desktop editor app
    /// to the front (macOS activation), not just focuses the tab inside it.
    @State private var lastWorkspaceAgentTapAt: [Int: Date] = [:]
    /// Claude's analog stick is intentionally reduced to one cardinal action
    /// per deflection. It must return to centre before another action can fire,
    /// so a slightly wandering thumb cannot toggle several desktop panes.
    @State private var activeClaudeJoystickDirection: Int?
    private let workspaceDoubleTapWindow: TimeInterval = 0.45

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let isMaximized = mode == .maximized
            let gap = isMaximized ? max(3, side * 0.010) : max(4, side * 0.016)
            let controlInset = isMaximized
                ? max(1, side * 0.006)
                : min(side * 0.15, max(12, (side - 188) / 2))
            let gridSide = side - (controlInset * 2)
            let keySide = max(1, (gridSide - (gap * 3)) / 4)

            ZStack {
                if !isMaximized {
                    shell(side: side)

                    if side > 285 {
                        caseInscriptions(side: side)
                    }

                    screws(side: side)
                }

                VStack(spacing: gap) {
                    HStack(spacing: gap) {
                        RotaryControl(
                            onStep: { clockwise in
                                pulseDialPerimeter()
                                // Clockwise always means "more": Codex raises
                                // reasoning effort and Claude Desktop advances
                                // Low → Medium → High → Extra high → Max.
                                routeKey(clockwise ? "ENC_CC" : "ENC_CW", action: 2)
                            },
                            onPress: { pressing in
                                if pressing { pulseDialPerimeter() }
                                routeKey("ENC", action: pressing ? 1 : 0)
                            }
                        )
                        .frame(width: keySide, height: keySide)

                        agentKey(0, side: keySide)
                        agentKey(1, side: keySide)

                        JoystickControl { angle, distance in
                            if page == .codex {
                                peripheral.sendJoystick(angle: angle, distance: distance)
                            } else if page == .claudeCode {
                                routeClaudeJoystick(angle: angle, distance: distance)
                            }
                        }
                        .frame(width: keySide, height: keySide)
                    }

                    HStack(spacing: gap) {
                        agentKey(2, side: keySide)
                        agentKey(3, side: keySide)
                        agentKey(4, side: keySide)
                        agentKey(5, side: keySide)
                    }

                    HStack(spacing: gap) {
                        if page == .codex {
                            commandKey("ACT06", side: keySide)
                            commandKey("ACT07", side: keySide)
                            commandKey("ACT08", side: keySide)
                            commandKey("ACT09", side: keySide)
                        } else if page == .claudeCode {
                            workspaceBlankKey(side: keySide)
                            workspaceNewKey(side: keySide)
                            workspacePinKey(side: keySide)
                            workspaceActionKey(
                                "FORK",
                                symbol: "arrow.triangle.branch",
                                accent: Color(packedRGB: page.accentRGB),
                                side: keySide
                            ) {
                                sendKey("ACT09", pressing: $0)
                            }
                        } else {
                            workspaceNewKey(side: keySide)
                            workspaceActionKey("APPR", symbol: "checkmark", accent: Color(packedRGB: 0x168A55), side: keySide) {
                                sendKey("ACT07", pressing: $0)
                            }
                            workspaceActionKey("REJ", symbol: "xmark", accent: Color(packedRGB: 0xCC334F), side: keySide) {
                                sendKey("ACT08", pressing: $0)
                            }
                            workspacePinKey(side: keySide)
                        }
                    }

                    HStack(spacing: gap) {
                        TouchSensor(openConnectionDetails: openConnectionDetails)
                            .frame(width: keySide, height: keySide)

                        if page == .codex {
                            twoUpKey(side: keySide, gap: gap)
                        } else {
                            VSCodeVoiceKey(
                                recorder: voiceRecorder,
                                surfaceName: page.surfaceName,
                                targetID: effectiveSelectedTargetID,
                                autoSend: page == .claudeCode ? false : autoSendVoicePrompts,
                                opensExternalPrefill: false,
                                // Claude Desktop owns transcription on its page:
                                // the bridge activates the app and invokes its
                                // native Command-D dictation toggle. The VS Code
                                // surface retains its provider-advertised route.
                                usesNativeVoice: page == .claudeCode
                                    || (page == .vscode
                                        && selectedWorkspaceTarget?.nativeVoice == true
                                        && !autoSendVoicePrompts),
                                confirmedNativeVoiceActive: page == .claudeCode
                                    ? workspaceState.nativeVoiceActive
                                    : nil,
                                onNativeVoice: { active, targetID in
                                    peripheral.setVSCodeNativeVoice(
                                        active,
                                        targetID: targetID,
                                        surface: page.hostTarget
                                    )
                                }
                            ) { text, targetID, autoSend in
                                peripheral.insertVSCodePrompt(
                                    text,
                                    targetID: targetID,
                                    autoSend: autoSend,
                                    surface: page.hostTarget
                                )
                            }
                            .frame(width: (keySide * 2) + gap, height: keySide)
                        }

                        if page == .codex {
                            commandKey("ACT12", side: keySide)
                        } else if page == .claudeCode {
                            workspaceSendKey(side: keySide)
                        } else {
                            workspaceActionKey(
                                "SEND",
                                symbol: "arrow.up",
                                accent: Color(packedRGB: 0x168A55),
                                side: keySide
                            ) {
                                sendKey("ACT12", pressing: $0)
                            }
                        }
                    }
                }
                .frame(width: gridSide, height: gridSide)
            }
            .frame(width: side, height: side)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(page.surfaceName) control surface")
        }
        .onDisappear {
            dialPulseTask?.cancel()
            dialPulseTask = nil
            optimisticCodexWorkingTask?.cancel()
            optimisticCodexWorkingTask = nil
            optimisticCodexWorking = nil
            activeClaudeJoystickDirection = nil
            codexSelectionReconciliationTask?.cancel()
            codexSelectionReconciliationTask = nil
            pendingLocalCodexSelection = false
        }
        .onChange(of: peripheral.slots) { _, slots in
            // Reconcile the optimistic selection with the host's authoritative
            // slot state on both pages, so the highlight follows selections made
            // outside the app (a chat opened in ChatGPT, an agent focused in VS
            // Code) and retires once the real "selected" light has landed.
            if let hostSelection = hostSelectedSlot() {
                if pendingLocalCodexSelection {
                    if hostSelection == localCodexSelection {
                        finishCodexSelectionReconciliation()
                    }
                } else {
                    localCodexSelection = hostSelection
                }
            }
            if let index = optimisticCodexWorking,
               slots.indices.contains(index),
               slots[index].color == 0x304FFE {
                clearOptimisticCodexWorking()
            }
        }
    }

    private func pulseDialPerimeter() {
        dialPulseTask?.cancel()
        withAnimation(.easeOut(duration: 0.08)) {
            dialPulseStrength = 1
        }
        dialPulseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 420_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.32)) {
                dialPulseStrength = 0
            }
            dialPulseTask = nil
        }
    }

    private var ambientColor: Color {
        peripheral.ambient.color == 0
            ? Color(packedRGB: 0x57E89B)
            : Color(packedRGB: peripheral.ambient.color)
    }

    /// The desktop drives the ambient zone as a snake in the selected
    /// thread's status colour while that thread is working. Voice state takes
    /// priority below, then this restores automatically when voice completes.
    private var hostThreadSnake: Color? {
        guard peripheral.ambient.effect == 2, peripheral.ambient.color != 0 else { return nil }
        // The protocol's thinking blue (#304FFE) is optically violet once it
        // blooms through the translucent shell. Lift it toward a clearer blue
        // while preserving every other host-supplied status colour verbatim.
        let visibleColor: UInt32 = peripheral.ambient.color == 0x304FFE
            ? 0x246BFE
            : peripheral.ambient.color
        return Color(packedRGB: visibleColor)
    }

    @ViewBuilder
    private func shell(side: CGFloat) -> some View {
        let shellCorner = side * 0.102
        let plateCorner = side * 0.055
        let bright = max(0, min(1, peripheral.lightingBrightness ?? 1))
        let activeSnake = casingSnake ?? hostThreadSnake
        let dialGreen = Color(packedRGB: 0x39D98A)
        let dialPulseIsActive = dialPulseStrength > 0.001
        let glowColor = dialPulseIsActive ? dialGreen : (activeSnake ?? caseHighlight ?? ambientColor)
        let casingLightIsActive = dialPulseIsActive || activeSnake != nil || caseHighlight != nil
        // ChatGPT is the sole brightness authority, including while voice
        // lighting temporarily changes the underglow colour/effect. Idle/ready
        // has no perimeter light: white belongs only to the selected Agent Key.
        let glowStrength = casingLightIsActive ? bright : 0

        // A restrained pool of light beneath the enclosure. The acrylic remains
        // neutral; colour appears to travel through its edges instead of turning
        // the whole shell into a saturated slab.
        RoundedRectangle(cornerRadius: shellCorner, style: .continuous)
            .fill(glowColor.opacity(0.12 * glowStrength))
            .frame(width: side * 0.925, height: side * 0.925)
            .offset(y: side * 0.018)
            .shadow(color: glowColor.opacity(0.48 * glowStrength), radius: side * 0.075)
            .shadow(color: glowColor.opacity(0.18 * glowStrength), radius: side * 0.13)

        // Thick translucent outer enclosure.
        RoundedRectangle(cornerRadius: shellCorner, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.88),
                        Color(packedRGB: 0xE9EEED).opacity(0.78),
                        Color(packedRGB: 0xC9D0CF).opacity(0.72)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: shellCorner, style: .continuous)
                    .stroke(Color.white.opacity(0.82), lineWidth: max(1, side * 0.006))
            }
            .overlay {
                CasingEdgeLight(
                    snakeColor: activeSnake,
                    pulseColor: dialGreen,
                    pulseStrength: dialPulseStrength,
                    cornerRadius: shellCorner,
                    brightness: glowStrength
                )
            }
            .frame(width: side * 0.955, height: side * 0.955)
            .shadow(color: .black.opacity(0.23), radius: side * 0.035, y: side * 0.022)

        // Dark recess between the acrylic frame and the aluminium faceplate.
        RoundedRectangle(cornerRadius: side * 0.071, style: .continuous)
            .fill(Color.black.opacity(0.16))
            .frame(width: side * 0.842, height: side * 0.842)
            .offset(y: side * 0.006)

        // Satin aluminium faceplate. Its subtle diagonal value shift supplies
        // depth without the glossy card-like treatment of the previous version.
        RoundedRectangle(cornerRadius: plateCorner, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(packedRGB: 0xF1F3F2),
                        Color(packedRGB: 0xD9DEDD),
                        Color(packedRGB: 0xC9CFCE)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: plateCorner, style: .continuous)
                    .stroke(Color.black.opacity(0.28), lineWidth: max(0.75, side * 0.0025))
            }
            .overlay {
                RoundedRectangle(cornerRadius: max(1, plateCorner - side * 0.008), style: .continuous)
                    .stroke(Color.white.opacity(0.56), lineWidth: 1)
                    .padding(side * 0.008)
            }
            .frame(width: side * 0.80, height: side * 0.80)
            .shadow(color: .black.opacity(0.20), radius: side * 0.011, y: side * 0.008)
    }

    @ViewBuilder
    private func screws(side: CGFloat) -> some View {
        // Pull the hardware inward from the active outer lighting path.
        let offset = side * 0.138
        let positions = [
            CGPoint(x: offset, y: offset),
            CGPoint(x: side - offset, y: offset),
            CGPoint(x: offset, y: side - offset),
            CGPoint(x: side - offset, y: side - offset)
        ]

        ForEach(Array(positions.enumerated()), id: \.offset) { _, point in
            BoardScrew()
                .frame(width: max(10, side * 0.034), height: max(10, side * 0.034))
                .position(point)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func caseInscriptions(side: CGFloat) -> some View {
        // The reference unit prints its legends on the faceplate, just inside
        // the fasteners. Keep idle ink neutral and only energise it for the
        // existing hands-free recording highlight.
        // Shared inset moves both side legends, the top arrow, and the bottom
        // line away from the enclosure light without disturbing their rhythm.
        let printLine = side * 0.128
        let inscriptionFont = Font.system(size: min(8, side * 0.022))
        let highlighted = caseHighlight != nil
        let glowColor = caseHighlight ?? ambientColor
        let ink = highlighted ? glowColor : Color.black.opacity(0.64)
        let glowRadius = max(1.5, side * 0.011)

        Text("WORK LOUDER · OPENAI 2026")
            .font(highlighted ? inscriptionFont.weight(.semibold) : inscriptionFont)
            .foregroundStyle(ink)
            .shadow(color: highlighted ? glowColor.opacity(0.75) : .clear, radius: glowRadius)
            .rotationEffect(.degrees(-90))
            .position(x: printLine, y: side * 0.50)

        Text("You can just build things")
            .font(highlighted ? inscriptionFont.weight(.semibold) : inscriptionFont)
            .foregroundStyle(ink)
            .shadow(color: highlighted ? glowColor.opacity(0.75) : .clear, radius: glowRadius)
            .rotationEffect(.degrees(90))
            .position(x: side - printLine, y: side * 0.50)

        Image(systemName: "arrow.up")
            .font(.system(size: min(10, side * 0.027), weight: .medium))
            .foregroundStyle(ink)
            .shadow(color: highlighted ? glowColor.opacity(0.75) : .clear, radius: glowRadius)
            .position(x: side * 0.50, y: printLine)

        Text("Let’s build")
            .font(inscriptionFont.weight(highlighted ? .semibold : .regular))
            .foregroundStyle(ink)
            .shadow(color: highlighted ? glowColor.opacity(0.75) : .clear, radius: glowRadius)
            .position(x: side * 0.50, y: side - printLine)
    }

    private func agentKey(_ index: Int, side: CGFloat) -> some View {
        AgentKeyView(
            light: light(at: index),
            index: index,
            brightness: peripheral.lightingBrightness ?? 1
        ) { pressing in
            // AG00 is deliberately not replaced with an invented "cancel"
            // command. ChatGPT contextually interprets this exact Agent Key 1
            // event as Cancel while a dial-opened menu is active, and as the
            // normal thread switch everywhere else.
            if pressing {
                // Optimistic selection feedback on every surface so a tapped agent
                // clears its green "complete/unread" glow immediately instead of
                // waiting for the host's next status write. Retiring the "working"
                // glow on a manual switch is Codex-only (workspace surfaces have
                // no such local glow).
                markCodexChatSelected(index)
                if page == .codex { clearOptimisticCodexWorking() }
                // Double-tap a workspace agent key to raise the owning desktop
                // editor app to the front, not just focus its tab. The single
                // tap still selects/focuses (routeKey below); the second tap
                // within the window adds the app-activation request. Only the
                // Workspace pages qualify; each controller raises only its own
                // desktop application and never touches the Codex wire.
                if page.usesWorkspaceBridge {
                    let now = Date()
                    if let last = lastWorkspaceAgentTapAt[index],
                       now.timeIntervalSince(last) < workspaceDoubleTapWindow {
                        let pinnedID = effectiveWorkspacePins.indices.contains(index)
                            ? effectiveWorkspacePins[index] : nil
                        peripheral.raiseWorkspaceApp(surface: page.hostTarget, targetID: pinnedID)
                        lastWorkspaceAgentTapAt[index] = nil // reset so a triple-tap doesn't re-fire
                    } else {
                        lastWorkspaceAgentTapAt[index] = now
                    }
                }
            }
            routeKey("AG0\(index)", action: pressing ? 1 : 0, agent: index)
        }
        .overlay(alignment: .topTrailing) {
            if page.usesWorkspaceBridge,
               effectiveWorkspacePins.indices.contains(index),
               effectiveWorkspacePins[index] != nil {
                Image(systemName: "pin.fill")
                    .font(.system(size: max(8, side * 0.14), weight: .bold))
                    .foregroundStyle(.primary.opacity(0.72))
                    .padding(max(5, side * 0.09))
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel(agentAccessibilityLabel(index))
        .frame(width: side, height: side)
    }

    private func agentAccessibilityLabel(_ index: Int) -> String {
        guard page.usesWorkspaceBridge,
              effectiveWorkspacePins.indices.contains(index),
              let id = effectiveWorkspacePins[index],
              let target = effectiveWorkspaceTargets.first(where: { $0.id == id }) else {
            return "Agent \(index + 1)"
        }
        return "Agent \(index + 1), pinned to \(target.label)"
    }

    private func light(at index: Int) -> SlotLight {
        guard peripheral.slots.indices.contains(index) else { return SlotLight() }
        // Workspace agent keys are an explicit pin map. Never leak cached
        // ChatGPT or another surface's slot colours into an unpinned key while
        // the page-switch state is catching up.
        if page.usesWorkspaceBridge {
            guard effectiveWorkspacePins.indices.contains(index), effectiveWorkspacePins[index] != nil else {
                return SlotLight()
            }
            if page == .claudeCode {
                let selected = effectiveWorkspacePins[index] == effectiveSelectedTargetID
                return SlotLight(
                    color: 0xFFFFFF,
                    brightness: 1,
                    effect: selected ? 4 : 1,
                    speed: selected ? 0.4 : 0
                )
            }
            var light = workspaceState.slots[index]
            // A tapped agent key is authoritative immediately. The bridge echoes
            // the selected slot back as breathing white over BLE, but that
            // round-trip can trail the tap — and until it lands a completed
            // (green) agent keeps looking unread. Show the selection optimistically
            // so it never waits for the next host status write (e.g. a new prompt).
            if localCodexSelection == index {
                light.color = 0xFFFFFF
                light.brightness = 1
                light.effect = 4
                light.speed = 0.4
            }
            return light
        }

        if optimisticCodexWorking == index {
            return SlotLight(color: 0x304FFE, brightness: 1, effect: 4, speed: 0.4)
        }

        var light = peripheral.slots[index]
        let hostSelected = light.isOn && (light.effect == 4 || light.effect == 6)
        let selectedIndex = localCodexSelection ?? peripheral.slots.firstIndex {
            $0.isOn && ($0.effect == 4 || $0.effect == 6)
        }

        // Some ChatGPT builds encode selection as white breathing even while
        // the selected task is running. The ambient snake simultaneously
        // carries that task's semantic status colour. Preserve the breathing
        // selection effect, but source its colour from that authoritative
        // status signal so selected working stays blue instead of flashing
        // white. Voice green/white are deliberately excluded.
        if selectedIndex == index,
           peripheral.ambient.effect == 2,
           peripheral.ambient.color != 0,
           peripheral.ambient.color != 0xFFFFFF,
           !CodexMicroPeripheral.isRecordingGreen(peripheral.ambient.color) {
            light.color = peripheral.ambient.color
            light.brightness = 1
            light.effect = 4
            light.speed = 0.4
        }

        // Green means "complete, unread". The moment that chat is selected it
        // has been read, even if ChatGPT has not emitted its normalized white
        // lighting packet yet.
        if light.color == 0x00FF4C && (hostSelected || localCodexSelection == index) {
            light.color = 0xFFFFFF
            light.brightness = 1
            light.effect = 4
            light.speed = 0.4
        }
        return light
    }

    private func markCodexChatSelected(_ index: Int) {
        localCodexSelection = index
        pendingLocalCodexSelection = true
        codexSelectionReconciliationTask?.cancel()
        codexSelectionReconciliationTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            pendingLocalCodexSelection = false
            if let hostSelection = hostSelectedSlot() {
                localCodexSelection = hostSelection
            }
            codexSelectionReconciliationTask = nil
        }
    }

    /// The slot the host currently reports as selected. On workspace surfaces
    /// the bridge marks only the selected slot as breathing white; a breathing
    /// colour there is a working/attention status, not a selection. On Codex,
    /// ChatGPT drives selection directly, so any breathing slot is the open chat.
    private func hostSelectedSlot() -> Int? {
        let isSelectionLight: (SlotLight) -> Bool = { $0.isOn && ($0.effect == 4 || $0.effect == 6) }
        if page.usesWorkspaceBridge {
            return peripheral.slots.firstIndex { isSelectionLight($0) && $0.color == 0xFFFFFF }
        }
        return peripheral.slots.firstIndex(where: isSelectionLight)
    }

    private func finishCodexSelectionReconciliation() {
        codexSelectionReconciliationTask?.cancel()
        codexSelectionReconciliationTask = nil
        pendingLocalCodexSelection = false
    }

    private func sendKey(_ id: String, pressing: Bool) {
        routeKey(id, action: pressing ? 1 : 0)
    }

    /// Single choke point for every key/dial event on the board. Codex speaks
    /// the ChatGPT HID channel (2); every workspace surface speaks the private
    /// bridge channel (5). The selected host target then isolates VS Code, T3
    /// Code, and Claude Desktop from one another without touching ChatGPT's wire.
    private func routeKey(_ id: String, action: Int, agent: Int? = nil) {
        if page.usesWorkspaceBridge {
            peripheral.sendVSCodeKey(id, action: action, agent: agent, surface: page.hostTarget)
        } else {
            peripheral.sendKey(id, action: action, agent: agent)
        }
    }

    /// Claude's four joystick directions map to Claude Desktop's own commands:
    /// right Browser, down Terminal, left Side Chat, and up /frontend-max.
    /// Only the Claude surface emits these private key IDs.
    private func routeClaudeJoystick(angle: Double, distance: Double) {
        guard distance >= 0.28 else {
            activeClaudeJoystickDirection = nil
            return
        }
        guard distance >= 0.55, activeClaudeJoystickDirection == nil else { return }
        let direction = Int((angle * 4).rounded()) % 4
        activeClaudeJoystickDirection = direction
        let key = ["JOY_RIGHT", "JOY_DOWN", "JOY_LEFT", "JOY_UP"][direction]
        routeKey(key, action: 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            routeKey(key, action: 0)
        }
    }

    /// A 1U command key whose legend/icon follows the synced layout for `slotId`.
    /// The raw HID id sent stays fixed (the physical slot); only the label syncs.
    private func commandKey(_ slotId: String, side: CGFloat) -> some View {
        let binding = peripheral.layout.binding(forSlot: slotId)
        let descriptor = KeycapCatalog.descriptor(for: binding.keycapId)
        let rawKey = slotId == "ACT10_ACT11" ? "ACT10" : slotId
        return CommandKey(
            title: descriptor.label,
            symbol: descriptor.symbol,
            accent: descriptor.accent,
            accessibilityName: descriptor.accessibilityName,
            hint: descriptor.hint
        ) { pressing in
            if pressing, rawKey == "ACT12" { markCodexPromptSubmitted() }
            sendKey(rawKey, pressing: pressing)
            // CODEX submits the pending voice prompt; signal the mic to clear.
            if pressing, rawKey == "ACT12" { codexSendTick &+= 1 }
        }
        .frame(width: side, height: side)
    }

    private func workspaceActionKey(
        _ title: String,
        symbol: String,
        accent: Color,
        side: CGFloat,
        action: @escaping (Bool) -> Void
    ) -> some View {
        CommandKey(
            title: title,
            symbol: symbol,
            accent: accent,
            accessibilityName: title,
            hint: "\(page.surfaceName) \(title.lowercased())"
        ) { action($0) }
        .frame(width: side, height: side)
    }

    private func workspaceBlankKey(side: CGFloat) -> some View {
        HardwareKeyCap(pressed: false, glowColor: nil) {
            Circle()
                .fill(Color.black.opacity(0.14))
                .frame(width: max(7, side * 0.10), height: max(7, side * 0.10))
        }
        .frame(width: side, height: side)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Unassigned")
        .accessibilityHint("Reserved for a future Claude Desktop action")
    }

    /// Match the Codex ACT12 cap exactly while keeping the spoken label and
    /// private bridge route specific to Claude Desktop.
    private func workspaceSendKey(side: CGFloat) -> some View {
        let binding = peripheral.layout.binding(forSlot: "ACT12")
        let descriptor = KeycapCatalog.descriptor(for: binding.keycapId)
        return CommandKey(
            title: descriptor.label,
            symbol: descriptor.symbol,
            accent: descriptor.accent,
            accessibilityName: "Send to Claude",
            hint: "Sends the current Claude Desktop composer message"
        ) { pressing in
            sendKey("ACT12", pressing: pressing)
        }
        .frame(width: side, height: side)
    }

    private func workspaceNewKey(side: CGFloat) -> some View {
        workspaceActionKey("NEW", symbol: "plus", accent: Color(packedRGB: page.accentRGB), side: side) { pressing in
            guard pressing else { return }
            let value = workspaceLauncher.requiresCustomValue
                ? customLauncherValue.trimmingCharacters(in: .whitespacesAndNewlines)
                : workspaceLauncher.value
            guard !value.isEmpty else { return }
            peripheral.createVSCodeSession(
                kind: workspaceLauncher.kind,
                value: value,
                label: workspaceLauncher.title,
                surface: page.hostTarget
            )
        }
    }

    private func workspacePinKey(side: CGFloat) -> some View {
        let selected = effectiveSelectedTargetID
        let isPinned = selected.map { effectiveWorkspacePins.contains($0) } ?? false
        return workspaceActionKey(
            isPinned ? "UNPIN" : "PIN",
            symbol: isPinned ? "pin.slash.fill" : "pin.fill",
            accent: isPinned ? Color(packedRGB: 0xFF8F00) : Color(packedRGB: 0x8B5CF6),
            side: side
        ) { pressing in
            // Pin/unpin the exact target the app is showing as selected, rather
            // than letting the desktop toggle whatever it last cached as focused
            // (which could be a previously-viewed tab). This keeps "the tab I'm
            // in" and "the tab that gets pinned/unpinned" the same.
            if pressing {
                if page == .claudeCode {
                    // Claude Desktop resolves the conversation it is currently
                    // showing. Do not depend on a manually copied deep link.
                    peripheral.toggleVSCodePin(
                        targetID: nil,
                        surface: page.hostTarget
                    )
                } else {
                    peripheral.toggleVSCodePin(targetID: selected, surface: page.hostTarget)
                }
            }
        }
    }

    /// The 2U slot. Renders the push-to-talk microphone when it holds the MIC
    /// cap (the default), otherwise a wide command key for the remapped legend.
    @ViewBuilder
    private func twoUpKey(side: CGFloat, gap: CGFloat) -> some View {
        let binding = peripheral.layout.binding(forSlot: "ACT10_ACT11")
        let width = (side * 2) + gap
        if binding.keycapId == "MIC", codexMicSource == .iphone {
            // "This iPhone": reuse the proven on-device recorder + transcriber
            // (the same pipeline the workspace pages use) and deliver the text
            // straight into ChatGPT's composer instead of driving the Mac's
            // push-to-talk. Voice lighting on the case still animates via the
            // recorder's own state.
            VSCodeVoiceKey(
                recorder: voiceRecorder,
                surfaceName: "Codex",
                targetID: nil,
                autoSend: autoSendVoicePrompts,
                opensExternalPrefill: false,
                usesNativeVoice: false,
                confirmedNativeVoiceActive: nil,
                onNativeVoice: { _, _ in }
            ) { text, _, shouldAutoSend in
                peripheral.insertCodexComposer(text, autoSend: shouldAutoSend)
            }
            .frame(width: width, height: side)
        } else if binding.keycapId == "MIC" {
            MicrophoneKey(
                // CODEX (send) retires the processing snake immediately; the
                // host's voice lighting drives every other transition, so it no
                // longer needs the blunt hostLightingTick coupling.
                endSignal: codexSendTick,
                hostVoice: peripheral.hostVoiceLighting,
                autoSubmitWhenReady: autoSendVoicePrompts,
                onCaseHighlight: { color in
                    withAnimation(.easeInOut(duration: 0.3)) { caseHighlight = color }
                },
                onCasingSnake: { color in
                    withAnimation(.easeInOut(duration: 0.25)) { casingSnake = color }
                },
                onAutoSubmit: {
                    // Waited for the host's transcript-ready signal; this CODEX
                    // press now submits directly into the running thread as a
                    // steer instead of leaving text in the composer for review.
                    markCodexPromptSubmitted()
                    sendKey("ACT12", pressing: true)
                    codexSendTick &+= 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                        sendKey("ACT12", pressing: false)
                    }
                },
                onChange: { sendKey("ACT10", pressing: $0) }
            )
            .frame(width: width, height: side)
        } else {
            let descriptor = KeycapCatalog.descriptor(for: binding.keycapId)
            CommandKey(
                title: descriptor.label,
                symbol: descriptor.symbol,
                accent: descriptor.accent,
                accessibilityName: descriptor.accessibilityName,
                hint: descriptor.hint
            ) { sendKey("ACT10", pressing: $0) }
            .frame(width: width, height: side)
        }
    }

    private func markCodexPromptSubmitted() {
        guard page == .codex else { return }
        let hostSelection = peripheral.slots.firstIndex {
            $0.isOn && ($0.effect == 4 || $0.effect == 6)
        }
        guard let index = localCodexSelection ?? hostSelection else { return }
        localCodexSelection = index
        optimisticCodexWorking = index
        optimisticCodexWorkingTask?.cancel()
        optimisticCodexWorkingTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            optimisticCodexWorking = nil
            optimisticCodexWorkingTask = nil
        }
    }

    private func clearOptimisticCodexWorking() {
        optimisticCodexWorkingTask?.cancel()
        optimisticCodexWorkingTask = nil
        optimisticCodexWorking = nil
    }
}

// MARK: - Key surfaces

private struct HardwareKeyCap<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let pressed: Bool
    let glowColor: Color?
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            let length = min(geometry.size.width, geometry.size.height)
            let corner = max(6, length * 0.13)
            let faceInset = max(1.5, length * 0.035)
            let faceOffset = pressed ? length * 0.025 : -length * 0.012

            ZStack {
                // Contact shadow beneath the raised cap.
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Color.black.opacity(pressed ? 0.12 : 0.25))
                    .padding(length * 0.025)
                    .blur(radius: max(1, length * 0.018))
                    .offset(y: pressed ? length * 0.035 : length * 0.085)

                if let glowColor {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .fill(glowColor.opacity(pressed ? 0.36 : 0.20))
                        .padding(length * 0.02)
                        .blur(radius: max(2, length * 0.09))
                }

                // Darker lower skirt establishes mechanical height.
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(packedRGB: 0xC9CFCE), Color(packedRGB: 0x959C9A)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .padding(length * 0.018)
                    .offset(y: pressed ? length * 0.026 : length * 0.058)

                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(pressed ? 0.91 : 0.99),
                                Color(packedRGB: 0xE6E9E8),
                                Color(packedRGB: 0xD6DBDA)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .padding(faceInset)
                    .overlay {
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .stroke(Color.white.opacity(0.88), lineWidth: 1)
                            .padding(faceInset)
                    }
                    .overlay {
                        // Circular on 1U caps and pill-shaped on the 2U mic cap.
                        RoundedRectangle(cornerRadius: length * 0.34, style: .continuous)
                            .fill(
                                RadialGradient(
                                    colors: [
                                        Color.white.opacity(0.28),
                                        Color.black.opacity(0.008),
                                        Color.black.opacity(0.045)
                                    ],
                                    center: UnitPoint(x: 0.45, y: 0.40),
                                    startRadius: length * 0.05,
                                    endRadius: length * 0.46
                                )
                            )
                            .padding(.horizontal, geometry.size.width > length * 1.35 ? length * 0.10 : length * 0.15)
                            .padding(.vertical, length * 0.17)
                    }
                    .overlay(alignment: .top) {
                        Capsule()
                            .fill(Color.white.opacity(0.46))
                            .frame(width: geometry.size.width * 0.52, height: max(1, length * 0.018))
                            .padding(.top, faceInset + length * 0.02)
                    }
                    .offset(y: faceOffset)

                content()
                    .foregroundStyle(Color.black.opacity(0.78))
                    .padding(max(5, length * 0.13))
                    .offset(y: faceOffset)
            }
            .scaleEffect(pressed ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: pressed)
        }
    }
}

private extension View {
    /// Emissive halo used to make LEDs, keys, and engraved legends read as
    /// backlit instead of printed. Two stacked colored shadows give a tight
    /// core plus a soft bloom.
    func glow(_ color: Color, radius: CGFloat, opacity: Double = 0.9) -> some View {
        self
            .shadow(color: color.opacity(opacity), radius: radius * 0.4)
            .shadow(color: color.opacity(opacity * 0.65), radius: radius)
    }
}

/// Push-to-talk lifecycle used to drive the microphone key's snake lighting.
private enum VoiceState: Equatable {
    case idle
    case recording   // capturing audio — sea-green snake
    case processing  // Codex working on the captured audio — white snake
}

/// The enclosure's edge light. It is off while the selected thread is idle;
/// while a thread works (or voice is active), the installed acrylic chassis
/// itself carries a travelling light from its true outside boundary toward the
/// inner recess. The faceplate/recess layers above this view naturally cut out
/// the center, producing a broad physical light pipe instead of a neon stroke.
/// There is intentionally no passive inner rail.
private struct CasingEdgeLight: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let snakeColor: Color?
    let pulseColor: Color
    let pulseStrength: Double
    let cornerRadius: CGFloat
    let brightness: Double

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let glowRadius = max(5, min(size.width, size.height) * 0.028)

            ZStack {
                if let snakeColor {
                    if reduceMotion {
                        chassisFill(color: snakeColor, opacity: 0.42 * brightness)
                            .shadow(
                                color: snakeColor.opacity(0.34 * brightness),
                                radius: glowRadius
                            )
                    } else {
                        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                            let angle = snakeAngle(at: context.date)

                            movingLight(color: snakeColor, angle: angle)
                                .mask {
                                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                        .fill(.white)
                                }
                                .shadow(
                                    color: snakeColor.opacity(0.48 * brightness),
                                    radius: glowRadius
                                )
                        }
                    }
                }

                if pulseStrength > 0.001 {
                    // Unlike the travelling status/voice snake, encoder
                    // feedback is a single broad breath across the complete
                    // acrylic band. The faceplate above naturally cuts out its
                    // center, keeping the light in the chassis perimeter.
                    chassisFill(
                        color: pulseColor,
                        opacity: 0.52 * brightness * pulseStrength
                    )
                    .shadow(
                        color: pulseColor.opacity(0.50 * brightness * pulseStrength),
                        radius: glowRadius
                    )
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func chassisFill(color: Color, opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(color.opacity(opacity))
    }

    private func movingLight(color: Color, angle: Angle) -> some View {
        AngularGradient(
            gradient: Gradient(stops: [
                .init(color: .clear, location: 0.00),
                .init(color: .clear, location: 0.38),
                .init(color: color.opacity(0.08 * brightness), location: 0.47),
                .init(color: color.opacity(0.46 * brightness), location: 0.63),
                .init(color: color.opacity(0.94 * brightness), location: 0.79),
                .init(color: color.opacity(0.42 * brightness), location: 0.91),
                .init(color: .clear, location: 1.00)
            ]),
            center: .center,
            startAngle: angle,
            endAngle: angle + .degrees(360)
        )
    }

    private func snakeAngle(at date: Date) -> Angle {
        let duration = 1.55
        let progress = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: duration) / duration
        return .degrees(progress * 360)
    }
}

private enum AgentVisualState: Equatable {
    case unassigned
    case idle
    case thinking
    case complete
    case needsInput
    case error
    case other(UInt32)

    init(light: SlotLight) {
        guard light.isOn else {
            self = .unassigned
            return
        }

        switch light.color {
        case 0xFFFFFF: self = .idle
        case 0x304FFE: self = .thinking
        case 0x00FF4C: self = .complete
        case 0xFF8F00: self = .needsInput
        case 0xFF0033: self = .error
        default: self = .other(light.color)
        }
    }

    var title: String {
        switch self {
        case .unassigned: return "Unassigned"
        case .idle: return "Idle"
        case .thinking: return "Thinking"
        case .complete: return "Complete, unread"
        case .needsInput: return "Needs input"
        case .error: return "Error"
        case .other: return "Active"
        }
    }

    var color: Color {
        switch self {
        case .unassigned: return Color(packedRGB: 0xA8B0AE)
        case .idle: return .white
        case .thinking: return Color(packedRGB: 0x304FFE)
        case .complete: return Color(packedRGB: 0x00D941)
        case .needsInput: return Color(packedRGB: 0xFF8F00)
        case .error: return Color(packedRGB: 0xFF0033)
        case let .other(packed): return Color(packedRGB: packed)
        }
    }

    /// Packed status colour used to build the frosted keycap gradient and to
    /// pick a legible glyph colour by luminance.
    var packedColor: UInt32 {
        switch self {
        case .unassigned: return 0xA8B0AE
        case .idle: return 0xFFFFFF
        case .thinking: return 0x304FFE
        case .complete: return 0x00D941
        case .needsInput: return 0xFF8F00
        case .error: return 0xFF0033
        case let .other(packed): return packed
        }
    }

    /// True when the lit cap is bright enough to need a dark status glyph.
    var prefersDarkGlyph: Bool {
        let r = Double((packedColor >> 16) & 0xFF)
        let g = Double((packedColor >> 8) & 0xFF)
        let b = Double(packedColor & 0xFF)
        return (0.299 * r + 0.587 * g + 0.114 * b) / 255 > 0.6
    }

    var symbol: String {
        switch self {
        case .unassigned: return "plus"
        case .idle: return "circle"
        case .thinking: return "ellipsis"
        case .complete: return "checkmark"
        case .needsInput: return "exclamationmark"
        case .error: return "xmark"
        case .other: return "circle.fill"
        }
    }

    var usesLightForeground: Bool {
        switch self {
        case .thinking, .error, .other: return true
        default: return false
        }
    }
}

private struct AgentKeyView: View {
    let light: SlotLight
    let index: Int
    /// Host-reported brightness (0–1) applied to the LED glow.
    let brightness: Double
    let onChange: (Bool) -> Void

    private var state: AgentVisualState { AgentVisualState(light: light) }
    /// ChatGPT identifies the currently selected thread with either of its
    /// breathing effects. The colour still describes that thread's status.
    private var isSelected: Bool {
        light.isOn && (light.effect == 4 || light.effect == 6)
    }

    var body: some View {
        PressableKey(onChange: onChange) { pressed in
            AgentKeyCap(
                state: state,
                isOn: light.isOn,
                isSelected: isSelected,
                brightness: brightness,
                pressed: pressed
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Agent \(index + 1)")
        .accessibilityValue(isSelected ? "\(state.title), selected" : state.title)
        .accessibilityHint(accessibilityHint)
    }

    private var accessibilityHint: String {
        if index == 0 {
            return "When ChatGPT lights this key red after using the dial, press to cancel the open control or menu. Otherwise, press to switch agents; double-press to bring ChatGPT forward."
        }
        return "Single press switches agents. Double-press brings ChatGPT forward."
    }
}

/// A frosted RGB Agent Key. Unlit it is a translucent white keycap with a faint
/// "+"; lit, the whole cap glows in its saturated status colour — brightest at
/// the centre but never blown out to white — with a coloured halo bleeding onto
/// the plate, matching the physical Codex Micro caps instead of a flat dot.
private struct AgentKeyCap: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let state: AgentVisualState
    let isOn: Bool
    /// The selected thread. Idle selection blinks white; a selected active
    /// thread blinks in its status colour without discarding that colour.
    let isSelected: Bool
    /// Host-reported brightness (0–1). At 0 the LED is fully off — the cap
    /// reads as bare frosted plastic; at 1 it is fully saturated.
    let brightness: Double
    let pressed: Bool

    var body: some View {
        GeometryReader { geometry in
            let length = min(geometry.size.width, geometry.size.height)
            let corner = max(6, length * 0.13)
            let faceInset = max(1.5, length * 0.03)
            let faceOffset = pressed ? length * 0.025 : -length * 0.012
            let color = state.color
            let lit = isOn ? max(0, min(1, brightness)) : 0
            let isThinking = state == .thinking
            // The lens emits its status colour edge-to-edge. The core carries the
            // colour itself (not a white-hot point) so a green/orange/red LED reads
            // as that colour everywhere; additive .plusLighter still makes the
            // centre the brightest region, and the milky top sheen below supplies
            // the realistic specular highlight — without washing the middle to white.
            let lensLight: [Color] = isThinking
                ? [
                    color.opacity(1.0),
                    color.opacity(0.95),
                    color.opacity(0.82),
                    color.opacity(0.46)
                ]
                : [
                    color.opacity(0.98),
                    color.opacity(0.88),
                    color.opacity(0.58),
                    color.opacity(0.14)
                ]

            let surface = ZStack {
                // Contact shadow and smoke-coloured lower lens housing.
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Color.black.opacity(pressed ? 0.13 : 0.28))
                    .padding(length * 0.02)
                    .blur(radius: max(1, length * 0.02))
                    .offset(y: pressed ? length * 0.04 : length * 0.09)

                RoundedRectangle(cornerRadius: corner + length * 0.01, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(packedRGB: 0x9DA5A5), Color(packedRGB: 0x6F7676)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .padding(length * 0.015)
                    .offset(y: pressed ? length * 0.027 : length * 0.058)

                // LED spill belongs under the translucent cap, not in the shell.
                if lit > 0 {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .fill(color)
                        .padding(length * 0.015)
                        .blur(radius: length * 0.15)
                        .opacity((pressed ? 0.72 : (isThinking ? 0.66 : 0.54)) * lit)
                        .scaleEffect(isThinking ? 1.09 : 1.07)
                }

                // Frosted smoke lens. It stays visibly grey when the host turns
                // brightness to zero, matching the translucent physical caps.
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(frostedSmoke)
                    .padding(faceInset)
                    .overlay {
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .fill(
                                RadialGradient(
                                    colors: lensLight,
                                    center: UnitPoint(x: 0.5, y: 0.44),
                                    startRadius: length * 0.015,
                                    endRadius: isThinking ? length * 0.90 : length * 0.78
                                )
                            )
                            .padding(faceInset)
                            .opacity(lit)
                            .blendMode(.plusLighter)
                    }
                    .overlay {
                        // Milky top sheen remains visible over the emitted light.
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.54), Color.white.opacity(0.10), .clear],
                                    startPoint: .top,
                                    endPoint: .center
                                )
                            )
                            .padding(faceInset)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .stroke(Color.white.opacity(0.72), lineWidth: 1)
                            .padding(faceInset)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: max(4, corner - 2), style: .continuous)
                            .stroke(Color.black.opacity(0.10), lineWidth: 1)
                            .padding(faceInset + length * 0.045)
                    }
                    .offset(y: faceOffset)

                // Small central diffuser visible in the product's translucent
                // agent caps, including when the LED is off. When lit it takes the
                // status colour (not white) so the centre still carries colour
                // rather than reading as a washed-out hotspot.
                Circle()
                    .fill(
                        lit > 0
                            ? color.opacity(0.14 + 0.12 * lit)
                            : Color(packedRGB: 0x7784B5).opacity(0.16)
                    )
                    .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
                    .frame(width: length * 0.36, height: length * 0.36)
                    .offset(y: faceOffset)

                // The host state remains readable, but the legend is printed
                // into the lens rather than presented as a software badge.
                Image(systemName: state.symbol)
                    .font(.system(size: max(9, length * 0.21), weight: .semibold))
                    .foregroundStyle(glyphColor(lit: lit))
                    .contentTransition(.symbolEffect(.replace))
                    .offset(y: faceOffset)
            }
            .scaleEffect(pressed ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: pressed)
            // Smoothly cross-fade the LED between status colours instead of
            // snapping. Kept fast (0.22s) so the state read stays instant for
            // accessibility. Also fades the lamp on/off and brightness changes.
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: state.packedColor)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: lit)

            if isSelected && !reduceMotion {
                // Date-driven animation resumes deterministically after launch
                // and foregrounding instead of waiting for a touch transaction
                // to restart SwiftUI's animation clock. Animate only the light
                // bloom, keeping the key and its status glyph fully legible.
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    surface.overlay {
                        SelectedKeyBlink(
                            color: color,
                            intensity: blinkIntensity(at: context.date),
                            cornerRadius: corner,
                            inset: faceInset,
                            length: length,
                            pressed: pressed
                        )
                    }
                }
            } else {
                surface.overlay {
                    if isSelected {
                        // Reduce Motion keeps selection unmistakable without a
                        // repeating animation.
                        SelectedKeyBlink(
                            color: color,
                            intensity: 0.72,
                            cornerRadius: corner,
                            inset: faceInset,
                            length: length,
                            pressed: pressed
                        )
                    }
                }
            }
        }
    }

    private func blinkIntensity(at date: Date) -> Double {
        let duration = 1.35
        let progress = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: duration) / duration
        // 0.08...1.0: a clear but smooth hardware-style blink.
        return 0.54 - (0.46 * cos(progress * 2 * .pi))
    }

    private var frostedSmoke: LinearGradient {
        LinearGradient(
            colors: [
                Color(packedRGB: 0xE1E5E6).opacity(0.88),
                Color(packedRGB: 0xB6BEC0).opacity(0.82),
                Color(packedRGB: 0x929A9C).opacity(0.76)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func glyphColor(lit: Double) -> Color {
        if lit > 0.45 && !state.prefersDarkGlyph {
            return Color.white.opacity(0.82)
        }
        return Color.black.opacity(isOn ? 0.48 : 0.18)
    }
}

/// Light emitted by the currently selected Agent Key. The tint comes from the
/// thread status: white when idle, blue while thinking, and so on.
private struct SelectedKeyBlink: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let color: Color
    let intensity: Double
    let cornerRadius: CGFloat
    let inset: CGFloat
    /// The keycap's edge length, so the bloom scales with the cap and fills
    /// more of its face instead of hugging the centre.
    let length: CGFloat
    let pressed: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                RadialGradient(
                    colors: [
                        color.opacity(0.80 * intensity),
                        color.opacity(0.60 * intensity),
                        color.opacity(0.24 * intensity)
                    ],
                    center: UnitPoint(x: 0.5, y: 0.44),
                    startRadius: length * 0.02,
                    endRadius: length * 0.74
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(color.opacity(0.32 + (0.62 * intensity)), lineWidth: 1.6)
            }
            .padding(inset)
            .offset(y: pressed ? 1 : -1)
            .shadow(color: color.opacity(0.82 * intensity), radius: length * 0.11 * intensity)
            .blendMode(.plusLighter)
            // Cross-fade the selected bloom when the thread's status colour
            // changes, matching the base cap's smooth transition.
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: color)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Visual + accessibility description for one Codex Micro keycap legend.
private struct KeycapDescriptor {
    let label: String
    let symbol: String
    let accent: Color
    let accessibilityName: String
    let hint: String
}

/// Maps the desktop app's keycap ids to how each command key renders, following
/// docs/codex-micro-protocol.md §4. Unknown ids (e.g. custom EMPT caps) fall
/// back to a generic key so a remap never leaves a blank surface.
private enum KeycapCatalog {
    static func descriptor(for keycapId: String) -> KeycapDescriptor {
        catalog[keycapId] ?? KeycapDescriptor(
            label: keycapId,
            symbol: "keyboard",
            accent: green,
            accessibilityName: keycapId,
            hint: "Runs the \(keycapId) action"
        )
    }

    private static let green = Color(packedRGB: 0x168A55)
    private static let catalog: [String: KeycapDescriptor] = [
        "FAST": .init(label: "FAST", symbol: "bolt.fill", accent: .blue, accessibilityName: "Fast mode", hint: "Toggles fast mode"),
        "APPR": .init(label: "APPR", symbol: "checkmark.circle", accent: green, accessibilityName: "Approve", hint: "Approves the current request"),
        "REJ": .init(label: "REJ", symbol: "xmark.circle", accent: .red, accessibilityName: "Decline", hint: "Declines the current request"),
        "SPLIT": .init(label: "SPLIT", symbol: "arrow.triangle.branch", accent: .indigo, accessibilityName: "Continue in new chat", hint: "Continues the conversation in a new chat"),
        "MIC": .init(label: "MIC", symbol: "mic.fill", accent: green, accessibilityName: "Microphone", hint: "Hold for push-to-talk"),
        "CODEX": .init(label: "CODEX", symbol: "chevron.left.forwardslash.chevron.right", accent: green, accessibilityName: "Send to Codex", hint: "Sends the current composer message"),
        "BUG": .init(label: "BUG", symbol: "ant.fill", accent: green, accessibilityName: "Send feedback", hint: "Sends feedback"),
        "OAI": .init(label: "OAI", symbol: "globe", accent: green, accessibilityName: "Open developers.openai.com", hint: "Opens the OpenAI developers site"),
        "TERM": .init(label: "TERM", symbol: "terminal", accent: green, accessibilityName: "Toggle terminal", hint: "Toggles the terminal"),
        "NAV": .init(label: "NAV", symbol: "safari", accent: green, accessibilityName: "Open browser tab", hint: "Opens a browser tab"),
        "DWN": .init(label: "DWN", symbol: "doc.on.doc", accent: green, accessibilityName: "Copy conversation as Markdown", hint: "Copies the conversation as Markdown"),
        "DEL": .init(label: "DEL", symbol: "archivebox", accent: green, accessibilityName: "Archive thread", hint: "Archives the current thread"),
        "NEW": .init(label: "NEW", symbol: "square.and.pencil", accent: green, accessibilityName: "New task", hint: "Starts a new task"),
        "MAGIC": .init(label: "MAGIC", symbol: "pin.fill", accent: green, accessibilityName: "Pin or unpin thread", hint: "Pins or unpins the thread"),
        "DIFF": .init(label: "DIFF", symbol: "plus.forwardslash.minus", accent: green, accessibilityName: "Review changes", hint: "Opens the review changes tab"),
        "BRCH": .init(label: "BRCH", symbol: "arrow.triangle.branch", accent: green, accessibilityName: "Review changes", hint: "Opens the review changes tab"),
        "MRG": .init(label: "MRG", symbol: "arrow.triangle.merge", accent: green, accessibilityName: "Review changes", hint: "Opens the review changes tab"),
        "PLAY": .init(label: "PLAY", symbol: "play.fill", accent: green, accessibilityName: "Environment action", hint: "Runs environment action 1"),
        "GIT": .init(label: "GIT", symbol: "arrow.up.circle", accent: green, accessibilityName: "Commit", hint: "Commits the current changes"),
        "PR": .init(label: "PR", symbol: "arrow.triangle.pull", accent: green, accessibilityName: "Create pull request", hint: "Creates a pull request"),
        "PAINT": .init(label: "PAINT", symbol: "photo", accent: green, accessibilityName: "Add photos", hint: "Adds photos"),
        "UPL": .init(label: "UPL", symbol: "paperclip", accent: green, accessibilityName: "Add files", hint: "Adds files"),
        "LAB": .init(label: "LAB", symbol: "gearshape", accent: green, accessibilityName: "Open settings", hint: "Opens settings"),
        "SETUP": .init(label: "SETUP", symbol: "gearshape.2", accent: green, accessibilityName: "Open settings", hint: "Opens settings"),
        "PARTY": .init(label: "PARTY", symbol: "bubble.left.and.bubble.right", accent: green, accessibilityName: "Open side chat", hint: "Opens a side chat"),
        "TIME": .init(label: "TIME", symbol: "clock", accent: green, accessibilityName: "Scheduled tasks", hint: "Manages scheduled tasks"),
        "MIND+": .init(label: "MIND+", symbol: "brain.head.profile", accent: green, accessibilityName: "Increase reasoning effort", hint: "Increases reasoning effort"),
        "MIND-": .init(label: "MIND-", symbol: "brain", accent: green, accessibilityName: "Decrease reasoning effort", hint: "Decreases reasoning effort"),
        "FOLD": .init(label: "FOLD", symbol: "folder", accent: green, accessibilityName: "Open folder", hint: "Opens a folder"),
        "APPS": .init(label: "APPS", symbol: "square.grid.2x2", accent: green, accessibilityName: "Open Skills", hint: "Opens Skills"),
        "YOLO": .init(label: "YOLO", symbol: "face.smiling", accent: green, accessibilityName: "Insert :yolo:", hint: "Inserts :yolo: into the composer"),
        "YEET": .init(label: "YEET", symbol: "hand.wave", accent: green, accessibilityName: "Insert :yeet:", hint: "Inserts :yeet: into the composer"),
        "EMPT1": .init(label: "EMPT1", symbol: "keyboard", accent: green, accessibilityName: "Custom shortcut 1", hint: "Runs custom shortcut 1"),
        "EMPT2": .init(label: "EMPT2", symbol: "keyboard", accent: green, accessibilityName: "Custom shortcut 2", hint: "Runs custom shortcut 2"),
        "EMPT3": .init(label: "EMPT3", symbol: "keyboard", accent: green, accessibilityName: "Custom shortcut 3", hint: "Runs custom shortcut 3"),
        "EMPT4": .init(label: "EMPT4", symbol: "keyboard", accent: green, accessibilityName: "Custom shortcut 4", hint: "Runs custom shortcut 4"),
        "EMPT5": .init(label: "EMPT5", symbol: "keyboard", accent: green, accessibilityName: "Custom shortcut 5", hint: "Runs custom shortcut 5"),
    ]
}

/// Turns a host command id ("composer.togglePlanMode") into a readable label
/// for the diagnostics sheet.
private func prettyCommand(_ id: String?) -> String {
    guard let raw = id, !raw.isEmpty else { return "Unassigned" }
    let tail = raw.split(separator: ".").last.map(String.init) ?? raw
    var out = ""
    for (index, character) in tail.enumerated() {
        if character.isUppercase && index != 0 { out.append(" ") }
        out.append(character)
    }
    return out.prefix(1).uppercased() + out.dropFirst()
}

private struct CommandKey: View {
    let title: String
    let symbol: String
    let accent: Color
    let accessibilityName: String
    let hint: String
    let onChange: (Bool) -> Void

    var body: some View {
        PressableKey(onChange: onChange) { pressed in
            HardwareKeyCap(pressed: pressed, glowColor: pressed ? accent : nil) {
                Image(systemName: symbol)
                    .font(.title3.weight(.regular))
                    .symbolRenderingMode(.monochrome)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityName)
        .accessibilityHint(hint)
    }
}

private struct VSCodeVoiceKey: View {
    @ObservedObject var recorder: VoicePromptRecorder
    @State private var localNativeRecording = false
    @State private var nativeRecordingTargetID: String?
    @State private var nativePressStart = Date()
    @State private var lastNativeTap: Date?
    @State private var nativeTapResetTask: Task<Void, Never>?
    @State private var nativeVoiceLatched = false
    @State private var nativeVoiceDesiredActive = false
    @State private var latestConfirmedNativeVoiceActive: Bool?
    @State private var nativeVoiceConfirmationTask: Task<Void, Never>?
    let surfaceName: String
    /// Snapshot when recording begins so a late transcription cannot be
    /// inserted into whichever agent the user happens to select next.
    let targetID: String?
    let autoSend: Bool
    let opensExternalPrefill: Bool
    /// Native provider dictation is used only when the selected concrete
    /// target advertises it and auto-send is off. Auto-send needs a transcript
    /// completion event, which Claude's VS Code command does not expose.
    let usesNativeVoice: Bool
    /// Claude Desktop confirms start/stop through bridge state. Nil retains the
    /// existing local latch for providers that do not publish acknowledgements.
    let confirmedNativeVoiceActive: Bool?
    let onNativeVoice: (Bool, String?) -> Void
    let onTranscript: (String, String?, Bool) -> Void

    var body: some View {
        PressableKey { pressing in
            if usesNativeVoice {
                handleNativeVoiceEdge(pressing)
                return
            }
            if pressing { recorder.resetError() }
            if pressing {
                let recordedTargetID = targetID
                let shouldAutoSend = autoSend
                recorder.setPressed(true) { text in
                    onTranscript(text, recordedTargetID, shouldAutoSend)
                }
            } else {
                recorder.setPressed(false) { _ in }
            }
        } label: { pressed in
            let active = pressed
                || (usesNativeVoice
                    && (nativeVoiceLatched
                        || confirmedNativeVoiceActive == true
                        || localNativeRecording))
            HardwareKeyCap(pressed: active, glowColor: glowColor(pressed: active)) {
                HStack(spacing: 7) {
                    Image(systemName: symbol)
                        .font(.headline.weight(.semibold))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title(pressed: active))
                            .font(.caption.weight(.bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                        if !detail.isEmpty {
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(Color.black.opacity(0.62))
                                .lineLimit(1)
                        }
                    }
                }
                .foregroundStyle(Color.black.opacity(0.82))
            }
        }
        .accessibilityLabel("\(surfaceName) microphone")
        .accessibilityHint(
            usesNativeVoice
                ? "Hold to talk. Double-tap for hands-free dictation; tap once to stop."
                : opensExternalPrefill
                ? "Hold to dictate on this iPhone. Release to open Claude with a new-session composer prefilled for review; Claude does not expose auto-submit."
                : autoSend
                ? "Hold to dictate. The recognized prompt is sent automatically to the session selected when recording began."
                : "Hold to dictate text into the selected session, then press Send."
        )
        .onAppear {
            latestConfirmedNativeVoiceActive = confirmedNativeVoiceActive
        }
        .onChange(of: confirmedNativeVoiceActive) { _, confirmed in
            latestConfirmedNativeVoiceActive = confirmed
            guard let confirmed, confirmed == nativeVoiceDesiredActive else { return }
            nativeVoiceConfirmationTask?.cancel()
            nativeVoiceConfirmationTask = nil
            localNativeRecording = confirmed
            if !confirmed { nativeVoiceLatched = false }
        }
        .onDisappear {
            nativeTapResetTask?.cancel()
            nativeTapResetTask = nil
            nativeVoiceConfirmationTask?.cancel()
            nativeVoiceConfirmationTask = nil
            if usesNativeVoice,
               localNativeRecording
                || nativeVoiceLatched
                || confirmedNativeVoiceActive == true {
                onNativeVoice(false, nativeRecordingTargetID)
            }
            localNativeRecording = false
            nativeVoiceLatched = false
            nativeRecordingTargetID = nil
            lastNativeTap = nil
        }
    }

    /// Mirrors the physical Codex microphone contract without sharing its
    /// backend: hold is push-to-talk, a quick double-tap leaves Claude's native
    /// dictation latched, and one tap while latched stops it.
    private func handleNativeVoiceEdge(_ pressing: Bool) {
        if pressing {
            nativePressStart = Date()
            guard !nativeVoiceLatched else { return }
            nativeRecordingTargetID = targetID
            requestNativeVoice(true, targetID: targetID)
            return
        }

        let held = Date().timeIntervalSince(nativePressStart)
        if nativeVoiceLatched {
            nativeVoiceLatched = false
            lastNativeTap = nil
            nativeTapResetTask?.cancel()
            nativeTapResetTask = nil
            let recordedTargetID = nativeRecordingTargetID
            nativeRecordingTargetID = nil
            requestNativeVoice(false, targetID: recordedTargetID)
            return
        }

        if held < 0.35,
           let previousTap = lastNativeTap,
           Date().timeIntervalSince(previousTap) < 0.45 {
            lastNativeTap = nil
            nativeTapResetTask?.cancel()
            nativeTapResetTask = nil
            nativeVoiceLatched = true
            // The second touch-down already started dictation. Do not emit a
            // release here; keeping that request active is the hands-free latch.
            return
        }

        let recordedTargetID = nativeRecordingTargetID
        nativeRecordingTargetID = nil
        requestNativeVoice(false, targetID: recordedTargetID)

        if held < 0.35 {
            lastNativeTap = Date()
            nativeTapResetTask?.cancel()
            nativeTapResetTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 450_000_000)
                guard !Task.isCancelled else { return }
                lastNativeTap = nil
                nativeTapResetTask = nil
            }
        } else {
            lastNativeTap = nil
            nativeTapResetTask?.cancel()
            nativeTapResetTask = nil
        }
    }

    private func requestNativeVoice(_ active: Bool, targetID: String?) {
        nativeVoiceDesiredActive = active
        localNativeRecording = active
        onNativeVoice(active, targetID)
        nativeVoiceConfirmationTask?.cancel()
        guard confirmedNativeVoiceActive != nil else { return }
        nativeVoiceConfirmationTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled,
                  nativeVoiceDesiredActive == active,
                  let confirmed = latestConfirmedNativeVoiceActive,
                  confirmed != active else { return }
            localNativeRecording = confirmed
            if !confirmed { nativeVoiceLatched = false }
            nativeVoiceConfirmationTask = nil
        }
    }

    private func title(pressed: Bool) -> String {
        if usesNativeVoice { return pressed ? "LISTENING" : "CLAUDE VOICE" }
        switch recorder.phase {
        case .idle: return opensExternalPrefill ? "HOLD TO PREFILL" : "HOLD TO TALK"
        case .requestingPermission: return "ALLOW MICROPHONE"
        case .listening: return "LISTENING"
        case .processing: return "TRANSCRIBING"
        case .failed: return "TRY AGAIN"
        }
    }

    private var detail: String {
        if !recorder.transcript.isEmpty { return recorder.transcript }
        if case .failed(let message) = recorder.phase { return message }
        return ""
    }

    private var symbol: String {
        if usesNativeVoice { return "mic.fill" }
        switch recorder.phase {
        case .processing: return "waveform"
        case .failed: return "exclamationmark.triangle.fill"
        default: return "mic.fill"
        }
    }

    private func glowColor(pressed: Bool) -> Color? {
        if usesNativeVoice { return pressed ? Color(packedRGB: 0x2E8B57) : nil }
        switch recorder.phase {
        case .listening: return Color(packedRGB: 0x2E8B57)
        case .processing: return .white
        case .failed: return Color(packedRGB: 0xFF0033)
        default: return nil
        }
    }
}

private struct MicrophoneKey: View {
    /// Sea-green while recording per the Codex Micro voice-capture lighting.
    static let recordingColor = Color(packedRGB: 0x2FD98A)

    /// Bumped by the parent when CODEX (send) is pressed. Retires the
    /// processing snake immediately, since sending consumes the prompt.
    let endSignal: Int
    /// The Mac's real voice-capture state, decoded from the host's ambient
    /// lighting. This is ground truth: whenever it asserts a voice state it
    /// overrides the local optimistic guess, so the snake can never claim to be
    /// recording while the Mac isn't (docs §Voice and global lighting).
    let hostVoice: HostVoiceLighting
    /// Captured when voice recording starts. If true, release waits for the
    /// host's solid-white transcript-ready signal and submits it immediately.
    let autoSubmitWhenReady: Bool
    /// Lights the surrounding case + engraved legends while hands-free
    /// recording is latched (nil clears the highlight).
    let onCaseHighlight: (Color?) -> Void
    /// Reports the active voice colour to the existing casing edge light.
    let onCasingSnake: (Color?) -> Void
    /// Emits the existing CODEX key once speech-to-text is genuinely ready.
    let onAutoSubmit: () -> Void
    let onChange: (Bool) -> Void

    @State private var voiceState: VoiceState = .idle
    @State private var latched = false
    // @GestureState auto-resets to false the instant a touch ends OR is
    // interrupted (e.g. a sheet steals it), so the key can never get stuck
    // "pressed" and stop responding — unlike a manual @State flag.
    @GestureState private var fingerDown = false
    // True between a genuine touch-down and its genuine finger-up. Distinct
    // from `fingerDown`: it survives a mid-hold gesture cancellation so the
    // ACT10 press is only released by a real lift (onEnded), never by an
    // interruption from an unrelated view re-render.
    @State private var pressLive = false
    @State private var abandonTask: Task<Void, Never>?
    @State private var pressStart = Date()
    @State private var lastTap: Date?
    @State private var tapResolveTask: Task<Void, Never>?
    @State private var processingTask: Task<Void, Never>?
    @State private var autoSubmitArmed = false
    // Clears an optimistically-shown snake shortly after the finger lifts if
    // the Mac never confirms a capture through its lighting — the fix for the
    // stale "recording" snake after a memo is sent and the key is pressed again.
    @State private var unconfirmedClearTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            let length = min(geometry.size.width, geometry.size.height)

            HardwareKeyCap(pressed: fingerDown, glowColor: keyGlow) {
                ZStack {
                    Image(systemName: "mic")
                        .font(.title3.weight(.regular))

                    HStack {
                        Spacer()
                        MicIndicator(color: indicatorColor, length: length)
                    }
                    .padding(.trailing, 3)
                }
            }
            .contentShape(Rectangle())
            // The press starts on touch-down and is released ONLY on a genuine
            // finger-up (onEnded). @GestureState resets when the drag ends *or*
            // is cancelled by an unrelated re-render — but a cancellation never
            // calls onEnded, so sourcing the ACT10 release from onEnded (not
            // from the state reset) stops the mic from cutting out ~1s into a
            // hold when the BLE host connects and churns the view tree. The
            // @GestureState still powers the cap-press visual; the grace task
            // below reclaims a genuinely abandoned touch so the key can't wedge.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($fingerDown) { _, state, _ in state = true }
                    .onChanged { _ in beginPress() }
                    .onEnded { _ in endPress() }
            )
            .onChange(of: fingerDown) { _, down in
                if down {
                    // Touch present (or re-attached after an interruption):
                    // the press is still live, so cancel any pending reclaim.
                    abandonTask?.cancel(); abandonTask = nil
                } else if pressLive {
                    scheduleAbandonRelease()
                }
            }
            .onChange(of: voiceState) { _, state in
                onCasingSnake(Self.snakeColor(for: state))
            }
            .onChange(of: hostVoice) { _, host in applyHostVoice(host) }
            .onChange(of: endSignal) { _, _ in finishVoiceOnSend() }
            .animation(.easeInOut(duration: 0.2), value: voiceState)
            .animation(.easeOut(duration: 0.12), value: fingerDown)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(
            autoSubmitWhenReady
                ? "Hold to talk. Release to steer the running agent immediately."
                : "Hold to talk. Double-tap for hands-free recording; tap again to finish."
        )
        .accessibilityAction(.default) { pulse() }
        .accessibilityAction(named: Text(latched ? "Stop hands-free" : "Hands-free recording")) { toggleLatch() }
        .onDisappear(perform: cleanup)
    }

    /// Casing snake colour for each voice phase: mint while recording and
    /// white while Codex processes the captured prompt.
    static func snakeColor(for state: VoiceState) -> Color? {
        switch state {
        case .recording: return recordingColor
        case .processing: return .white
        case .idle: return nil
        }
    }

    /// Drives the whole-cap bloom behind the key, not just a border edge.
    private var keyGlow: Color? {
        switch voiceState {
        case .recording: return Self.recordingColor
        case .processing: return .white
        case .idle: return fingerDown ? Self.recordingColor : nil
        }
    }

    private var indicatorColor: Color? {
        switch voiceState {
        case .recording: return Self.recordingColor
        case .processing: return .white
        case .idle: return nil
        }
    }

    private var accessibilityLabel: String {
        switch voiceState {
        case .recording: return latched ? "Microphone, recording hands-free" : "Microphone, recording"
        case .processing: return "Microphone, sending to Codex"
        case .idle: return "Microphone, ACT10 and ACT11"
        }
    }

    // MARK: Interaction

    /// Genuine touch-down. onChanged fires repeatedly during a drag, so guard
    /// on pressLive to run the press once per touch.
    private func beginPress() {
        abandonTask?.cancel(); abandonTask = nil
        guard !pressLive else { return }
        pressLive = true
        pressDown()
    }

    /// Genuine finger-up. The only path that releases ACT10 during normal use.
    private func endPress() {
        abandonTask?.cancel(); abandonTask = nil
        guard pressLive else { return }
        pressLive = false
        pressUp()
    }

    /// The gesture reset without an onEnded — either a transient interruption
    /// (the touch re-attaches within a frame and cancels this) or a truly
    /// abandoned press. Wait out interruptions, then release only if the finger
    /// is still gone, so the key never stays stuck down.
    private func scheduleAbandonRelease() {
        abandonTask?.cancel()
        abandonTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled, pressLive, !fingerDown else { return }
            endPress()
        }
    }

    private func pressDown() {
        processingTask?.cancel(); processingTask = nil
        // A new press starts a fresh cycle — drop any pending grace clear from
        // the previous one so it can't retire this recording.
        unconfirmedClearTask?.cancel(); unconfirmedClearTask = nil
        pressStart = Date()
        // ChatGPT owns the mic state machine and derives push-to-talk, latch,
        // and "press while latched to stop" solely from raw ACT10 press/release
        // edges (docs §Host-side gesture state machines). So every physical
        // touch-down must emit its press edge — including the tap that stops a
        // hands-free latch. Suppressing it here left that stopping tap with only
        // a release edge, so the host never saw the press and the memo never
        // finished. pressUp always supplies the matching release.
        onChange(true)
        // While latched this press only arms the stop; keep the recording snake
        // lit and don't re-arm steering — the release in pressUp ends the memo.
        guard !latched else { return }
        // Capture the thread state at recording start. If the task completes
        // while the user is speaking, the utterance still belongs to the task
        // they intentionally started steering.
        autoSubmitArmed = autoSubmitWhenReady
        voiceState = .recording
    }

    private func pressUp() {
        let held = Date().timeIntervalSince(pressStart)

        // Any release while hands-free latched stops recording and sends.
        if latched {
            setLatched(false)
            onChange(false)
            startProcessing()
            return
        }

        onChange(false)

        if held < 0.35 {
            // Short tap: a second one soon after latches hands-free recording.
            if let last = lastTap, Date().timeIntervalSince(last) < 0.45 {
                lastTap = nil
                tapResolveTask?.cancel(); tapResolveTask = nil
                processingTask?.cancel(); processingTask = nil
                voiceState = .recording
                setLatched(true)
                return
            }
            lastTap = Date()
            tapResolveTask?.cancel()
            tapResolveTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 450_000_000)
                guard !Task.isCancelled else { return }
                lastTap = nil
                tapResolveTask = nil
                if !latched { startProcessing() }
            }
        } else {
            // Genuine push-to-talk hold released — hand off to processing.
            lastTap = nil
            startProcessing()
        }
    }

    private func toggleLatch() {
        if latched {
            setLatched(false)
            onChange(false)
            startProcessing()
        } else {
            processingTask?.cancel(); processingTask = nil
            autoSubmitArmed = autoSubmitWhenReady
            voiceState = .recording
            onChange(true)
            setLatched(true)
        }
    }

    private func pulse() {
        processingTask?.cancel(); processingTask = nil
        autoSubmitArmed = autoSubmitWhenReady
        voiceState = .recording
        onChange(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            onChange(false)
            startProcessing()
        }
    }

    private func setLatched(_ on: Bool) {
        latched = on
        onCaseHighlight(on ? Self.recordingColor : nil)
    }

    private func startProcessing() {
        processingTask?.cancel()
        voiceState = .processing
        // The white snake lasts the whole "voice → text" phase. When the Mac is
        // driving voice lighting it retires precisely — the host moves ambient
        // to ready/idle (`applyHostVoice`) or CODEX is sent (`endSignal`). This
        // timeout is only a backstop for hosts that never drive that lighting,
        // kept short so the snake can't linger.
        processingTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            autoSubmitArmed = false
            voiceState = .idle
        }
        scheduleUnconfirmedClear()
    }

    /// Ground truth from the Mac. Voice lighting the host drives always wins
    /// over the local optimistic guess: it adopts recording/processing when the
    /// Mac confirms them, and clears the snake the moment the Mac stops
    /// capturing — which is what fixes the stale "recording" snake after a memo
    /// is sent and the key is pressed again.
    private func applyHostVoice(_ host: HostVoiceLighting) {
        switch host {
        case .recording:
            unconfirmedClearTask?.cancel(); unconfirmedClearTask = nil
            processingTask?.cancel(); processingTask = nil
            voiceState = .recording
        case .processing:
            unconfirmedClearTask?.cancel(); unconfirmedClearTask = nil
            processingTask?.cancel(); processingTask = nil
            voiceState = .processing
        case .ready:
            // ACT12 must not be sent on finger-up: speech recognition is still
            // producing the transcript then. Solid white is ChatGPT's explicit
            // ready signal, so this is the first race-free submission point.
            if autoSubmitArmed, !fingerDown, !latched {
                autoSubmitArmed = false
                unconfirmedClearTask?.cancel(); unconfirmedClearTask = nil
                processingTask?.cancel(); processingTask = nil
                voiceState = .idle
                onAutoSubmit()
            } else {
                clearIfUnconfirmed()
            }
        case .none:
            // The Mac is not capturing — drop any snake we're optimistically
            // showing. Held or latched presses are exempt: the press itself is
            // the recording intent and the host lighting may simply lag it.
            clearIfUnconfirmed()
        }
    }

    /// Retires an optimistic snake once the finger is up and hands-free isn't
    /// latched. A no-op while the user is physically holding the key.
    private func clearIfUnconfirmed() {
        guard !fingerDown, !latched, voiceState != .idle else { return }
        unconfirmedClearTask?.cancel(); unconfirmedClearTask = nil
        processingTask?.cancel(); processingTask = nil
        autoSubmitArmed = false
        voiceState = .idle
    }

    /// After the finger lifts, give the Mac a short grace to reflect the press
    /// in its lighting. If it never confirms a capture, clear the snake so it
    /// can't imply a recording that isn't happening. If the host *does* confirm,
    /// `applyHostVoice` cancels this task first, so the snake stays.
    private func scheduleUnconfirmedClear() {
        unconfirmedClearTask?.cancel()
        unconfirmedClearTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            clearIfUnconfirmed()
        }
    }

    /// End of the voice flow — the prompt was sent via CODEX. Retire the
    /// processing snake. Ignored while actively recording, since the user is
    /// still dictating.
    private func finishVoiceOnSend() {
        // A manual CODEX press always disarms deferred submission, even if the
        // optimistic processing animation already timed out.
        autoSubmitArmed = false
        guard voiceState == .processing else { return }
        unconfirmedClearTask?.cancel(); unconfirmedClearTask = nil
        processingTask?.cancel(); processingTask = nil
        voiceState = .idle
    }

    private func cleanup() {
        tapResolveTask?.cancel(); tapResolveTask = nil
        processingTask?.cancel(); processingTask = nil
        unconfirmedClearTask?.cancel(); unconfirmedClearTask = nil
        abandonTask?.cancel(); abandonTask = nil
        if voiceState == .recording, !latched { onChange(false) }
        setLatched(false)
        voiceState = .idle
        onCasingSnake(nil)
        autoSubmitArmed = false
        lastTap = nil
        pressLive = false
    }
}

/// The mic's status LED, rendered as a soft emissive bloom rather than a solid
/// filled disc so it reads as glowing light. Dim and neutral when idle.
private struct MicIndicator: View {
    let color: Color?
    let length: CGFloat

    var body: some View {
        let tint = color ?? Color.white
        let size = max(12, length * 0.17)
        let active = color != nil

        ZStack {
            Circle()
                .fill(tint)
                .frame(width: size, height: size)
                .blur(radius: size * 0.5)
                .opacity(active ? 0.95 : 0.28)

            Circle()
                .fill(tint)
                .frame(width: size * 0.46, height: size * 0.46)
                .blur(radius: size * 0.1)
                .opacity(active ? 1 : 0.45)
        }
        .frame(width: size, height: size)
    }
}

private struct TouchSensor: View {
    let openConnectionDetails: () -> Void
    @State private var armed = false

    var body: some View {
        PressableKey { pressing in
            if pressing {
                armed = true
            } else if armed {
                armed = false
                openConnectionDetails()
            }
        } label: { pressed in
            GeometryReader { geometry in
                let length = min(geometry.size.width, geometry.size.height)

                ZStack {
                    // The real capacitive pad is a flat black disc, not a
                    // raised keycap. The whole cell remains the 44+ pt target.
                    Circle()
                        .fill(Color.black.opacity(pressed ? 0.72 : 1))
                        .frame(width: length * 0.52, height: length * 0.52)

                    VStack(spacing: max(2, length * 0.035)) {
                        ForEach(0..<3, id: \.self) { channel in
                            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                .fill(channel == 0 ? Color(packedRGB: 0x57E89B) : Color(packedRGB: 0xE6E9E7))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                        .stroke(Color.black.opacity(0.42), lineWidth: 1)
                                }
                                .shadow(
                                    color: channel == 0 ? Color(packedRGB: 0x57E89B).opacity(0.55) : .clear,
                                    radius: max(1, length * 0.025)
                                )
                                .frame(width: max(7, length * 0.105), height: max(4, length * 0.055))
                        }
                    }
                    .offset(x: -length * 0.34)
                }
                // GeometryReader otherwise places the decoration-sized ZStack
                // at the cell's top-leading corner. Occupying the whole cell
                // centers the disc on the adjacent button row exactly.
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Capacitive touch and Bluetooth setup")
        .accessibilityHint("Shows pairing instructions and connection diagnostics")
    }
}

// MARK: - Dial and joystick

private struct RotaryControl: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let onStep: (Bool) -> Void
    let onPress: (Bool) -> Void

    @State private var rotation = 42.0
    // Circular (rim) tracking.
    @State private var lastDragAngle: Double?
    @State private var pendingRotation = 0.0
    // Linear (center) fine-scrub tracking.
    @State private var lastLocation: CGPoint?
    @State private var pendingLinear = 0.0
    @State private var isRotating = false
    @State private var isTouching = false
    @State private var isPressed = false
    @State private var touchStartedAt: Date?
    @State private var pressStartedAt: Date?
    @State private var pendingPressTask: Task<Void, Never>?

    // Relative detent readout for the active gesture, so a turn can be counted
    // and landed precisely without needing to read the host's current target.
    @State private var stepBalance = 0
    @State private var showBalance = false
    @State private var balanceHideTask: Task<Void, Never>?

    // Haptic detents. `.selection` is Apple's cue for moving through discrete
    // values (a picker/encoder); a press gives a firmer impact, and crossing the
    // 500 ms hold threshold gives a heavier one to signal "settings will open".
    @State private var detentTick = 0
    @State private var pressTick = 0
    @State private var settingsTick = 0

    var body: some View {
        GeometryReader { geometry in
            let length = min(geometry.size.width, geometry.size.height)
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)

            ZStack {
                // Short cast shadow under a raised cylindrical encoder.
                Circle()
                    .fill(Color.black.opacity(0.28))
                    .blur(radius: max(1, length * 0.025))
                    .offset(y: length * 0.075)

                // Fixed collar seated in the faceplate.
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(packedRGB: 0xF5F6F5), Color(packedRGB: 0xAAB0AF)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        // Continuous dotted perimeter around the fixed collar;
                        // the rotating button/drum inside remains unchanged.
                        Circle()
                            .stroke(
                                Color.black.opacity(0.48),
                                style: StrokeStyle(
                                    lineWidth: max(1.25, length * 0.014),
                                    lineCap: .round,
                                    dash: [0.1, max(3, length * 0.055)]
                                )
                            )
                            .padding(length * 0.012)
                    }

                // Neutral top drum with directional shading. The broad diagonal
                // ridge is the recognisable physical control from the product.
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color.white,
                                    Color(packedRGB: 0xE6E9E8),
                                    Color(packedRGB: 0xB9BFBE)
                                ],
                                center: UnitPoint(x: 0.34, y: 0.26),
                                startRadius: 0,
                                endRadius: length * 0.50
                            )
                        )
                        .overlay(Circle().stroke(Color.white.opacity(0.78), lineWidth: 1))

                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color(packedRGB: 0x6A706F), Color(packedRGB: 0x343837)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(8, length * 0.20), height: length * 0.70)
                        .shadow(color: .black.opacity(0.28), radius: 2, x: length * 0.02, y: length * 0.02)

                    Capsule()
                        .fill(Color.white.opacity(0.22))
                        .frame(width: max(1, length * 0.025), height: length * 0.56)
                        .offset(x: -length * 0.045)
                }
                .padding(length * 0.075)
                .offset(y: -length * 0.025)
                .rotationEffect(.degrees(rotation))

                if showBalance, stepBalance != 0 {
                    stepReadout(length: length)
                }
            }
            .padding(length * 0.06)
            .scaleEffect(isPressed ? 0.95 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isPressed)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(dragGesture(center: center, deadZone: length * 0.30, linearThrow: max(20, length * 0.20)))
        }
        .sensoryFeedback(.selection, trigger: detentTick)
        .sensoryFeedback(.impact(weight: .medium), trigger: pressTick)
        .sensoryFeedback(.impact(flexibility: .rigid, intensity: 1.0), trigger: settingsTick)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reasoning dial")
        .accessibilityValue("Composer navigation")
        .accessibilityHint("Drag around the rim to turn, or slide up and down in the center to step one at a time. Activate to press. Press and hold for settings.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: sendStep(clockwise: true)
            case .decrement: sendStep(clockwise: false)
            @unknown default: break
            }
        }
        .accessibilityAction {
            // Complete the encoder click as one ordered transaction. Deferring
            // release allowed a fast follow-up turn to reach ChatGPT first and
            // continue composer navigation instead of adjusting the control
            // that had just been selected.
            onPress(true)
            onPress(false)
        }
        .onDisappear {
            pendingPressTask?.cancel()
            balanceHideTask?.cancel()
            if isPressed { onPress(false) }
        }
    }

    /// A deliberately coarse virtual encoder: 30° per emitted detent gives
    /// twelve precise steps per revolution instead of twenty, requiring a
    /// more intentional turn before changing the host selection.
    private var stepDegrees: Double { 30 }
    private var stepAngle: Double { stepDegrees * .pi / 180 }

    /// Transient ±N detent count for the active gesture, floated just above the
    /// pointer so a turn can be counted and stopped on the right item.
    private func stepReadout(length: CGFloat) -> some View {
        HStack(spacing: length * 0.02) {
            Image(systemName: stepBalance > 0 ? "arrow.up" : "arrow.down")
            Text("\(abs(stepBalance))")
        }
        .font(.system(size: max(10, length * 0.16), weight: .bold, design: .rounded))
        .foregroundStyle(.white)
        .padding(.horizontal, length * 0.08)
        .padding(.vertical, length * 0.03)
        .background(Color(packedRGB: 0x168A55).opacity(0.92), in: Capsule())
        .offset(y: -length * 0.21)
        .transition(.opacity.combined(with: .scale))
        .allowsHitTesting(false)
    }

    private func dragGesture(center: CGPoint, deadZone: CGFloat, linearThrow: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isTouching {
                    beginTouch()
                }

                let location = value.location
                let dx = Double(location.x - center.x)
                let dy = Double(location.y - center.y)
                let radius = hypot(dx, dy)

                if radius > Double(deadZone) {
                    // Rotate mode: circular tracking on the outer rim — sweep
                    // quickly through many steps.
                    lastLocation = nil
                    pendingLinear = 0
                    let angle = atan2(dy, dx)
                    guard let previous = lastDragAngle else {
                        lastDragAngle = angle
                        return
                    }
                    var delta = angle - previous
                    if delta > .pi { delta -= 2 * .pi }
                    if delta < -.pi { delta += 2 * .pi }
                    lastDragAngle = angle
                    pendingRotation += delta
                    rotation += delta * 180 / .pi
                    while pendingRotation >= stepAngle {
                        pendingRotation -= stepAngle
                        emitStep(true)
                    }
                    while pendingRotation <= -stepAngle {
                        pendingRotation += stepAngle
                        emitStep(false)
                    }
                } else {
                    // Fine mode: vertical scrub in the center disc. One detent per
                    // `linearThrow` points, up = increase — a predictable,
                    // controllable 1-at-a-time motion for exact selection.
                    lastDragAngle = nil
                    pendingRotation = 0
                    guard let last = lastLocation else {
                        lastLocation = location
                        return
                    }
                    pendingLinear += Double(last.y - location.y)
                    lastLocation = location
                    while pendingLinear >= Double(linearThrow) {
                        pendingLinear -= Double(linearThrow)
                        rotation += stepDegrees
                        emitStep(true)
                    }
                    while pendingLinear <= -Double(linearThrow) {
                        pendingLinear += Double(linearThrow)
                        rotation -= stepDegrees
                        emitStep(false)
                    }
                }
            }
            .onEnded { _ in
                endTouch()
            }
    }

    /// Emit one encoder detent: fire the host event, tick the haptic, and update
    /// the readout. The first step of a gesture cancels a pending press so a
    /// turn is never also read as a select.
    private func emitStep(_ clockwise: Bool) {
        if !isRotating {
            isRotating = true
            pendingPressTask?.cancel()
            if isPressed {
                isPressed = false
                onPress(false)
            }
        }
        onStep(clockwise)
        detentTick &+= 1
        stepBalance += clockwise ? 1 : -1
        revealReadout()
    }

    private func revealReadout() {
        balanceHideTask?.cancel()
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { showBalance = true }
        balanceHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeIn(duration: 0.25)) { showBalance = false }
        }
    }

    private func beginTouch() {
        isTouching = true
        isRotating = false
        lastDragAngle = nil
        lastLocation = nil
        pendingRotation = 0
        pendingLinear = 0
        stepBalance = 0
        touchStartedAt = Date()

        let task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled, isTouching, !isRotating else { return }
            isPressed = true
            pressStartedAt = Date()
            onPress(true)
            pressTick &+= 1
            // Crossing the 500 ms hold threshold opens Codex Micro settings on
            // the host; a heavier tick confirms the hold has registered.
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, isPressed, !isRotating else { return }
            settingsTick &+= 1
        }
        pendingPressTask = task
    }

    private func endTouch() {
        pendingPressTask?.cancel()
        pendingPressTask = nil

        let touchDuration = Date().timeIntervalSince(touchStartedAt ?? Date())

        if !isRotating {
            if isPressed {
                releasePress(afterMinimumHoldFor: touchDuration)
            } else {
                // A short tap may finish before the delayed down event. Send
                // down/up together, in order, so the selected composer control
                // is activated before any subsequent encoder gesture can emit
                // navigation steps.
                onPress(true)
                pressTick &+= 1
                onPress(false)
            }
        } else if isPressed {
            isPressed = false
            onPress(false)
        }

        isTouching = false
        isRotating = false
        lastDragAngle = nil
        lastLocation = nil
        pendingRotation = 0
        pendingLinear = 0
        touchStartedAt = nil

        // Rest the pointer exactly on the nearest detent so it never sits
        // between two ticks. Reduce Motion snaps without the settle spring.
        let snapped = (rotation / stepDegrees).rounded() * stepDegrees
        if reduceMotion {
            rotation = snapped
        } else {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.72)) { rotation = snapped }
        }
    }

    private func releasePress(afterMinimumHoldFor touchDuration: TimeInterval) {
        isPressed = false
        let rawDuration = Date().timeIntervalSince(pressStartedAt ?? Date())
        let remaining = touchDuration >= 0.5 ? max(0, 0.51 - rawDuration) : 0

        DispatchQueue.main.asyncAfter(deadline: .now() + remaining) {
            onPress(false)
        }
        pressStartedAt = nil
    }

    private func sendStep(clockwise: Bool) {
        onStep(clockwise)
        detentTick &+= 1
        stepBalance = clockwise ? 1 : -1
        revealReadout()
        rotation += clockwise ? stepDegrees : -stepDegrees
    }
}

private struct JoystickControl: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let onEvent: (Double, Double) -> Void

    @State private var knobOffset = CGSize.zero
    @State private var activeAngle: Double?
    @State private var activeDistance = 0.0
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geometry in
            let length = min(geometry.size.width, geometry.size.height)
            let travel = max(11, length * 0.26)

            ZStack {
                RoundedRectangle(cornerRadius: max(5, length * 0.13), style: .continuous)
                    .fill(Color.black.opacity(0.20))
                    .padding(length * 0.075)
                    .offset(y: length * 0.035)

                RoundedRectangle(cornerRadius: max(5, length * 0.13), style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(packedRGB: 0xE5E8E7), Color(packedRGB: 0xB2B8B7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .padding(length * 0.075)

                RoundedRectangle(cornerRadius: max(6, length * 0.18), style: .continuous)
                    .stroke(
                        Color.black.opacity(0.62),
                        style: StrokeStyle(lineWidth: max(1, length * 0.018), dash: [3, 2.5])
                    )
                    .padding(length * 0.11)

                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color(packedRGB: 0x6A706F), Color(packedRGB: 0x252827)],
                                center: .topLeading,
                                startRadius: 0,
                                endRadius: length * 0.34
                            )
                        )
                        .frame(width: length * 0.58, height: length * 0.58)

                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color(packedRGB: 0x333736), Color(packedRGB: 0x080909)],
                                center: UnitPoint(x: 0.34, y: 0.26),
                                startRadius: 0,
                                endRadius: length * 0.30
                            )
                        )
                        .overlay(Circle().stroke(Color.white.opacity(0.13), lineWidth: 1))
                        .frame(width: length * 0.46, height: length * 0.46)

                    ForEach(0..<4, id: \.self) { index in
                        Capsule()
                            .fill(Color.white.opacity(0.15))
                            .frame(width: length * 0.12, height: max(1.2, length * 0.022))
                            .offset(y: -length * 0.145)
                            .rotationEffect(.degrees(45 + Double(index) * 90))
                    }
                }
                .frame(width: length * 0.62, height: length * 0.62)
                .shadow(color: .black.opacity(0.30), radius: 3, y: 3)
                .offset(knobOffset)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(joystickGesture(maxTravel: travel))
            // Animating while the finger is down makes the knob trail the touch,
            // which reads as jitter; ease only the spring back to center.
            .animation(reduceMotion || isDragging ? nil : .easeOut(duration: 0.14), value: knobOffset)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Workflow joystick")
        .accessibilityValue("Continuous analog control")
        .accessibilityHint("Drag in any direction or circle continuously")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Plan mode") { pulse(angle: 0.75) }
        .accessibilityAction(named: "Navigate forward") { pulse(angle: 0.0) }
        .accessibilityAction(named: "Toggle sidebar") { pulse(angle: 0.25) }
        .accessibilityAction(named: "Navigate back") { pulse(angle: 0.5) }
        .onDisappear {
            if let activeAngle { onEvent(activeAngle, 0) }
        }
    }

    private func joystickGesture(maxTravel: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                isDragging = true
                let dx = value.translation.width
                let dy = value.translation.height
                let distance = hypot(dx, dy)

                if distance > 0 {
                    let scale = min(1, maxTravel / distance)
                    knobOffset = CGSize(width: dx * scale, height: dy * scale)
                }

                if let current = activeAngle {
                    // Only the physical return to center releases the stick.
                    // Moving through a diagonal or around the rim stays one
                    // continuous analog gesture, which is required by the
                    // host's circular-spin mini-game detector.
                    if distance <= max(3, maxTravel * 0.18) {
                        onEvent(current, 0)
                        activeAngle = nil
                        activeDistance = 0
                        return
                    }

                    let nextAngle = analogAngle(dx: dx, dy: dy)
                    let nextDistance = min(1, Double(distance / maxTravel))
                    if circularDistance(from: current, to: nextAngle) >= 0.004
                        || abs(nextDistance - activeDistance) >= 0.015 {
                        activeAngle = nextAngle
                        activeDistance = nextDistance
                        onEvent(nextAngle, nextDistance)
                    }
                } else if distance >= max(4, maxTravel * 0.30) {
                    let nextAngle = analogAngle(dx: dx, dy: dy)
                    let nextDistance = min(1, Double(distance / maxTravel))
                    activeAngle = nextAngle
                    activeDistance = nextDistance
                    onEvent(nextAngle, nextDistance)
                }
            }
            .onEnded { _ in
                isDragging = false
                if let activeAngle { onEvent(activeAngle, 0) }
                activeAngle = nil
                activeDistance = 0
                knobOffset = .zero
            }
    }

    /// Continuous normalized turns: right 0, down .25, left .5, up .75, with
    /// every diagonal preserved rather than collapsed onto a cardinal axis.
    private func analogAngle(dx: CGFloat, dy: CGFloat) -> Double {
        let turns = atan2(Double(dy), Double(dx)) / (2 * Double.pi)
        return turns >= 0 ? turns : turns + 1
    }

    /// Shortest distance between two normalized angles, including wraparound
    /// from values near 1 back to values near 0.
    private func circularDistance(from first: Double, to second: Double) -> Double {
        let delta = abs(first - second)
        return min(delta, 1 - delta)
    }

    private func pulse(angle: Double) {
        onEvent(angle, 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            onEvent(angle, 0)
        }
    }
}

private struct BoardScrew: View {
    var body: some View {
        GeometryReader { geometry in
            let length = min(geometry.size.width, geometry.size.height)

            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.28))
                    .offset(y: length * 0.12)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(packedRGB: 0x777D7B),
                                Color(packedRGB: 0x303432),
                                Color(packedRGB: 0x111312)
                            ],
                            center: UnitPoint(x: 0.32, y: 0.25),
                            startRadius: 0,
                            endRadius: length * 0.58
                        )
                    )
                    .overlay(Circle().stroke(Color.black.opacity(0.58), lineWidth: 1))

                Circle()
                    .fill(Color.black.opacity(0.52))
                    .frame(width: length * 0.58, height: length * 0.58)

                HexSocket()
                    .fill(Color(packedRGB: 0x090A09))
                    .overlay(HexSocket().stroke(Color.white.opacity(0.08), lineWidth: 0.75))
                    .frame(width: length * 0.43, height: length * 0.43)
            }
        }
    }
}

private struct HexSocket: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()

        for index in 0..<6 {
            let angle = CGFloat(index) * .pi / 3 - .pi / 2
            let point = CGPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            )
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Setup and diagnostics

private struct DeviceDetailsSheet: View {
    /// The page the settings were opened from. Page-specific sections (Codex
    /// microphone, T3 connection) key off this.
    let page: ControlPage
    @EnvironmentObject private var peripheral: CodexMicroPeripheral
    @Environment(\.dismiss) private var dismiss
    @AppStorage("codexMicro.codexMicSource") private var codexMicSourceRaw = CodexMicSource.computer.rawValue
    @State private var t3PairingInput = ""
    @State private var t3PairingStatus: String?
    @AppStorage("codexMicro.controlSurfaceMode") private var surfaceModeRaw = ControlSurfaceMode.framed.rawValue
    @AppStorage("codexMicro.vscodeLauncher") private var vscodeLauncherRaw = WorkspaceLauncher.claudeExtension.rawValue
    @AppStorage("codexMicro.vscodeCustomCommand") private var vscodeCustomLauncherValue = ""
    @AppStorage("codexMicro.t3CodeLauncher") private var t3CodeLauncherRaw = WorkspaceLauncher.t3NewSession.rawValue
    @AppStorage("codexMicro.t3CodeCustomCommand") private var t3CodeCustomLauncherValue = ""
    @AppStorage("codexMicro.claudeCodeLauncher") private var claudeCodeLauncherRaw = WorkspaceLauncher.claudeNewSession.rawValue
    @AppStorage("codexMicro.claudeCodeCustomLink") private var claudeCodeCustomLauncherValue = ""
    @AppStorage("codexMicro.voiceAutoSend") private var voiceAutoSend = false
    @AppStorage("codexMicro.useMacProviderVoice") private var useMacProviderVoice = false

    var body: some View {
        NavigationStack {
            List {
                Section("Display mode") {
                    Picker("Control surface view", selection: $surfaceModeRaw) {
                        ForEach(ControlSurfaceMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(selectedSurfaceMode.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // VS Code and T3 Code setup remain persisted but are hidden with
                // their parked pages.

                launcherSection(
                    page: .claudeCode,
                    launcherRaw: $claudeCodeLauncherRaw,
                    customValue: $claudeCodeCustomLauncherValue
                )

                Section("Claude Desktop session pins") {
                    let pinCount = peripheral.workspaceState(for: ControlPage.claudeCode.hostTarget)
                        .pins.compactMap { $0 }.count
                    LabeledContent("Saved exact sessions", value: "\(pinCount) / 6")

                    Text("Open a Claude Code conversation on the Mac and press PIN. The Mac helper identifies that exact conversation automatically; the six agent keys reopen the sessions assigned to them.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section("Voice prompts") {
                    Toggle("Auto-send after dictation", isOn: $voiceAutoSend)

                    Text("On the Claude page, the voice key controls Claude Desktop's own dictation using the Mac's current microphone. Hold to talk, tap to stop, or double-tap to latch it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if page == .codex {
                    Section("Microphone") {
                        Picker("Dictate from", selection: $codexMicSourceRaw) {
                            ForEach(CodexMicSource.allCases) { source in
                                Text(source.title).tag(source.rawValue)
                            }
                        }

                        Text(selectedCodexMicSource.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if selectedCodexMicSource == .iphone {
                            Text("The MIC key records on this iPhone and transcribes on-device, then types the text into ChatGPT's composer — so you speak into the phone you're holding, not the Mac. Requires the ChatGPT bridge shim (re-run tools/patch-chatgpt.sh once, and again after ChatGPT updates).")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if page == .t3Code {
                    t3ConnectionSection
                }

                if let issue = peripheral.blockingIssue, !issue.isEmpty {
                    Section {
                        Label {
                            Text(issue)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                }

                Section("Connection") {
                    detailRow("Bluetooth", value: bluetoothState, symbol: "antenna.radiowaves.left.and.right")
                    detailRow("Services", value: peripheral.publishedServicesReady ? "Ready" : "Starting", symbol: "wave.3.right")
                    detailRow("Pairing", value: peripheral.isAdvertising ? "Discoverable" : "Not advertising", symbol: "dot.radiowaves.left.and.right")
                    detailRow(
                        "Mac transport",
                        value: peripheral.hostConnected ? "Linked" : "Not linked",
                        symbol: peripheral.hostConnected ? "link" : "link.slash"
                    )
                    detailRow(
                        "ChatGPT",
                        value: peripheral.macConnectionState.isOperational ? "Operational" : peripheral.macConnectionDetail,
                        symbol: peripheral.macConnectionState.isOperational ? "checkmark.circle.fill" : "hourglass"
                    )
                    detailRow("iPhone battery", value: "\(peripheral.batteryPercent)%", symbol: "battery.100percent")
                }

                if let issue = peripheral.blockingIssue, !issue.isEmpty {
                    Section("Connection unavailable") {
                        Text(connectionLimitation(for: issue))
                            .fixedSize(horizontal: false, vertical: true)

                        Label(
                            "The hardware face remains available for layout and interaction testing, but controls cannot reach ChatGPT without a macOS HID connection.",
                            systemImage: "info.circle"
                        )
                        .foregroundStyle(.secondary)
                    }
                } else if peripheral.publishedServicesReady || peripheral.isAdvertising || peripheral.hostConnected {
                    Section(peripheral.bridgeMode ? "Connect via the Mac helper" : "Connect to your Mac") {
                        if peripheral.bridgeMode {
                            setupStep(1, "Keep Codex Micro Remote open on this iPhone.")
                            setupStep(2, "On your Mac, build the helper once from the repo: swiftc -O tools/CodexMicroBridge/main.swift tools/CodexMicroBridge/T3Backend.swift -o tools/CodexMicroBridge/codexbridge")
                            setupStep(3, "One time only, patch ChatGPT so it accepts the helper: ./tools/patch-chatgpt.sh (re-run it after each ChatGPT update).")
                            setupStep(4, "Run ./tools/CodexMicroBridge/codexbridge — no sudo needed. It links to this iPhone and relays it to ChatGPT.")
                        } else {
                            setupStep(1, "Keep Codex Micro Remote open on this iPhone.")
                            setupStep(2, "On your Mac, open System Settings › Bluetooth and select “Codex Micro.”")
                            setupStep(3, "Confirm pairing, then open ChatGPT and follow its Codex Micro setup prompt.")
                        }

                        if peripheral.canControlChatGPT {
                            Label("Fully connected. ChatGPT and this iPhone completed a two-way data check.", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(Color(packedRGB: 0x168A55))
                        } else if peripheral.hostConnected {
                            Label(peripheral.macConnectionDetail, systemImage: "arrow.triangle.2.circlepath")
                                .foregroundStyle(.orange)
                        }
                    }
                } else {
                    Section("Preparing Bluetooth") {
                        Label("The app is publishing its Bluetooth services. Connection steps appear once they are ready.", systemImage: "hourglass")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Agent lights") {
                    legendRow(color: .white, title: "Idle")
                    legendRow(color: Color(packedRGB: 0x304FFE), title: "Thinking")
                    legendRow(color: Color(packedRGB: 0x00D941), title: "Complete, unread")
                    legendRow(color: Color(packedRGB: 0xFF8F00), title: "Needs input")
                    legendRow(color: Color(packedRGB: 0xFF0033), title: "Error")
                    legendRow(color: Color(packedRGB: 0xA8B0AE), title: "Off · unassigned")
                }

                Section("Lighting") {
                    LabeledContent {
                        if let brightness = peripheral.lightingBrightness {
                            Text("\(Int((brightness * 100).rounded()))%")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        } else {
                            Text("Waiting for ChatGPT")
                                .foregroundStyle(.secondary)
                        }
                    } label: {
                        Label("Brightness", systemImage: "sun.max.fill")
                    }

                    Text("Set brightness in ChatGPT’s Codex Micro settings.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Key bindings") {
                    ForEach(CodexMicroLayout.slotOrder, id: \.self) { slotId in
                        let binding = peripheral.layout.binding(forSlot: slotId)
                        let descriptor = KeycapCatalog.descriptor(for: binding.keycapId)
                        LabeledContent {
                            Text(binding.commandId.map(prettyCommand) ?? descriptor.accessibilityName)
                                .foregroundStyle(.secondary)
                        } label: {
                            Label(descriptor.label, systemImage: descriptor.symbol)
                        }
                    }
                    ForEach(CodexMicroLayout.stickOrder, id: \.self) { direction in
                        LabeledContent {
                            Text(prettyCommand(peripheral.layout.action(forDirection: direction)?.commandId))
                                .foregroundStyle(.secondary)
                        } label: {
                            Label("Stick \(direction)", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                        }
                    }
                }

                Section("Controls") {
                    controlRow("Agent keys", detail: "Press to switch; double-press within 350 ms to bring ChatGPT forward.")
                    controlRow("Dial", detail: "Turn to navigate composer controls; press to open; hold 500 ms for settings.")
                    controlRow("Joystick", detail: "Up Plan · right Forward · down Sidebar · left Back.")
                    controlRow("Command row", detail: "Fast · Approve · Decline · Continue in new chat.")
                    controlRow("Microphone", detail: voiceAutoSend
                        ? "Hold to talk; recognized prompts send automatically. Double-press to latch."
                        : "Hold to talk; double-press to latch; press again to stop.")
                    controlRow("Codex", detail: "Sends the current composer message.")
                    controlRow("Touch sensor", detail: "On this iPhone remote it opens pairing details; macOS manages the Bluetooth channel.")
                }

                Section("Protocol log") {
                    if peripheral.logEntries.isEmpty {
                        ContentUnavailableView(
                            "No activity yet",
                            systemImage: "waveform.path",
                            description: Text("Pair your Mac to see connection and control messages.")
                        )
                    } else {
                        ForEach(Array(peripheral.logEntries.enumerated()), id: \.offset) { _, entry in
                            Text(entry)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle("Codex Micro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var bluetoothState: String {
        switch peripheral.managerState {
        case .unknown: return "Starting"
        case .resetting: return "Resetting"
        case .unsupported: return "Unsupported"
        case .unauthorized: return "Permission required"
        case .poweredOff: return "Off"
        case .poweredOn: return "On"
        @unknown default: return "Unavailable"
        }
    }

    private var selectedSurfaceMode: ControlSurfaceMode {
        ControlSurfaceMode(rawValue: surfaceModeRaw) ?? .framed
    }

    private var selectedCodexMicSource: CodexMicSource {
        CodexMicSource(rawValue: codexMicSourceRaw) ?? .computer
    }

    // MARK: T3 Code connection

    @ViewBuilder
    private var t3ConnectionSection: some View {
        let state = peripheral.workspaceState(for: ControlPage.t3Code.hostTarget)
        Section("T3 Code connection") {
            LabeledContent("Status", value: t3StatusText(state))

            TextField("http://192.168.x.x:3773/pair#token=…", text: $t3PairingInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .keyboardType(.URL)
                .font(.footnote.monospaced())
                .lineLimit(1)

            Button {
                pairT3()
            } label: {
                Label(peripheral.t3IsPaired ? "Re-pair" : "Pair", systemImage: "link")
            }
            .disabled(t3PairingInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if peripheral.t3IsPaired {
                Button(role: .destructive) {
                    peripheral.unpairT3()
                    t3PairingStatus = "Forgotten. Paste a pairing URL to reconnect."
                } label: {
                    Label("Forget server", systemImage: "trash")
                }
            }

            if let status = t3PairingStatus {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("On the Mac, start the T3 server so it prints a LAN pairing URL:\n  node apps/server/src/bin.ts serve --host 0.0.0.0 --port 3773\nPaste its “Pairing URL” above. This iPhone then talks straight to T3 over your local network — no Mac bridge involved.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func t3StatusText(_ state: WorkspaceBridgeState) -> String {
        if state.connected { return "Connected" }
        if let issue = state.issue, !issue.isEmpty { return issue }
        return peripheral.t3IsPaired ? "Connecting…" : "Not paired"
    }

    private func pairT3() {
        let url = t3PairingInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        t3PairingStatus = "Pairing… watch Status above."
        // Fire-and-forget: the live poll flips Status to Connected (or surfaces a
        // pairing issue) via the reactive workspace state.
        peripheral.pairT3(url)
        t3PairingInput = ""
    }

    @ViewBuilder
    private func launcherSection(
        page: ControlPage,
        launcherRaw: Binding<String>,
        customValue: Binding<String>
    ) -> some View {
        let selectedLauncher = selectedLauncher(for: page, rawValue: launcherRaw.wrappedValue)

        Section(page.surfaceName) {
            Picker("New button", selection: launcherRaw) {
                ForEach(WorkspaceLauncher.options(for: page)) { launcher in
                    Text(launcher.title).tag(launcher.rawValue)
                }
            }

            if selectedLauncher.requiresCustomValue {
                TextField(selectedLauncher.customValuePlaceholder, text: customValue)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }

            Text("Swipe to the \(page.surfaceName) page. NEW uses only this page’s launcher; PIN assigns the selected session to the first free agent key and toggles it off when pressed again.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func selectedLauncher(for page: ControlPage, rawValue: String) -> WorkspaceLauncher {
        if let launcher = WorkspaceLauncher(rawValue: rawValue), launcher.page == page {
            return launcher
        }
        return WorkspaceLauncher.defaultLauncher(for: page)
    }

    private func connectionLimitation(for issue: String) -> String {
        if peripheral.managerState == .unsupported {
            return "The iOS Simulator has no Bluetooth peripheral mode. On a physical iPhone, public CoreBluetooth also rejects the mandatory HID Report Reference descriptors that macOS needs to recognize a Codex Micro, so a normal iOS build cannot complete this pairing path."
        }

        let normalized = issue.lowercased()
        if normalized.contains("hid")
            || normalized.contains("0x1812")
            || normalized.contains("0x2908")
            || normalized.contains("report reference") {
            return "Public iOS CoreBluetooth cannot publish the complete HID profile macOS needs to recognize a Codex Micro. This build cannot complete the ChatGPT pairing flow; use supported HID hardware or an Apple-approved accessory path."
        }

        return "Resolve the Bluetooth issue above before attempting to connect. The app does not claim a working Mac link until a host has subscribed to its HID input report."
    }

    private func detailRow(_ title: String, value: String, symbol: String) -> some View {
        LabeledContent {
            Text(value)
                .foregroundStyle(.secondary)
        } label: {
            Label(title, systemImage: symbol)
        }
    }

    private func setupStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color(packedRGB: 0x168A55), in: Circle())
                .accessibilityHidden(true)

            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func legendRow(color: Color, title: String) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(color)
                .overlay(Circle().stroke(Color.primary.opacity(0.18), lineWidth: 1))
                .frame(width: 18, height: 18)
            Text(title)
        }
    }

    private func controlRow(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.body.weight(.semibold))
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    ContentView()
        .environmentObject(CodexMicroPeripheral())
}
