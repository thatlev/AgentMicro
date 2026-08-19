import AppKit
import Combine
import SwiftUI

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate, NSWindowDelegate {
    private let model: AppModel
    private let onQuit: () -> Void
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let statusDot = StatusDotView()
    private var subscriptions = Set<AnyCancellable>()
    private var settingsWindowController: NSWindowController?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var appResignActiveObserver: NSObjectProtocol?
    private var isDialogPresented = false

    init(model: AppModel, onQuit: @escaping () -> Void) {
        self.model = model
        self.onQuit = onQuit
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
            origin: Self.statusDotOrigin(in: button),
            size: NSSize(width: Self.statusDotSize, height: Self.statusDotSize)
        )
        statusDot.autoresizingMask = [.minXMargin, .maxYMargin]
        button.addSubview(statusDot, positioned: .above, relativeTo: nil)
    }

    private func configurePopover() {
        // Keep one owner for dismissal. AppKit's transient/semitransient
        // behaviors compete with alert windows and event monitors, especially
        // while another app owns a full-screen Space. With applicationDefined,
        // this controller alone opens and closes the popover.
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: 310, height: 330)
        popover.contentViewController = NSHostingController(
            rootView: MenuPopoverView(
                model: model,
                onOpenSettings: { [weak self] in self?.showSettings() },
                onQuit: { [weak self] in self?.requestQuit() },
                onDialogPresented: { [weak self] in
                    self?.isDialogPresented = true
                },
                onDialogDismissed: { [weak self] in
                    self?.restorePopoverInteractionAfterDialog()
                }
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
        statusDot.frame.origin = Self.statusDotOrigin(in: button)
    }

    private static let statusDotSize: CGFloat = 4

    /// Kept wholly inside the glyph's own bounds. Centring the dot on the
    /// artwork's corner left half of it outside, which is what still made the
    /// item measure wider than its neighbours: the glyph is 14pt, but the
    /// overhanging dot took the visible width to 15.5pt.
    private static func statusDotOrigin(in button: NSStatusBarButton) -> NSPoint {
        let glyph = button.image?.size.width ?? CodexMicroGlyph.canvasSize
        let glyphOriginX = (button.bounds.width - glyph) / 2
        let glyphOriginY = (button.bounds.height - glyph) / 2
        // Measure to the outer edge of the stroke, not the path, so the dot
        // never lands beyond the ink and re-widens the item.
        let halfStroke = CodexMicroGlyph.outlineWidth / 2
        let artworkMaxX = glyphOriginX + glyph - CodexMicroGlyph.clearMargin + halfStroke
        let artworkMinY = glyphOriginY + CodexMicroGlyph.clearMargin - halfStroke
        return NSPoint(x: artworkMaxX - statusDotSize, y: artworkMinY)
    }

    @objc
    private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            closePopover()
            return
        }

        guard let button = statusItem.button else { return }
        endDismissalMonitoring()
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        model.refreshStatus()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        configurePopoverWindow()
        beginDismissalMonitoring()
    }

    /// Usage4Claude promotes its shown popover to a key pop-up-menu-level window.
    /// Besides keeping it above normal app windows, this gives AppKit ownership
    /// of the active appearance and the complete system presentation transition.
    private func configurePopoverWindow() {
        guard let popoverWindow = popover.contentViewController?.view.window else { return }
        popoverWindow.level = .popUpMenu
        popoverWindow.collectionBehavior.insert(.fullScreenAuxiliary)

        // A window can only become key while its app is active, and app
        // activation completes asynchronously. Re-assert key status on the
        // following run-loop turns as well; without a key popover window,
        // SwiftUI treats every click as window activation and the buttons
        // never fire.
        NSApp.activate(ignoringOtherApps: true)
        popoverWindow.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak popoverWindow] in
            popoverWindow?.makeKeyAndOrderFront(nil)
        }
    }

    private func closePopover() {
        guard popover.isShown else {
            isDialogPresented = false
            endDismissalMonitoring()
            return
        }

        isDialogPresented = false
        endDismissalMonitoring()
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.performClose(nil)
    }

    private func requestQuit() {
        // Finish the popover's mouse event before asking AppKit to terminate.
        // Terminating synchronously from inside SwiftUI's button transaction
        // can leave the popover/event tracking loop owning the first request.
        closePopover()
        DispatchQueue.main.async { [onQuit] in
            onQuit()
        }
    }

    private func beginDismissalMonitoring() {
        endDismissalMonitoring()

        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            guard event.keyCode == 53 else { return event }
            self.closePopover()
            return nil
        }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, !self.isDialogPresented else { return }
                // Global monitors receive events delivered to other apps, not
                // this app. Local alert and popover clicks therefore never
                // enter the outside-click dismissal path.
                self.closePopover()
            }
        }

        appResignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self,
                      self.popover.isShown,
                      !self.isDialogPresented,
                      !NSApp.isActive else {
                    return
                }
                self.closePopover()
            }
        }
    }

    private func endDismissalMonitoring() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
        if let appResignActiveObserver {
            NotificationCenter.default.removeObserver(appResignActiveObserver)
            self.appResignActiveObserver = nil
        }
    }

    private func restorePopoverInteractionAfterDialog() {
        isDialogPresented = false

        // SwiftUI dismisses its alert after invoking the button action. Restore
        // on the next run-loop turn so the alert window has relinquished key
        // status before the popover is promoted again.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.popover.isShown else { return }
            self.configurePopoverWindow()
        }
    }

    func popoverDidShow(_ notification: Notification) {
        // By the time the popover finishes presenting, the activation request
        // has completed, so this is the reliable point to make it key.
        configurePopoverWindow()
    }

    func popoverDidClose(_ notification: Notification) {
        isDialogPresented = false
        endDismissalMonitoring()
    }

    private func showSettings() {
        closePopover()

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
        layer?.backgroundColor = color.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.windowBackgroundColor.withAlphaComponent(0.8).cgColor
        setAccessibilityElement(false)
    }

    /// Derived from the live bounds rather than the init frame. The view is
    /// created with a zero frame and sized afterwards, so a radius captured at
    /// init left the dot square.
    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.width / 2
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
