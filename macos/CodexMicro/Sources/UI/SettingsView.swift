import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    let onOpenOnboarding: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                heading
                connectionSection
                generalSection
                chatGPTSection
                diagnosticsSection
                aboutSection
            }
            .padding(22)
        }
        .frame(minWidth: 440, idealWidth: 470, minHeight: 510, idealHeight: 570)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var heading: some View {
        HStack(spacing: 12) {
            MicroGlyphView(size: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text("Codex Micro")
                    .font(.title3.weight(.semibold))
                Text(model.headline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            StatusPill(text: statusLabel, tone: overallTone)
        }
    }

    private var connectionSection: some View {
        settingsSection("Connection") {
            ConnectionRail(stages: connectionStages)
                .padding(.vertical, 2)

            Divider()

            StatusRow(
                icon: "arrow.left.arrow.right",
                title: "Last verified round trip",
                value: model.lastRoundTripText
            )

            HStack(spacing: 8) {
                ActionButton(
                    title: "Reconnect",
                    systemImage: "arrow.clockwise",
                    help: "Recheck every part of the connection.",
                    isDisabled: model.isBusy
                ) {
                    model.reconnect()
                }

                ActionButton(
                    title: "Open ChatGPT",
                    systemImage: "arrow.up.forward.app",
                    help: "Open ChatGPT.",
                    isDisabled: model.isBusy
                ) {
                    model.openChatGPT()
                }
            }
        }
    }

    private var generalSection: some View {
        settingsSection("General") {
            Toggle(
                "Launch Codex Micro at login",
                isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                )
            )
            .toggleStyle(.switch)
            .help("Keep Codex Micro available after you sign in to this Mac.")

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.isPaused ? "Bridge is paused" : "Bridge is active")
                        .font(.callout.weight(.medium))
                    Text(
                        model.isPaused
                            ? "No connection events are being forwarded."
                            : "Codex Micro is available from the menu bar."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Button(model.isPaused ? "Resume" : "Pause") {
                    model.togglePause()
                }
                .disabled(model.isBusy)
                .help(model.isPaused ? "Resume connection handling." : "Pause connection handling.")
            }
        }
    }

    private var chatGPTSection: some View {
        settingsSection("ChatGPT Integration") {
            StatusRow(
                icon: "bubble.left.and.bubble.right",
                title: "ChatGPT",
                value: model.chatGPTStatus,
                tone: chatGPTTone
            )
            StatusRow(
                icon: "wrench.and.screwdriver",
                title: "Patch",
                value: model.patchStatusText,
                tone: patchTone
            )

            Text(
                "Patching is always manual. Codex Micro asks ChatGPT to close and never force-quits it."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            PatchActionButtons(model: model, compact: true)
        }
    }

    private var diagnosticsSection: some View {
        settingsSection("Diagnostics") {
            Text(
                "Diagnostics stay on this Mac. Codex Micro does not send telemetry."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ActionButton(
                    title: "Copy diagnostics",
                    systemImage: "doc.on.doc",
                    help: "Copy a redacted diagnostic report.",
                    isDisabled: model.isBusy
                ) {
                    model.copyDiagnostics()
                }

                ActionButton(
                    title: "Open logs",
                    systemImage: "folder",
                    help: "Reveal local rotating logs.",
                    isDisabled: model.isBusy
                ) {
                    model.openLogs()
                }
            }
        }
    }

    private var aboutSection: some View {
        HStack {
            Text("Version \(versionText)")
            Spacer()
            Button("Run Setup Guide…", action: onOpenOnboarding)
                .buttonStyle(.link)
                .help("Review pairing, permissions, and ChatGPT integration.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private func settingsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel(title: title)
            QuietCard {
                VStack(alignment: .leading, spacing: 11, content: content)
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
        case .healthy: return "Verified"
        case .connecting: return "Connecting"
        case .actionRequired: return "Action needed"
        case .failed: return "Failed"
        case .idle: return model.isPaused ? "Paused" : "Idle"
        }
    }

    private var chatGPTTone: StatusTone {
        StatusTone.inferred(from: model.chatGPTStatus, fallback: overallTone)
    }

    private var patchTone: StatusTone {
        StatusTone.inferred(from: model.patchStatusText, fallback: overallTone)
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
                tone: chatGPTTone
            ),
        ]
    }

    private var versionText: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (version, build) {
        case let (.some(version), .some(build)):
            return "\(version) (\(build))"
        case let (.some(version), .none):
            return version
        default:
            return "Development"
        }
    }
}
