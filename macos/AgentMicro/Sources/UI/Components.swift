import SwiftUI

struct QuietCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }
}

struct StatusPill: View {
    let text: String
    let tone: StatusTone

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tone.color)
                .frame(width: 6, height: 6)

            Text(text)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(tone.color.opacity(0.11))
        )
        .overlay(
            Capsule()
                .stroke(tone.color.opacity(0.22), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(text), \(tone.accessibilityDescription)")
    }
}

struct StatusRow: View {
    let icon: String
    let title: String
    let value: String
    var tone: StatusTone? = nil

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)

            Text(title)
                .foregroundStyle(.secondary)

            Spacer(minLength: 10)

            HStack(spacing: 5) {
                if let tone {
                    Circle()
                        .fill(tone.color)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }

                Text(value)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)
            }
        }
        .font(.caption)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value)")
    }
}

struct SectionLabel: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.55)
            .foregroundStyle(.tertiary)
            .accessibilityAddTraits(.isHeader)
    }
}

struct ActionButton: View {
    let title: String
    let systemImage: String
    var help: String
    var isDisabled = false
    var isLoading = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: systemImage)
                }
                Text(title)
                    .lineLimit(1)
            }
            .font(.caption.weight(.medium))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .disabled(isDisabled)
        .help(help)
        .accessibilityLabel(title)
        .accessibilityHint(help)
    }
}

struct PatchActionButtons: View {
    enum PendingAction: String, Identifiable {
        case patch
        case restore

        var id: String { rawValue }
    }

    @ObservedObject var model: AppModel
    var compact = false
    var onDialogPresented: () -> Void = {}
    var onDialogDismissed: () -> Void = {}
    @State private var pendingAction: PendingAction?

    var body: some View {
        Group {
            if compact {
                HStack(spacing: 8) {
                    patchButton
                    restoreButton
                }
            } else {
                VStack(spacing: 8) {
                    patchButton
                    restoreButton
                }
            }
        }
        .alert(item: $pendingAction) { action in
            switch action {
            case .patch:
                return Alert(
                    title: Text("Patch ChatGPT?"),
                    message: Text(
                        "AgentMicro will ask ChatGPT to close normally, modify its local app resources, re-sign it locally, then reopen it. ChatGPT may ask you to sign in or approve permissions again, and an update will remove the patch. AgentMicro never force-quits ChatGPT."
                    ),
                    primaryButton: .default(Text("Patch & Reopen")) {
                        pendingAction = nil
                        onDialogDismissed()
                        model.patchChatGPT()
                    },
                    secondaryButton: .cancel(Text("Cancel")) {
                        pendingAction = nil
                        onDialogDismissed()
                    }
                )
            case .restore:
                return Alert(
                    title: Text("Restore ChatGPT?"),
                    message: Text(
                        "AgentMicro will ask ChatGPT to close normally, validate and restore the version-matched backup, then reopen it. Migrated legacy backups remain locally signed; reinstall ChatGPT to recover OpenAI’s signature. AgentMicro never force-quits ChatGPT."
                    ),
                    primaryButton: .default(Text("Restore & Reopen")) {
                        pendingAction = nil
                        onDialogDismissed()
                        model.restoreChatGPT()
                    },
                    secondaryButton: .cancel(Text("Cancel")) {
                        pendingAction = nil
                        onDialogDismissed()
                    }
                )
            }
        }
    }

    private var patchButton: some View {
        ActionButton(
            title: "Patch ChatGPT",
            systemImage: "wrench.and.screwdriver",
            help: "Apply the AgentMicro integration after confirmation.",
            isDisabled: model.isBusy || !model.canPatch,
            isLoading: model.isBusy && model.operationProgress?.operation == .patch
        ) {
            onDialogPresented()
            pendingAction = .patch
        }
    }

    private var restoreButton: some View {
        ActionButton(
            title: "Restore ChatGPT",
            systemImage: "arrow.uturn.backward",
            help: "Restore ChatGPT to its original files after confirmation.",
            isDisabled: model.isBusy || !model.canRestore,
            isLoading: model.isBusy && model.operationProgress?.operation == .restore
        ) {
            onDialogPresented()
            pendingAction = .restore
        }
    }
}

struct PatchOperationProgressView: View {
    let progress: PatchProgress?
    let fallbackMessage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(title)
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 0)
                if let fraction = progress?.fraction {
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if let fraction = progress?.fraction {
                ProgressView(value: fraction, total: 1)
                    .progressViewStyle(.linear)
            }

            Text(progress?.message ?? fallbackMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var title: String {
        switch progress?.operation {
        case .restore: return "Restoring ChatGPT"
        case .patch: return "Patching ChatGPT"
        case nil: return "Working safely"
        }
    }

    private var accessibilityLabel: String {
        let message = progress?.message ?? fallbackMessage
        if let fraction = progress?.fraction {
            return "\(title), \(Int((fraction * 100).rounded())) percent. \(message)"
        }
        return "\(title). \(message)"
    }
}

struct AgentRepairPromptButton: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ActionButton(
            title: model.agentRepairPromptCopied
                ? "Copied"
                : "Copy agent repair prompt",
            systemImage: model.agentRepairPromptCopied
                ? "checkmark"
                : "doc.on.doc",
            help: "Copy the detected ChatGPT build, failure reason, repository, documentation, and required test procedure.",
            isDisabled: model.isBusy || !model.canCopyAgentRepairPrompt
        ) {
            model.copyAgentRepairPrompt()
        }
    }
}
