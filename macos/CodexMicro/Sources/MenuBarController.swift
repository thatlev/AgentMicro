import AppKit
import Combine
import SwiftUI

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate, NSWindowDelegate {
    private let model: AppModel
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let statusDot = StatusDotView()
    private var subscriptions = Set<AnyCancellable>()
    private var settingsWindowController: NSWindowController?

    init(model: AppModel) {
        self.model = model
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        configureStatusItem()
        configurePopover()
        observeModel()
        refreshStatusItem()
    }

    func showOnboardingIfNeeded() {
        guard model.showOnboarding else { return }
        showSettings()
    }

    private func configureStatusItem() {
        statusItem.autosaveName = "CodexMicroStatusItem"

        guard let button = statusItem.button else { return }
        button.image = CodexMicroGlyph.image
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp])
        button.setAccessibilityLabel("AgentMicro")
        button.setAccessibilityHelp("Open AgentMicro connection status and controls.")

        statusDot.frame = NSRect(
            x: max(button.bounds.maxX - 8, 14),
            y: 2,
            width: 6,
            height: 6
        )
        statusDot.autoresizingMask = [.minXMargin, .maxYMargin]
        button.addSubview(statusDot, positioned: .above, relativeTo: nil)
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: 310, height: 330)
        popover.contentViewController = NSHostingController(
            rootView: MenuPopoverView(
                model: model,
                onOpenSettings: { [weak self] in self?.showSettings() }
            )
        )
    }

    private func observeModel() {
        model.$overallState
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshStatusItem()
            }
            .store(in: &subscriptions)

        model.$headline
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshStatusItem()
            }
            .store(in: &subscriptions)

        model.$detail
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshStatusItem()
            }
            .store(in: &subscriptions)

        model.$showOnboarding
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] shouldShow in
                guard let self else { return }
                if shouldShow {
                    DispatchQueue.main.async { [weak self] in
                        self?.showOnboardingIfNeeded()
                    }
                }
            }
            .store(in: &subscriptions)
    }

    private func refreshStatusItem() {
        guard let button = statusItem.button else { return }

        let tone = overallTone
        let patchValue = model.patchStatusText.lowercased()
        let showsIntegrationAction = patchValue.contains("required")
            || patchValue.contains("update")
            || patchValue.contains("unsupported")
        popover.contentSize = NSSize(
            width: 310,
            height: showsIntegrationAction ? 450 : (tone == .healthy ? 300 : 345)
        )
        statusDot.isHidden = tone == .healthy
        statusDot.color = tone.nsColor

        let stateDescription = tone.accessibilityDescription
        let tooltip = "AgentMicro — \(model.headline)\n\(model.detail)"
        button.toolTip = tooltip
        button.setAccessibilityValue(stateDescription)
        button.setAccessibilityHelp("\(tooltip). Click to open status and controls.")

        button.layoutSubtreeIfNeeded()
        statusDot.frame.origin = NSPoint(
            x: max(button.bounds.maxX - 8, 14),
            y: 2
        )
    }

    @objc
    private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }

        guard let button = statusItem.button else { return }
        model.refreshStatus()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func showSettings() {
        popover.performClose(nil)

        if settingsWindowController == nil {
            let hostingController = NSHostingController(
                rootView: SettingsView(model: model)
            )
            let window = NSWindow(contentViewController: hostingController)
            window.title = "AgentMicro Settings"
            window.identifier = NSUserInterfaceItemIdentifier("CodexMicroSettings")
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 620, height: 480))
            window.isReleasedWhenClosed = false
            window.center()
            window.delegate = self
            settingsWindowController = NSWindowController(window: window)
        }

        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
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
}

private final class StatusDotView: NSView {
    var color: NSColor = .systemGray {
        didSet {
            layer?.backgroundColor = color.cgColor
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = frameRect.width / 2
        layer?.backgroundColor = color.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.windowBackgroundColor.withAlphaComponent(0.8).cgColor
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
