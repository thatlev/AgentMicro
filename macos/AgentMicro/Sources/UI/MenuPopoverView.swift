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

            if model.isBusy {
                Divider()
                operationProgress
                    .padding(14)
            }

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
                Image(systemName: model.isChatGPTPatched ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(integrationTone.color)
            }

            if model.hasNoPatchAction {
                Text(model.patchBlockedReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("How to fix: \(model.patchBlockedReason)")
            }

            if model.canCopyAgentRepairPrompt {
                AgentRepairPromptButton(model: model)
            }

            // Once the scanner has rejected a pristine build, the repair
            // prompt is the action. Avoid surrounding it with two dead buttons.
            if !model.hasNoPatchAction {
                PatchActionButtons(
                    model: model,
                    compact: true,
                    onDialogPresented: onDialogPresented,
                    onDialogDismissed: onDialogDismissed
                )
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(integrationTone.color.opacity(0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(integrationTone.color.opacity(0.22), lineWidth: 1)
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
        model.isPatchStatusReady
            && (model.integrationNeedsAttention
                || (model.isChatGPTPatched && model.overallState != .healthy))
    }

    private var integrationTone: StatusTone {
        model.isChatGPTPatched ? .healthy : .actionRequired
    }

    private var integrationActionTitle: String {
        if model.canCopyAgentRepairPrompt { return "Unsupported ChatGPT build" }
        if model.integrationNeedsUpdate { return "Update the ChatGPT integration" }
        if model.isChatGPTPatched { return "ChatGPT integration ready" }
        return "Enable ChatGPT integration"
    }

    private var integrationActionDetail: String {
        if model.canCopyAgentRepairPrompt {
            return "AgentMicro stopped safely before changing ChatGPT. Copy a complete repair request for your coding agent."
        }
        if model.integrationNeedsUpdate {
            return "Restore ChatGPT first, then choose Patch ChatGPT. This is normally needed only after ChatGPT or AgentMicro updates."
        }
        if model.isChatGPTPatched {
            return "The patch is current. Restore is available if ChatGPT needs to return to its original files."
        }
        return "Patch ChatGPT once to enable the complete iPhone route."
    }

    private var operationProgress: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(operationTitle)
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 0)
                if let fraction = model.operationProgress?.fraction {
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if let fraction = model.operationProgress?.fraction {
                ProgressView(value: fraction, total: 1)
                    .progressViewStyle(.linear)
            }

            Text(model.operationProgress?.message ?? model.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(operationAccessibilityLabel)
    }

    private var operationTitle: String {
        switch model.operationProgress?.operation {
        case .restore: return "Restoring ChatGPT"
        case .patch: return "Patching ChatGPT"
        case nil: return "Working safely"
        }
    }

    private var operationAccessibilityLabel: String {
        let message = model.operationProgress?.message ?? model.detail
        if let fraction = model.operationProgress?.fraction {
            return "\(operationTitle), \(Int((fraction * 100).rounded())) percent. \(message)"
        }
        return "\(operationTitle). \(message)"
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
