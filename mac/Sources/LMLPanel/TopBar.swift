import AppKit
import CoreGraphics

/// A bar another app draws along the top of a screen, like a tiling window manager's status bar.
/// macOS leaves it out of `visibleFrame`, so without this the overlay's top would sit under it.
enum TopBar {
    struct Window: Equatable {
        /// Top-left origin, as the window server reports it.
        var bounds: CGRect
        var layer: Int
        var pid: pid_t
    }

    static let maxHeight: CGFloat = 80

    /// How far below `usableTop` the overlay must start. `screen` and `usableTop` are in the same
    /// top-left coordinates as the windows; `usableTop` is where the screen's menu bar ends, if it has one.
    static func inset(screen: CGRect, usableTop: CGFloat, windows: [Window], ownPid: pid_t) -> CGFloat {
        var bottom = usableTop
        for w in windows where w.pid != ownPid && w.layer > 0 && w.bounds.height <= maxHeight {
            let b = w.bounds
            let spans = b.intersection(screen).width >= screen.width * 0.8
            let atTop = b.minY >= screen.minY - 1 && b.minY <= usableTop + 1
            if spans && atTop { bottom = max(bottom, b.maxY) }
        }
        return bottom - usableTop
    }

    /// `screen.visibleFrame` without any bar another app draws at its top.
    @MainActor
    static func usableFrame(of screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let inset = inset(of: screen)
        return NSRect(x: visible.minX, y: visible.minY, width: visible.width, height: visible.height - inset)
    }

    /// How tall a bar another app draws at the top of `screen` is, below its menu bar; 0 when there is none.
    @MainActor
    static func inset(of screen: NSScreen) -> CGFloat {
        let visible = screen.visibleFrame
        guard let primary = NSScreen.screens.first?.frame,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return 0 }
        func flip(_ r: NSRect) -> CGRect { CGRect(x: r.minX, y: primary.maxY - r.maxY, width: r.width, height: r.height) }
        let windows = info.compactMap { w -> Window? in
            guard let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict),
                  let layer = w[kCGWindowLayer as String] as? Int,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t else { return nil }
            return Window(bounds: bounds, layer: layer, pid: pid)
        }
        return inset(screen: flip(screen.frame), usableTop: flip(visible).minY, windows: windows,
                     ownPid: ProcessInfo.processInfo.processIdentifier)
    }
}
