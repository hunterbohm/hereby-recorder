import AppKit
import SwiftUI
import LMLCore

public enum PanelHost {
    @MainActor private static var controller: StatusController?

    /// Installs the status item, its panel, and the Option-M hotkey. Call once on the main thread
    /// of a process that runs the AppKit event loop.
    @MainActor public static func start(model: any RecorderModel, actions: any RecorderActions, hasMini: Bool = true,
                                        overlay: OverlayOptions = OverlayOptions()) {
        guard controller == nil else { return }
        controller = StatusController(model: model, actions: actions, hasMini: hasMini, overlay: overlay)
    }

    /// Tells `overlay_command` the overlay is gone, so a window manager gives the room back before the recorder quits.
    @MainActor public static func finish() { controller?.finish() }
}

/// The overlay's settings from `recorder.toml`.
public struct OverlayOptions: Sendable {
    public var toggleKey: Shortcut?
    public var sayKey: Shortcut?
    public var command: String?
    public init(toggleKey: Shortcut? = LMLCore.Settings().overlayToggleKey, sayKey: Shortcut? = LMLCore.Settings().overlaySayKey, command: String? = nil) {
        self.toggleKey = toggleKey; self.sayKey = sayKey; self.command = command
    }
    public init(_ settings: LMLCore.Settings) {
        self.init(toggleKey: settings.overlayToggleKey, sayKey: settings.overlaySayKey, command: settings.overlayCommand)
    }
}

@MainActor
final class StatusController: NSObject, NSPopoverDelegate {
    private let store: PanelStore
    private let item: NSStatusItem
    private let popover = NSPopover()
    private var hotkey: Hotkey?
    private var overlay: OverlayController?
    private var timer: Timer?
    private var previousApp: NSRunningApplication?
    private var closedAt: Date?
    private var outsideClickMonitor: Any?
    private var anchor: NSPanel?

    init(model: any RecorderModel, actions: any RecorderActions, hasMini: Bool, overlay options: OverlayOptions) {
        store = PanelStore(snapshot: model.snapshot, actions: actions, hasMini: hasMini, openURL: { NSWorkspace.shared.open($0) })
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        item.button?.target = self
        item.button?.action = #selector(toggle(_:))
        popover.behavior = .transient
        popover.delegate = self
        let content = NSHostingController(rootView: PanelView(store: store))
        content.sizingOptions = .preferredContentSize
        popover.contentViewController = content
        trackIcon()
        let store = store
        hotkey = Hotkey { Task { await store.markMoment() } }
        store.shortcutAvailable = hotkey != nil
        overlay = OverlayController(store: store, options: options)
        model.observe { [weak self] snapshot in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.store.update(snapshot) } }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.resetGrace() }
        }
        tick(every: 30)
    }

    @objc private func toggle(_ button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        if let closedAt, Date().timeIntervalSince(closedAt) < 0.3 { return }
        store.tick()
        previousApp = NSWorkspace.shared.frontmostApplication
        NSApp.activate()
        if let window = button.window, let point = PanelAnchor.point(for: window) {
            let anchor = self.anchor ?? Self.makeAnchor()
            self.anchor = anchor
            anchor.setFrame(NSRect(x: point.x - 1, y: point.y - 1, width: 2, height: 1), display: false)
            anchor.orderFrontRegardless()
            popover.show(relativeTo: anchor.contentView!.bounds, of: anchor.contentView!, preferredEdge: .minY)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        // .transient only sees this app's events, and this accessory app stays inactive, so clicks in other apps need a global monitor
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.popover.performClose(nil) }
        }
        tick(every: 1)
    }

    /// An invisible window the panel hangs from when the status item is hidden or covered (see `PanelAnchor`).
    private static func makeAnchor() -> NSPanel {
        let anchor = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        anchor.isOpaque = false
        anchor.backgroundColor = .clear
        anchor.hasShadow = false
        anchor.ignoresMouseEvents = true
        anchor.level = .statusBar
        anchor.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        return anchor
    }

    func popoverDidClose(_ notification: Notification) {
        anchor?.orderOut(nil)
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        store.panelClosed()
        closedAt = Date()
        tick(every: 30)
        if NSApp.isActive, let previousApp, previousApp != NSRunningApplication.current { previousApp.activate() }
        previousApp = nil
    }

    private func trackIcon() {
        withObservationTracking {
            let icon = store.icon
            item.button?.image = icon.image()
            item.button?.setAccessibilityLabel(PanelCopy.accessibilityName(icon))
            item.button?.toolTip = PanelCopy.accessibilityName(icon)
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.trackIcon() } }
        }
    }

    func finish() { overlay?.finish() }

    private func tick(every seconds: TimeInterval) {
        timer?.invalidate()
        let next = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.tick() }
        }
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }
}
