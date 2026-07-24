import SwiftUI

struct MenuPopoverView: View {
    @ObservedObject var model: AppModel
    let onOpenSettings: () -> Void
    let onOpenOnboarding: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    summary
                    connection
                    details
                    actions
                    preferences
                }
                .padding(14)
            }

            Divider()
            footer
        }
        .frame(width: 360)
        .frame(maxHeight: 650)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            MicroGlyphView(size: 19)

            VStack(alignment: .leading, spacing: 1) {
                Text("Codex Micro")
                    .font(.system(size: 13, weight: .semibold))
                Text("Mac companion")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            StatusPill(text: statusLabel, tone: overallTone)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var summary: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: overallTone.systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(overallTone.color)
                .padding(.top, 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(model.headline)
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)

                Text(model.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            if model.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Codex Micro is working")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel(title: "Connection")

            QuietCard {
                ConnectionRail(stages: connectionStages)
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel(title: "Status")

            QuietCard {
                VStack(spacing: 9) {
                    StatusRow(
                        icon: "iphone",
                        title: "iPhone",
                        value: model.phoneStatus,
                        tone: phoneTone
                    )
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
                    StatusRow(
                        icon: "arrow.left.arrow.right",
                        title: "Last round trip",
                        value: model.lastRoundTripText
                    )
                }
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel(title: "Actions")

            HStack(spacing: 8) {
                ActionButton(
                    title: "Reconnect",
                    systemImage: "arrow.clockwise",
                    help: "Recheck the iPhone, bridge, and ChatGPT connection.",
                    isDisabled: model.isBusy
                ) {
                    model.reconnect()
                }

                ActionButton(
                    title: "Open ChatGPT",
                    systemImage: "arrow.up.forward.app",
                    help: "Open ChatGPT without changing the current connection.",
                    isDisabled: model.isBusy
                ) {
                    model.openChatGPT()
                }
            }

            PatchActionButtons(model: model, compact: true)

            HStack(spacing: 8) {
                ActionButton(
                    title: "Copy diagnostics",
                    systemImage: "doc.on.doc",
                    help: "Copy redacted diagnostic information to the clipboard.",
                    isDisabled: model.isBusy
                ) {
                    model.copyDiagnostics()
                }

                ActionButton(
                    title: "Open logs",
                    systemImage: "doc.text.magnifyingglass",
                    help: "Reveal Codex Micro's local logs.",
                    isDisabled: model.isBusy
                ) {
                    model.openLogs()
                }
            }
        }
    }

    private var preferences: some View {
        QuietCard {
            VStack(spacing: 10) {
                Toggle(
                    "Launch at Login",
                    isOn: Binding(
                        get: { model.launchAtLogin },
                        set: { model.setLaunchAtLogin($0) }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Keep Codex Micro available after you sign in to this Mac.")

                Divider()

                Button {
                    model.togglePause()
                } label: {
                    Label(
                        model.isPaused ? "Resume bridge" : "Pause bridge",
                        systemImage: model.isPaused ? "play.fill" : "pause.fill"
                    )
                    .font(.caption.weight(.medium))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.isPaused ? Color.accentColor : Color.secondary)
                .disabled(model.isBusy)
                .help(model.isPaused ? "Resume connection handling." : "Temporarily stop connection handling.")
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button("Setup Guide", action: onOpenOnboarding)
                .buttonStyle(.plain)
                .help("Open the Codex Micro setup guide.")

            Button("Settings…", action: onOpenSettings)
                .buttonStyle(.plain)
                .keyboardShortcut(",", modifiers: .command)
                .help("Open Codex Micro settings.")

            Spacer()

            Button("Quit", action: model.quit)
                .buttonStyle(.plain)
                .keyboardShortcut("q", modifiers: .command)
                .disabled(model.isBusy)
                .help("Quit Codex Micro.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var overallTone: StatusTone {
        switch model.overallState {
        case .healthy:
            return .healthy
        case .connecting:
            return .connecting
        case .actionRequired:
            return .actionRequired
        case .failed:
            return .failed
        case .idle:
            return .idle
        }
    }

    private var statusLabel: String {
        switch model.overallState {
        case .healthy:
            return "Verified"
        case .connecting:
            return "Connecting"
        case .actionRequired:
            return "Action needed"
        case .failed:
            return "Failed"
        case .idle:
            return model.isPaused ? "Paused" : "Idle"
        }
    }

    private var phoneTone: StatusTone {
        StatusTone.inferred(from: model.phoneStatus, fallback: overallTone)
    }

    private var chatGPTTone: StatusTone {
        StatusTone.inferred(from: model.chatGPTStatus, fallback: overallTone)
    }

    private var patchTone: StatusTone {
        StatusTone.inferred(from: model.patchStatusText, fallback: overallTone)
    }

    private var connectionStages: [ConnectionRail.Stage] {
        [
            ConnectionRail.Stage(
                id: "phone",
                title: "iPhone",
                detail: model.phoneStatus,
                icon: "iphone",
                tone: phoneTone
            ),
            ConnectionRail.Stage(
                id: "bridge",
                title: "Mac",
                detail: bridgeDetail,
                icon: "macbook",
                tone: overallTone
            ),
            ConnectionRail.Stage(
                id: "chatgpt",
                title: "ChatGPT",
                detail: model.chatGPTStatus,
                icon: "bubble.left.and.bubble.right",
                tone: chatGPTTone
            ),
        ]
    }

    private var bridgeDetail: String {
        switch model.overallState {
        case .healthy:
            return "Verified"
        case .connecting:
            return "Checking"
        case .actionRequired:
            return "Needs attention"
        case .failed:
            return "Route failed"
        case .idle:
            return model.isPaused ? "Paused" : "Waiting"
        }
    }
}
