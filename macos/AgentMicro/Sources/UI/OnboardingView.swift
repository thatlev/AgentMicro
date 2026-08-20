import AppKit
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var model: AppModel
    let onFinish: () -> Void

    @State private var step = Step.welcome
    @State private var didCopySetupPrompt = false
    @State private var copiedSetupPrompt = false
    @State private var copyFeedbackGeneration = 0
    @State private var openedX = false
    @State private var openedGitHub = false

    private enum Step: Int, CaseIterable {
        case welcome
        case chatGPT
        case mobile
        case connect
        case agents
        case finish

        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .chatGPT: return "ChatGPT"
            case .mobile: return "iPhone"
            case .connect: return "Connect"
            case .agents: return "Agents"
            case .finish: return "Finish"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            stepNavigation
                .padding(.horizontal, 28)
                .padding(.vertical, 18)

            Divider()

            ZStack {
                Color(nsColor: .windowBackgroundColor)
                stepContent
                    .id(step)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                    .padding(.horizontal, 52)
                    .padding(.vertical, 34)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
        }
        .frame(minWidth: 680, idealWidth: 720, minHeight: 540, idealHeight: 580)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(.blue)
    }

    private var stepNavigation: some View {
        HStack(spacing: 8) {
            MicroGlyphView(size: 20)
            Text("AgentMicro")
                .font(.headline)

            Spacer()

            ForEach(Step.allCases, id: \.self) { item in
                HStack(spacing: 5) {
                    Image(systemName: navigationIcon(for: item))
                        .font(.system(size: 10, weight: .semibold))
                    Text(item.title)
                        .font(.caption.weight(item == step ? .semibold : .regular))
                }
                .foregroundStyle(item.rawValue <= step.rawValue ? Color.primary : Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(item == step ? Color.accentColor.opacity(0.12) : Color.clear)
                )
                .accessibilityLabel("\(item.title), step \(item.rawValue + 1) of \(Step.allCases.count)")
                .accessibilityAddTraits(item == step ? .isSelected : [])
            }
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome: welcomeStep
        case .chatGPT: chatGPTStep
        case .mobile: mobileStep
        case .connect: connectionStep
        case .agents: agentsStep
        case .finish: finishStep
        }
    }

    private var welcomeStep: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.11))
                    .frame(width: 92, height: 92)
                MicroGlyphView(size: 44)
            }

            VStack(spacing: 8) {
                Text("Your coding agents, within reach")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                Text("Turn your iPhone into a private control surface.\nSetup takes about three minutes.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 28) {
                welcomeBenefit("iphone", "Control from iPhone")
                welcomeBenefit("lock.shield", "Local and private")
                welcomeBenefit("bolt", "Ready when you are")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var chatGPTStep: some View {
        VStack(spacing: 24) {
            stepHeading(
                icon: !model.isPatchStatusReady
                    ? "magnifyingglass"
                    : (model.isChatGPTPatched ? "checkmark.seal.fill" : "wrench.and.screwdriver.fill"),
                tint: model.isChatGPTPatched ? .green : .blue,
                title: !model.isPatchStatusReady
                    ? "Checking ChatGPT"
                    : (model.isChatGPTPatched ? "ChatGPT is patched" : "Connect AgentMicro to ChatGPT"),
                detail: !model.isPatchStatusReady
                    ? "Reading the installed ChatGPT build before offering a safe action."
                    : (model.isChatGPTPatched
                    ? "The integration is installed and ready for the iPhone route."
                    : "AgentMicro makes one reversible local change. It normally finishes in under a minute.")
            )

            if !model.isPatchStatusReady {
                ProgressView()
                    .controlSize(.regular)
                    .accessibilityLabel("Checking the installed ChatGPT build")
            } else if model.isBusy {
                operationCard
            } else if model.isChatGPTPatched {
                successRow("Patch complete", detail: "Continue to install the iPhone app.")
            } else {
                VStack(spacing: 10) {
                    PatchActionButtons(model: model, compact: true)

                    if model.hasNoPatchAction {
                        Text(model.patchBlockedReason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: 520, maxHeight: .infinity)
    }

    private var mobileStep: some View {
        VStack(spacing: 24) {
            stepHeading(
                icon: "iphone.gen3.radiowaves.left.and.right",
                tint: .blue,
                title: "Let your agent install the iPhone app",
                detail: "Copy one prompt into the agent you already use. It will inspect Xcode, build AgentMicro, and stop only when Apple needs your approval."
            )

            HStack(spacing: 12) {
                appBadge("Claude", assetName: "ClaudeAppIcon")
                appBadge("ChatGPT", assetName: "ChatGPTAppIcon")
                appBadge("Cursor", assetName: "CursorAppIcon")
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(setupPrompt)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack {
                    Link("Read the mobile setup guide", destination: Links.mobileSetup)
                        .font(.caption)
                    Spacer()
                    Button {
                        copySetupPrompt()
                    } label: {
                        ZStack {
                            Label("Copy setup prompt", systemImage: "doc.on.doc")
                                .opacity(copiedSetupPrompt ? 0 : 1)
                            Label("Copied", systemImage: "checkmark")
                                .opacity(copiedSetupPrompt ? 1 : 0)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .help(copiedSetupPrompt ? "Copied. Click to copy it again." : "Copy the complete setup prompt.")
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
        }
        .frame(maxWidth: 560, maxHeight: .infinity)
    }

    private var connectionStep: some View {
        VStack(spacing: 24) {
            stepHeading(
                icon: model.isPhoneReady ? "checkmark.circle.fill" : "iphone.radiowaves.left.and.right",
                tint: model.isPhoneReady ? .green : .blue,
                title: model.isPhoneReady ? "Your iPhone is connected" : "Open AgentMicro on your iPhone",
                detail: model.isPhoneReady
                    ? "The encrypted Bluetooth report stream is ready."
                    : "Keep the phone unlocked and nearby. AgentMicro will connect automatically after the app opens."
            )

            if !model.isPhoneReady {
                HStack(spacing: 14) {
                    Circle()
                        .fill(Color.orange.opacity(0.13))
                        .frame(width: 46, height: 46)
                        .overlay {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.orange)
                        }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Waiting for iPhone")
                            .font(.headline)
                        Text(model.phoneStatus)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    ProgressView()
                        .controlSize(.small)
                    Button("Check again") {
                        model.reconnect()
                    }
                    .buttonStyle(.bordered)
                    .tint(.gray)
                    .disabled(model.isBusy)
                }
                .padding(18)
                .frame(maxWidth: 500)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )

                Text("If Xcode says the app is no longer available, build it to the phone again. Free Apple ID builds expire after seven days.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var agentsStep: some View {
        VStack(spacing: 22) {
            stepHeading(
                icon: "point.3.connected.trianglepath.dotted",
                tint: .blue,
                title: "Use more models with AgentMicro",
                detail: "This step is optional. AgentMicro is already ready. Add one workspace for every coding agent, or bring other models directly into ChatGPT."
            )

            VStack(spacing: 10) {
                projectRow(
                    icon: "rectangle.3.group.fill",
                    assetName: "T3CodeAppIcon",
                    emphasized: true,
                    title: "T3 Code",
                    detail: "Run Claude, ChatGPT, Codex, and other coding agents side by side in one desktop app.",
                    button: "View T3 Code",
                    url: Links.t3Code
                )
                projectRow(
                    icon: "terminal.fill",
                    title: "OpenCodex for ChatGPT",
                    detail: "Add Claude, Codex, and other models directly inside the ChatGPT app.",
                    button: "View OpenCodex",
                    url: Links.openCodex
                )
            }
            .frame(maxWidth: 540)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var finishStep: some View {
        VStack(spacing: 24) {
            stepHeading(
                icon: "heart.fill",
                tint: .pink,
                title: "Help AgentMicro grow",
                detail: "If this project is useful, follow the build and star the repository. Both links open in your browser."
            )

            VStack(spacing: 10) {
                supportRow(
                    icon: "at",
                    assetName: "LevProfilePicture",
                    title: "Follow @thatlevco on X",
                    detail: "Product updates, demos, and new builds.",
                    completed: openedX
                ) {
                    openedX = true
                    NSWorkspace.shared.open(Links.xProfile)
                }
                supportRow(
                    icon: "star.fill",
                    title: "Star AgentMicro on GitHub",
                    detail: "It helps other builders discover the project.",
                    completed: openedGitHub
                ) {
                    openedGitHub = true
                    NSWorkspace.shared.open(Links.repository)
                }
            }
            .frame(maxWidth: 520)

            Text("AgentMicro can confirm that the links were opened, but never reads your social or GitHub account.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("Back") { move(to: step.rawValue - 1) }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
            }

            Spacer()

            Button(footerActionTitle) {
                if step == .finish {
                    onFinish()
                } else {
                    move(to: step.rawValue + 1)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(canContinue ? Color.accentColor : Color.gray)
            .keyboardShortcut(.defaultAction)
            .disabled(step == .finish && !canContinue)
            .accessibilityHint(
                footerActionTitle == "Skip"
                    ? "Move to the next setup step without completing this one."
                    : "Complete this setup step and continue."
            )
        }
    }

    private var footerActionTitle: String {
        if step == .finish { return "Finish" }
        return canContinue ? "Continue" : "Skip"
    }

    private var canContinue: Bool {
        switch step {
        case .chatGPT: return model.isChatGPTPatched && !model.isBusy
        case .mobile: return didCopySetupPrompt
        case .connect: return model.isPhoneReady
        case .finish: return openedX && openedGitHub
        case .welcome, .agents: return true
        }
    }

    private var operationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text(model.operationProgress?.message ?? model.headline)
                    .font(.callout.weight(.medium))
                Spacer()
                if let fraction = model.operationProgress?.fraction {
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let fraction = model.operationProgress?.fraction {
                ProgressView(value: fraction)
            }
            Text("Keep AgentMicro open while ChatGPT closes and reopens.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: 500)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .accessibilityElement(children: .combine)
    }

    private func stepHeading(icon: String, tint: Color, title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(tint)
                .symbolEffect(.pulse, options: .repeating, isActive: model.isBusy)
                .frame(height: 42)
            Text(title)
                .font(.title.weight(.bold))
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 560)
    }

    private func welcomeBenefit(_ icon: String, _ title: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private func successRow(_ title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: 500)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.green.opacity(0.09))
        )
    }

    private func appBadge(_ name: String, assetName: String) -> some View {
        VStack(spacing: 8) {
            Image(assetName)
                .resizable()
                .scaledToFit()
                .frame(width: 42, height: 42)
                .accessibilityHidden(true)
            Text(name)
                .font(.caption.weight(.medium))
        }
        .frame(width: 88, height: 76)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func projectRow(
        icon: String,
        assetName: String? = nil,
        emphasized: Bool = false,
        title: String,
        detail: String,
        button: String,
        url: URL
    ) -> some View {
        HStack(spacing: 14) {
            Group {
                if let assetName {
                    Image(assetName)
                        .resizable()
                        .scaledToFit()
                        .frame(
                            width: emphasized ? 44 : 32,
                            height: emphasized ? 44 : 32
                        )
                } else {
                    Image(systemName: icon)
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: emphasized ? 50 : 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(button) { NSWorkspace.shared.open(url) }
        }
        .padding(emphasized ? 19 : 16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func supportRow(
        icon: String,
        assetName: String? = nil,
        title: String,
        detail: String,
        completed: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Group {
                    if let assetName {
                        Image(assetName)
                            .resizable()
                            .scaledToFill()
                            .clipShape(Circle())
                    } else {
                        Image(systemName: icon)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(completed ? .green : Color.accentColor)
                    }
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: completed ? "checkmark.circle.fill" : "arrow.up.right")
                    .foregroundStyle(completed ? .green : .secondary)
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func navigationIcon(for item: Step) -> String {
        if item.rawValue < step.rawValue { return "checkmark.circle.fill" }
        if item == step { return "circle.inset.filled" }
        return "circle"
    }

    private func move(to rawValue: Int) {
        guard let next = Step(rawValue: rawValue) else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            step = next
        }
    }

    private func copySetupPrompt() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(setupPrompt, forType: .string)
        didCopySetupPrompt = true
        copyFeedbackGeneration += 1
        let generation = copyFeedbackGeneration
        copiedSetupPrompt = true
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: "Setup prompt copied",
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            guard generation == copyFeedbackGeneration else { return }
            copiedSetupPrompt = false
        }
    }

    private var setupPrompt: String {
        """
        Set up AgentMicro on my connected iPhone. Follow \(Links.mobileSetup.absoluteString) exactly. Inspect prerequisites first; do not rename bundle IDs or protocol identifiers. Build, install, and launch the iPhone app, asking me only for Apple ID, signing-team, trust, or Developer Mode steps that require my click. Then verify the AgentMicro Mac app reports iPhone Ready.
        """
    }
}

private enum Links {
    static let repository = URL(string: "https://github.com/thatlev/AgentMicro")!
    static let mobileSetup = URL(string: "https://github.com/thatlev/AgentMicro/blob/main/docs/MOBILE-SETUP.md")!
    static let t3Code = URL(string: "https://github.com/thatlev/t3code")!
    static let openCodex = URL(string: "https://github.com/lidge-jun/opencodex")!
    static let xProfile = URL(string: "https://x.com/thatlevco")!
}
