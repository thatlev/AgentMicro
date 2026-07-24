import SwiftUI

struct OnboardingView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    hero
                    steps
                    privacyNote
                }
                .padding(26)
            }

            Divider()

            HStack {
                Text("You can reopen this guide from the menu bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Finish Setup") {
                    model.completeOnboarding()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isBusy)
                .help("Close the setup guide and continue using Codex Micro.")
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .frame(minWidth: 500, idealWidth: 530, minHeight: 530, idealHeight: 590)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var hero: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .frame(width: 54, height: 54)
                MicroGlyphView(size: 29)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Set up Codex Micro")
                    .font(.title2.weight(.semibold))

                Text(
                    "Three quick checks connect your iPhone to the Codex Micro interface in ChatGPT."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var steps: some View {
        VStack(spacing: 10) {
            OnboardingStep(
                number: 1,
                title: "Keep the companion available",
                detail: "Launch at Login keeps the Mac connection ready without a background-only service.",
                status: model.launchAtLogin ? "Enabled" : "Optional",
                tone: model.launchAtLogin ? .healthy : .idle
            ) {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { model.launchAtLogin },
                        set: { model.setLaunchAtLogin($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel("Launch Codex Micro at login")
            }

            OnboardingStep(
                number: 2,
                title: "Connect your iPhone",
                detail: "Keep Bluetooth enabled and open Codex Micro on your iPhone to pair or reconnect.",
                status: model.phoneStatus,
                tone: phoneTone
            ) {
                Button("Reconnect") {
                    model.reconnect()
                }
                .disabled(model.isBusy)
                .help("Search for the paired iPhone and verify the route.")
            }

            OnboardingStep(
                number: 3,
                title: "Enable the ChatGPT integration",
                detail: "macOS may request App Management permission. Patching is manual and ChatGPT is never force-quit.",
                status: model.patchStatusText,
                tone: patchTone
            ) {
                Button("Patch ChatGPT…") {
                    pendingPatchConfirmation = true
                }
                .disabled(model.isBusy || !model.canPatch)
                .help("Review and apply the ChatGPT integration.")
            }

            OnboardingStep(
                number: 4,
                title: "Verify the complete route",
                detail: "The menu-bar dot disappears only after a real ChatGPT → iPhone → ChatGPT round trip succeeds.",
                status: model.lastRoundTripText,
                tone: overallTone
            ) {
                Button("Check Now") {
                    model.reconnect()
                }
                .disabled(model.isBusy)
                .help("Run all connection checks now.")
            }
        }
        .alert("Patch ChatGPT?", isPresented: $pendingPatchConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Patch & Reopen") {
                model.patchChatGPT()
            }
        } message: {
            Text(
                "Codex Micro will ask ChatGPT to close normally, modify its local app resources, re-sign it locally, then reopen it. ChatGPT may ask you to sign in or approve permissions again. Updates remove the patch. Codex Micro never force-quits ChatGPT."
            )
        }
    }

    private var privacyNote: some View {
        Label {
            Text("No telemetry is sent. Diagnostics and rotating logs stay on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: "lock.shield")
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 2)
    }

    @State private var pendingPatchConfirmation = false

    private var overallTone: StatusTone {
        switch model.overallState {
        case .healthy: return .healthy
        case .connecting: return .connecting
        case .actionRequired: return .actionRequired
        case .failed: return .failed
        case .idle: return .idle
        }
    }

    private var phoneTone: StatusTone {
        StatusTone.inferred(from: model.phoneStatus, fallback: overallTone)
    }

    private var patchTone: StatusTone {
        StatusTone.inferred(from: model.patchStatusText, fallback: overallTone)
    }
}

private struct OnboardingStep<Accessory: View>: View {
    let number: Int
    let title: String
    let detail: String
    let status: String
    let tone: StatusTone
    let accessory: Accessory

    init(
        number: Int,
        title: String,
        detail: String,
        status: String,
        tone: StatusTone,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.number = number
        self.title = title
        self.detail = detail
        self.status = status
        self.tone = tone
        self.accessory = accessory()
    }

    var body: some View {
        QuietCard {
            HStack(alignment: .top, spacing: 12) {
                Text("\(number)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tone.color)
                    .frame(width: 23, height: 23)
                    .background(Circle().fill(tone.color.opacity(0.12)))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.callout.weight(.semibold))

                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    StatusPill(text: status, tone: tone)
                        .padding(.top, 2)
                }

                Spacer(minLength: 10)
                accessory
                    .padding(.top, 1)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
