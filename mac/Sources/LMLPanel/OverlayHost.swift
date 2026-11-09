import AppKit
import SwiftUI
import Carbon.HIToolbox
import LMLCore

/// Keyboard focus without activating the recorder, so the meeting app stays frontmost.
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Tells the controller each time the overlay's content changes size.
private final class SizingHost<Content: View>: NSHostingView<Content> {
    var onResize: (() -> Void)?
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onResize?()
    }
}

/// Shows the overlay over every window while a call is live, hides it otherwise, and keeps it out of screen shares.
@MainActor
final class OverlayController {
    static let styleKey = "overlayStyle"
    private let store: PanelStore
    private let panel: OverlayPanel
    private let host: SizingHost<OverlayView>
    private var hotkeys: [Hotkey] = []
    private var placedStyle: OverlayStyle?
    private let defaults: UserDefaults
    private let command: OverlayCommand?

    init(store: PanelStore, options: OverlayOptions = OverlayOptions(), defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        command = options.command.map { OverlayCommand($0) }
        store.overlayStyle = defaults.string(forKey: Self.styleKey).flatMap(OverlayStyle.init) ?? .strip
        panel = OverlayPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                             backing: .buffered, defer: true)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.sharingType = .none
        panel.setAccessibilityTitle("Meeting overlay")
        host = SizingHost(rootView: OverlayView(store: store))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        host.onResize = { [weak self] in DispatchQueue.main.async { self?.fit() } }
        var keys: [Hotkey] = []
        func register(_ key: Shortcut?, action: @escaping @MainActor () -> Void) -> String? {
            guard let key, let hotkey = Hotkey(keyCode: Int(key.keyCode), modifiers: Int(key.modifiers), action: action) else { return nil }
            keys.append(hotkey)
            return key.symbol
        }
        store.overlayToggleHint = register(options.toggleKey) { [weak store] in store?.toggleOverlay() }
        store.overlaySayHint = register(options.sayKey) { [weak store] in Task { await store?.quickAsk(.say) } }
        hotkeys = keys
        // A recorder that quit without telling the window manager left room reserved; free every screen once.
        for screen in NSScreen.screens {
            command?.announce(OverlayEdge(style: nil, display: OverlayEdge.uuid(of: screen)), force: true)
        }
        track()
    }

    private func track() {
        withObservationTracking {
            let visible = store.overlayVisible
            let style = store.overlayStyle
            apply(visible: visible, style: style)
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.track() } }
        }
    }

    private func apply(visible: Bool, style: OverlayStyle) {
        if defaults.string(forKey: Self.styleKey) != style.rawValue { defaults.set(style.rawValue, forKey: Self.styleKey) }
        guard visible else {
            if panel.isVisible { panel.orderOut(nil) }
            placedStyle = nil
            command?.announce(.off)
            return
        }
        if placedStyle != style { place(style) }
        if !panel.isVisible { panel.orderFrontRegardless() }
        command?.announce(OverlayEdge(style: style, display: (panel.screen ?? NSScreen.main).flatMap(OverlayEdge.uuid)))
    }

    func finish() { command?.finish() }

    /// Puts each style in its home spot: the strip down the right edge, the card top right, the pill under the menu bar.
    private func place(_ style: OverlayStyle) {
        placedStyle = style
        guard let screen = NSScreen.main else { return }
        let frame = TopBar.usableFrame(of: screen)
        let size = host.fittingSize
        let origin: CGPoint
        switch style {
        case .strip:
            let margin = OverlayRules.stripMargin
            panel.setFrame(NSRect(x: frame.maxX - OverlayRules.stripWidth - margin, y: frame.minY + margin,
                                  width: OverlayRules.stripWidth, height: frame.height - 2 * margin), display: true)
            return
        case .card: origin = CGPoint(x: frame.maxX - size.width - 16, y: frame.maxY - size.height - 16)
        case .pill: origin = CGPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 6)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    /// Card and pill grow and shrink with their content and keep their top edge; the pill also keeps its center.
    private func fit() {
        guard let style = placedStyle, style != .strip else { return }
        let size = host.fittingSize
        let old = panel.frame
        guard abs(old.width - size.width) > 0.5 || abs(old.height - size.height) > 0.5 else { return }
        let x = style == .pill ? old.midX - size.width / 2 : old.maxX - size.width
        panel.setFrame(NSRect(x: x, y: old.maxY - size.height, width: size.width, height: size.height), display: true)
    }
}
