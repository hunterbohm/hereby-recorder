import AppKit
import SwiftUI
import LMLCore
import LMLPanel
import LMLPanelFakes

/// Renders the setup window inside the same panel `SetupWindow` makes (transparent title bar, close button only), at 1x
/// and 2x, into `<dir>/<state>-<light|dark>@<scale>x.png`, then every state on one sheet per scheme,
/// `<dir>/sheet-<light|dark>.png`.
enum SetupShots {
    /// The window's corner on this macOS (NSWindow `_cornerRadius` for a titled panel).
    static let corner: CGFloat = 16

    @MainActor static func run(into directory: URL) async {
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var states: [String] = []
        for scenario in await PanelScenarios.setups() {
            let state = String(scenario.name.dropFirst("setup-".count))
            states.append(state)
            for dark in [false, true] {
                for scale in [1, 2] {
                    let name = "\(state)-\(dark ? "dark" : "light")@\(scale)x"
                    let size = render(SetupView(store: scenario.store), dark: dark, scale: CGFloat(scale),
                                      to: directory.appendingPathComponent(name + ".png"))
                    if scale == 1 { print("\(name).png \(Int(size.width))x\(Int(size.height))") }
                }
            }
            scenario.recorder.release()
        }
        for dark in [false, true] {
            let name = "sheet-\(dark ? "dark" : "light").png"
            draw(Sheet(folder: directory, states: states, dark: dark), scale: 1, to: directory.appendingPathComponent(name))
            print(name)
        }
    }

    /// The window `SetupWindow.make()` builds, never ordered front, drawn with its frame so the title bar and close
    /// button land where they will on screen, and cut to the window's rounded corners.
    @MainActor static func render(_ view: some View, dark: Bool, scale: CGFloat, to url: URL) -> CGSize {
        let window = NSPanel(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered,
                             defer: true)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingController(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        host.sizingOptions = .preferredContentSize
        window.contentViewController = host
        window.setContentSize(host.view.fittingSize)
        window.setFrameOrigin(CGPoint(x: -20000, y: -20000))
        PanelSnapshots.windows.append(window)
        let frame = window.contentView!.superview!
        Measure.settle(frame)
        window.setContentSize(host.view.fittingSize)
        Measure.settle(frame)
        precondition(!window.isVisible)
        let bounds = frame.bounds
        let flat = bitmap(bounds.size, scale: scale)
        frame.cacheDisplay(in: bounds, to: flat)
        let cut = bitmap(bounds.size, scale: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: cut)
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: bounds.size), xRadius: corner, yRadius: corner).addClip()
        flat.draw(in: NSRect(origin: .zero, size: bounds.size))
        NSGraphicsContext.restoreGraphicsState()
        try! cut.representation(using: .png, properties: [:])!.write(to: url)
        return bounds.size
    }

    static func bitmap(_ size: CGSize, scale: CGFloat) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        return rep
    }

    @discardableResult @MainActor static func draw(_ view: some View, scale: CGFloat, to url: URL) -> CGSize {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .light))
        host.appearance = NSAppearance(named: .aqua)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -20000, y: -20000), size: size), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        PanelSnapshots.windows.append(window)
        host.frame = NSRect(origin: .zero, size: size)
        Measure.settle(host)
        let rep = bitmap(size, scale: scale)
        host.cacheDisplay(in: host.bounds, to: rep)
        try! rep.representation(using: .png, properties: [:])!.write(to: url)
        return size
    }
}

/// One rendered window as it sits on the desktop: its own corners, a hairline edge and a soft shadow.
private struct Shot: View {
    let url: URL

    var body: some View {
        if let image = NSImage(contentsOf: url), let rep = image.representations.first {
            let size = CGSize(width: CGFloat(rep.pixelsWide) / 2, height: CGFloat(rep.pixelsHigh) / 2)
            let shape = RoundedRectangle(cornerRadius: SetupShots.corner, style: .continuous)
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size.width, height: size.height)
                .overlay(shape.strokeBorder(Color.black.opacity(0.14), lineWidth: 0.5))
                .background(shape.fill(Color.black.opacity(0.001)).shadow(color: .black.opacity(0.16), radius: 18, y: 10))
        } else {
            Text("missing \(url.lastPathComponent)").foregroundStyle(.red)
        }
    }
}

/// Every state in one scheme, three to a row, for review.
private struct Sheet: View {
    let folder: URL
    let states: [String]
    let dark: Bool

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 40, verticalSpacing: 28) {
            ForEach(Array(stride(from: 0, to: states.count, by: 3)), id: \.self) { start in
                GridRow {
                    ForEach(states[start..<min(start + 3, states.count)], id: \.self) { state in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(state).font(.system(size: 13)).foregroundStyle(.secondary)
                            Shot(url: folder.appendingPathComponent("\(state)-\(dark ? "dark" : "light")@2x.png"))
                        }
                    }
                }
            }
        }
        .padding(48)
        .background(Color(red: 0.89, green: 0.89, blue: 0.9))
    }
}
