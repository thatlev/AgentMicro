import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            SetupSettingsTab(model: model)
                .tabItem {
                    Label("Setup", systemImage: "rectangle.connected.to.line.below")
                }

            GeneralSettingsTab(model: model)
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            IntegrationSettingsTab(model: model)
                .tabItem {
                    Label("Integration", systemImage: "link")
                }

            AdvancedSettingsTab(model: model)
                .tabItem {
                    Label("Advanced", systemImage: "ellipsis.circle")
                }
        }
        .padding(.top, 8)
        .frame(minWidth: 590, idealWidth: 620, minHeight: 440, idealHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct SetupSettingsTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SettingsPage(title: "Connection", subtitle: "Green means the complete route exchanged real data.") {
            SettingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: overallTone.systemImage)
                            .font(.title2)
                            .foregroundStyle(overallTone.color)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.headline)
                                .font(.headline)
                            Text(model.detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer()
                        StatusPill(text: statusLabel, tone: overallTone)
                    }

                    Divider()
                    ConnectionRail(stages: connectionStages)
                }
            }

            HStack(spacing: 10) {
                ActionButton(
                    title: "Check connection",
                    systemImage: "arrow.clockwise",
                    help: "Recheck the iPhone, Mac bridge, and ChatGPT route.",
                    isDisabled: model.isBusy
                ) {
                    model.reconnect()
                }

                ActionButton(
                    title: "Open ChatGPT",
                    systemImage: "arrow.up.forward.app",
                    help: "Open ChatGPT without changing its integration.",
                    isDisabled: model.isBusy
                ) {
                    model.openChatGPT()
                }
            }

            if model.showOnboarding {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Setup is ready to finish")
                            .font(.callout.weight(.medium))
                        Text("You can return here whenever the connection needs attention.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Finish Setup") {
                        model.completeOnboarding()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private var overallTone: StatusTone {
        switch model.overallState {
        case .healthy: return .healthy
        case .connecting: return .connecting
        case .actionRequired: return .actionRequired
        case .failed: return .failed
        case .idle: return .idle
        }
    }

    private var statusLabel: String {
        switch model.overallState {
        case .healthy: return "Connected"
        case .connecting: return "Connecting"
        case .actionRequired: return "Action needed"
        case .failed: return "Failed"
        case .idle: return model.isPaused ? "Paused" : "Idle"
        }
    }

    private var connectionStages: [ConnectionRail.Stage] {
        [
            .init(
                id: "phone",
                title: "iPhone",
                detail: model.phoneStatus,
                icon: "iphone",
                tone: StatusTone.inferred(from: model.phoneStatus, fallback: overallTone)
            ),
            .init(
                id: "bridge",
                title: "Mac",
                detail: statusLabel,
                icon: "macbook",
                tone: overallTone
            ),
            .init(
                id: "chatgpt",
                title: "ChatGPT",
                detail: model.chatGPTStatus,
                icon: "bubble.left.and.bubble.right",
                tone: StatusTone.inferred(from: model.chatGPTStatus, fallback: overallTone)
            ),
        ]
    }
}

private struct GeneralSettingsTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SettingsPage(title: "General", subtitle: "Keep the companion ready without unnecessary background work.") {
            SettingsCard {
                VStack(spacing: 0) {
                    settingsToggle(
                        title: "Launch at Login",
                        detail: "Start AgentMicro when you sign in to this Mac.",
                        isOn: Binding(
                            get: { model.launchAtLogin },
                            set: { model.setLaunchAtLogin($0) }
                        )
                    )

                    Divider().padding(.vertical, 12)

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.isPaused ? "Bridge paused" : "Bridge active")
                                .font(.callout.weight(.medium))
                            Text(
                                model.isPaused
                                    ? "No control messages are being forwarded."
                                    : "Listening only for the lightweight iPhone and ChatGPT bridge."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(model.isPaused ? "Resume" : "Pause") {
                            model.togglePause()
                        }
                        .disabled(model.isBusy)
                    }
                }
            }
        }
    }

    private func settingsToggle(
        title: String,
        detail: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}

private struct IntegrationSettingsTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SettingsPage(
            title: "ChatGPT Integration",
            subtitle: "AgentMicro changes ChatGPT only when you explicitly confirm it."
        ) {
            SettingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    StatusRow(
                        icon: "bubble.left.and.bubble.right",
                        title: "ChatGPT",
                        value: model.chatGPTStatus,
                        tone: chatGPTTone
                    )
                    StatusRow(
                        icon: "wrench.and.screwdriver",
                        title: "Integration",
                        value: model.patchStatusText,
                        tone: patchTone
                    )

                    if model.integrationNeedsUpdate {
                        Label {
                            Text(
                                "Update required: restore the version-matched backup first, then patch again. This should happen only after ChatGPT or AgentMicro changes."
                            )
                            .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(StatusTone.actionRequired.color)
                        }
                        .font(.caption)
                    } else {
                        Text(
                            "ChatGPT updates remove the local integration. AgentMicro detects the new build and asks before restoring or patching; it never force-quits ChatGPT."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    // Matches the menu popover: never leave the user facing two
                    // disabled buttons with no stated way forward.
                    if model.hasNoPatchAction {
                        Text(model.patchBlockedReason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("How to fix: \(model.patchBlockedReason)")
                        if model.canCopyAgentRepairPrompt {
                            AgentRepairPromptButton(model: model)
                        }
                    } else {
                        PatchActionButtons(model: model, compact: true)
                    }
                }
            }
        }
    }

    private var overallTone: StatusTone {
        switch model.overallState {
        case .healthy: return .healthy
        case .connecting: return .connecting
        case .actionRequired: return .actionRequired
        case .failed: return .failed
        case .idle: return .idle
        }
    }

    private var chatGPTTone: StatusTone {
        StatusTone.inferred(from: model.chatGPTStatus, fallback: overallTone)
    }

    private var patchTone: StatusTone {
        StatusTone.inferred(from: model.patchStatusText, fallback: overallTone)
    }
}

private struct AdvancedSettingsTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SettingsPage(title: "Advanced", subtitle: "Local troubleshooting and app information.") {
            SettingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Diagnostics stay on this Mac and contain no message content.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        ActionButton(
                            title: "Copy diagnostics",
                            systemImage: "doc.on.doc",
                            help: "Copy a redacted connection report.",
                            isDisabled: model.isBusy
                        ) {
                            model.copyDiagnostics()
                        }
                        ActionButton(
                            title: "Open logs",
                            systemImage: "folder",
                            help: "Reveal local rotating logs in Finder.",
                            isDisabled: model.isBusy
                        ) {
                            model.openLogs()
                        }
                    }
                }
            }

            HStack {
                Text("AgentMicro \(versionText)")
                Spacer()
                Text("Apple silicon")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 2)
        }
    }

    private var versionText: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (version, build) {
        case let (.some(version), .some(build)): return "\(version) (\(build))"
        case let (.some(version), .none): return version
        default: return "Development"
        }
    }
}

private struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String
    let content: Content

    init(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                content
            }
            .padding(24)
        }
    }
}

private struct SettingsCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }
}
