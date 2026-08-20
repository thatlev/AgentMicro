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
    private var spaceChangeObserver: NSObjectProtocol?
    private var screenChangeObserver: NSObjectProtocol?
    private var isDialogPresented = false

    /// When an outside click last dismissed the popover.
    ///
    /// Clicking the status item while the popover is open delivers mouse-down
    /// and mouse-up as one physical click. The global monitor sees the
    /// mouse-down and closes, then the button's action fires on mouse-up and
    /// reopens it — so a click that should have toggled the popover shut left
    /// it open, and rapid clicking only highlighted the icon while the popover
    /// appeared stuck.
    private var lastOutsideClickCloseAt: Date?

    /// A mouse-up follows its mouse-down within a few milliseconds. Anything
    /// inside this window belongs to the click that already closed the popover.
    private static let sameClickInterval: TimeInterval = 0.4

    init(model: AppModel, onQuit: @escaping () -> Void) {
        self.model = model
        self.onQuit = onQuit
        // squareLength pins the item's window to a fixed 38pt no matter how
        // small the artwork is, which is why shrinking the glyph never
        // narrowed the item. variableLength sizes the window to the image, so
        // an 18pt canvas costs 34pt against the 36pt a system icon takes.
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
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
        statusItem.autosaveName = "AgentMicroStatusItem"

        guard let button = statusItem.button else { return }
        button.image = AgentMicroGlyph.image
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
        // Anchored to the top-right corner. The button is flipped, so the
        // fixed margin above the badge is maxYMargin, not minYMargin.
        statusDot.autoresizingMask = [.minXMargin, .maxYMargin]
        button.addSubview(statusDot, positioned: .above, relativeTo: nil)
        installStatusGeometryObservers()
    }

    /// Keep the status item's measured frame honest across Space switches and
    /// display changes.
    ///
    /// Both events can leave AppKit holding a frame for the item that no
    /// longer matches where it is drawn. The popover is then placed against
    /// that stale frame: it opens away from the icon, or on the display the
    /// item used to be on. Re-asserting the length forces a fresh measurement,
    /// which costs nothing when the geometry was already correct.
    private func installStatusGeometryObservers() {
        spaceChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.remeasureStatusItem() }
        }

        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.remeasureStatusItem() }
        }
    }

    private func remeasureStatusItem() {
        guard statusItem.button != nil else { return }
        // A shown popover is anchored to the old frame, so it has to go before
        // the item re-measures; leaving it up is what stranded it on the
        // previous display.
        if popover.isShown { closePopover() }
        statusItem.length = NSStatusItem.variableLength
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

    private static let statusDotSize: CGFloat = 3.5

    /// Pinned to the glyph's top-right, wholly inside its bounds.
    ///
    /// The popover's arrow points at the bottom edge of the status button, so
    /// a badge sitting at the glyph's bottom corner is exactly where the arrow
    /// arrives: opening the menu drew the arrow over the dot. Keeping the
    /// badge at the top leaves the arrow's approach clear, and the top corner
    /// is where macOS puts unread and attention badges anyway.
    private static func statusDotOrigin(in button: NSStatusBarButton) -> NSPoint {
        let mark = AgentMicroGlyph.canvasSize
        let imageSize = button.image?.size
            ?? NSSize(width: mark, height: AgentMicroGlyph.canvasHeight)
        // The image is taller than the mark, and the mark sits at its base.
        let imageOriginX = (button.bounds.width - imageSize.width) / 2
        let imageOriginY = (button.bounds.height - imageSize.height) / 2
        let glyphOriginX = imageOriginX
        // Flipped view: the mark's base is the image's *largest* y, so the
        // mark's top edge is that base minus the mark's own height.
        let markBaseY = imageOriginY + imageSize.height - AgentMicroGlyph.baselineInset
        let glyphOriginY = markBaseY - mark
        // Measure to the outer edge of the stroke, not the path, so the dot
        // never lands beyond the ink and re-widens the item.
        let halfStroke = AgentMicroGlyph.outlineWidth / 2
        let artworkMaxX = glyphOriginX + mark - AgentMicroGlyph.clearMargin + halfStroke
        // NSStatusBarButton is flipped: y grows downwards, so the glyph's top
        // edge is its *smallest* y. Computing this as though the view were
        // unflipped put the badge back at the bottom, in the arrow's path.
        let artworkTopY = glyphOriginY + AgentMicroGlyph.clearMargin - halfStroke
        return NSPoint(x: artworkMaxX - statusDotSize, y: artworkTopY)
    }

    @objc
    private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            closePopover()
            return
        }

        // The mouse-down half of this same click already closed the popover.
        // Reopening now would make a click on the item fail to toggle it shut.
        if consumeRecentOutsideClickClose() { return }

        guard let button = statusItem.button else { return }
        endDismissalMonitoring()
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        model.refreshStatus()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        configurePopoverWindow()
        beginDismissalMonitoring()
    }

    private func consumeRecentOutsideClickClose() -> Bool {
        guard let lastOutsideClickCloseAt else { return false }
        self.lastOutsideClickCloseAt = nil
        return Date().timeIntervalSince(lastOutsideClickCloseAt) < Self.sameClickInterval
    }

    /// Screen frame of the status item, padded because the item is small and
    /// the menu bar is a coarse click target.
    private func statusItemFrame() -> NSRect {
        guard let button = statusItem.button, let window = button.window else { return .null }
        let inWindow = button.convert(button.bounds, to: nil)
        return window.convertToScreen(inWindow).insetBy(dx: -4, dy: -4)
    }

    /// Give the popover key status so its SwiftUI controls receive clicks.
    ///
    /// The popover hosts confirmation alerts for patch and restore, so it
    /// cannot be `.transient`: AppKit would dismiss it the moment the alert
    /// took over. That means this controller has to make the window key
    /// itself.
    ///
    /// It deliberately does not call `NSApp.activate(ignoringOtherApps:)`.
    /// Activating a menu bar accessory steals focus from the app the user was
    /// in, and forcing activation while the status bar is laying out is what
    /// made every icon in the bar flicker on each click. Making the window key
    /// is enough for the controls to work, and leaves the frontmost app alone.
    private func configurePopoverWindow() {
        guard let popoverWindow = popover.contentViewController?.view.window else { return }
        popoverWindow.level = .popUpMenu
        popoverWindow.collectionBehavior.insert(.fullScreenAuxiliary)
        popoverWindow.makeKey()
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
            let location = NSEvent.mouseLocation
            DispatchQueue.main.async {
                guard let self, !self.isDialogPresented else { return }
                // A click on the status item is not an outside click. Closing
                // on its mouse-down races the button's mouse-up action, which
                // then reopens the popover instead of toggling it shut.
                guard !self.statusItemFrame().contains(location) else { return }
                // Global monitors receive events delivered to other apps, not
                // this app. Local alert and popover clicks therefore never
                // enter the outside-click dismissal path.
                self.closePopover()
                // Recorded either way: the pointer can sit fractionally outside
                // the item while the click still targets it.
                self.lastOutsideClickCloseAt = Date()
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
            window.identifier = NSUserInterfaceItemIdentifier("AgentMicroSettings")
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
