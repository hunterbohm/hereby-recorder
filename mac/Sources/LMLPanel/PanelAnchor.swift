import AppKit
import CoreGraphics

/// Where the panel hangs when the status item is out of sight. With the menu bar set to hide, the item
/// sits just above the top of the screen until the pointer reveals it, and a panel shown from it then can
/// land off every screen. And a bar another app draws over the top of the screen, like a tiling window
/// manager's with a tray, covers both the menu bar and the top of the panel. In both cases the panel
/// hangs from an invisible window instead, at the top of the screen and below that bar.
enum PanelAnchor {
    /// The top of a screen's room: below its menu bar and below any bar another app draws there.
    struct Top: Equatable {
        var y: CGFloat
        /// Another app's bar covers the top of the screen.
        var covered: Bool
    }

    /// The point, in screen coordinates (bottom-left origin), the panel's arrow should touch, or nil when
    /// it can hang from the status item as usual. A click in another app's bar puts it under the click;
    /// otherwise, when the item is off every screen, it goes under the item, or under the pointer when
    /// the pointer is near the top of a screen.
    static func point(item: CGRect, mouse: CGPoint, screens: [CGRect], top: (CGRect) -> Top) -> CGPoint? {
        let pointed = screens.first { mouse.x >= $0.minX && mouse.x < $0.maxX && mouse.y >= $0.maxY - TopBar.maxHeight && mouse.y <= $0.maxY }
        if let screen = pointed, top(screen).covered { return CGPoint(x: mouse.x, y: top(screen).y) }
        guard !screens.isEmpty, !screens.contains(where: { !$0.intersection(item).isEmpty }) else { return nil }
        if let screen = pointed { return CGPoint(x: mouse.x, y: top(screen).y) }
        let screen = screens.first { item.midX >= $0.minX && item.midX < $0.maxX && abs(item.minY - $0.maxY) <= 1 }
            ?? screens.first { item.midX >= $0.minX && item.midX < $0.maxX } ?? screens[0]
        return CGPoint(x: min(max(item.midX, screen.minX), screen.maxX - 1), y: top(screen).y)
    }

    /// `point` for the live screens and status item window.
    @MainActor
    static func point(for item: NSWindow) -> CGPoint? {
        let screens = NSScreen.screens
        return point(item: item.frame, mouse: NSEvent.mouseLocation, screens: screens.map(\.frame)) { frame in
            guard let screen = screens.first(where: { $0.frame == frame }) else { return Top(y: frame.maxY, covered: false) }
            let bar = TopBar.inset(of: screen)
            return Top(y: screen.visibleFrame.maxY - bar, covered: bar > 0)
        }
    }
}
