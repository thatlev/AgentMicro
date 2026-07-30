import SwiftUI

/// The menu-bar surface is deliberately a glanceable health check, not a
/// second settings window. The three dots are the same source of truth as the
/// full Setup tab: iPhone, Mac bridge, and ChatGPT.
struct MenuPopoverView: View {
    @ObservedObject var model: AppModel
    let onOpenSettings: () -> Void
    let onQuit: () -> Void
    let onDialogPresented: () -> Void
    let onDialogDismissed: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            statusSummary
                .padding(16)

            if showsIntegrationAction {
                Divider()
                integrationAction
                    .padding(14)
            }

            Divider()

            VStack(spacing: 2) {
                if model.overallState != .healthy {
                    menuRow(
                        model.isBusy ? "Checking…" : "Check connection",
                        systemImage: "arrow.clockwise",
                        disabled: model.isBusy
                    ) {
                        model.reconnect()
                    }
                }

                menuRow("Settings…", systemImage: "gearshape") {
                    onOpenSettings()
                }
                .keyboardShortcut(",", modifiers: .command)

                menuRow(
                    model.isPaused ? "Resume bridge" : "Pause bridge",
                    systemImage: model.isPaused ? "play.fill" : "pause.fill",
                    disabled: model.isBusy
                ) {
                    model.togglePause()
                }
            }
            .padding(8)

            Divider()

            menuRow("Quit AgentMicro", systemImage: "xmark.square", disabled: model.isBusy) {
                onQuit()
            }
            .keyboardShortcut("q", modifiers: .command)
            .padding(8)
        }
        .frame(width: 310)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var statusSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                MicroGlyphView(size: 19)

                Text("AgentMicro")
                    .font(.system(size: 13, weight: .semibold))

                Spacer()

                if model.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("AgentMicro is working")
                } else {
                    StatusPill(text: statusLabel, tone: overallTone)
                }
            }

            ConnectionRail(stages: connectionStages)
                .padding(.horizontal, -4)

            VStack(alignment: .leading, spacing: 3) {
                Text(model.headline)
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                Text(model.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var integrationAction: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(integrationActionTitle)
                        .font(.callout.weight(.semibold))
                    Text(integrationActionDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(StatusTone.actionRequired.color)
            }

            PatchActionButtons(
                model: model,
                compact: true,
                onDialogPresented: onDialogPresented,
                onDialogDismissed: onDialogDismissed
            )
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(StatusTone.actionRequired.color.opacity(0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(StatusTone.actionRequired.color.opacity(0.22), lineWidth: 1)
        )
    }

    private func menuRow(
        _ title: String,
        systemImage: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .frame(width: 16)

                Text(title)

                Spacer(minLength: 0)
            }
            .font(.callout)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private var showsIntegrationAction: Bool {
        let value = model.patchStatusText.lowercased()
        return value.contains("required")
            || value.contains("update")
            || value.contains("unsupported")
    }

    private var integrationActionTitle: String {
        model.integrationNeedsUpdate ? "Update the ChatGPT integration" : "Enable ChatGPT integration"
    }

    private var integrationActionDetail: String {
        if model.integrationNeedsUpdate {
            return "Restore ChatGPT first, then choose Patch ChatGPT. This is normally needed only after ChatGPT or AgentMicro updates."
        }
        return "Patch ChatGPT once to enable the complete iPhone route."
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

    private var phoneTone: StatusTone {
        StatusTone.inferred(from: model.phoneStatus, fallback: overallTone)
    }

    private var chatGPTTone: StatusTone {
        StatusTone.inferred(from: model.chatGPTStatus, fallback: overallTone)
    }

    private var connectionStages: [ConnectionRail.Stage] {
        [
            .init(
                id: "phone",
                title: "iPhone",
                detail: model.phoneStatus,
                icon: "iphone",
                tone: phoneTone
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
}
