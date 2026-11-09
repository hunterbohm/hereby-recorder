import AppKit
import SwiftUI
import LMLCore
import LMLPanel
import LMLPanelFakes

@main
struct PanelSnapshots {
    static let maxHeight: CGFloat = 640
    static let overlayStripHeight: CGFloat = 760
    @MainActor static var windows: [NSWindow] = []

    @MainActor static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--measure"] {
            await Measure.run()
            return
        }
        guard arguments.count == 1 else {
            FileHandle.standardError.write(Data("usage: lml-panel-snapshots <dir> | --measure\n".utf8))
            exit(2)
        }
        let directory = URL(fileURLWithPath: arguments[0], isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scenarios = await PanelScenarios.all()
        var oversized: [String] = []
        for scenario in scenarios {
            for dark in [false, true] {
                let name = "\(scenario.name)-\(dark ? "dark" : "light")"
                let size = render(PanelView(store: scenario.store), dark: dark, to: directory.appendingPathComponent(name + ".png"))
                print("\(name).png \(Int(size.width))x\(Int(size.height))")
                if size.width != PanelRules.width || size.height > maxHeight { oversized.append(name) }
            }
            scenario.recorder.release()
        }
        for scenario in await PanelScenarios.overlays() {
            for style in OverlayStyle.allCases {
                for open in style == .pill ? [false, true] : [false] {
                    scenario.store.overlayStyle = style
                    scenario.store.pillOpen = open
                    let name = "\(scenario.name)-\(style.rawValue)\(open ? "-open" : "")"
                    let view = OverlayView(store: scenario.store).frame(height: style == .strip ? overlayStripHeight : nil)
                    let size = render(view.padding(24), dark: true, backdrop: true, to: directory.appendingPathComponent(name + ".png"))
                    print("\(name).png \(Int(size.width))x\(Int(size.height))")
                }
            }
            scenario.recorder.release()
        }
        for dark in [false, true] {
            let name = "status-icons-\(dark ? "dark" : "light")"
            let size = render(IconSheet(), dark: dark, to: directory.appendingPathComponent(name + ".png"))
            print("\(name).png \(Int(size.width))x\(Int(size.height))")
        }
        guard oversized.isEmpty else {
            FileHandle.standardError.write(Data("wrong size: \(oversized.joined(separator: ", "))\n".utf8))
            exit(1)
        }
    }

    /// Hosts the view in a borderless window that is never ordered front, far off any screen, so scroll views get real
    /// geometry without anything appearing on the display.
    @MainActor static func host(_ view: some View, dark: Bool, backdrop: Bool = false) -> NSHostingView<some View> {
        let root = view
            .background(backdrop ? AnyShapeStyle(LinearGradient(colors: [Color(white: 0.18), Color(red: 0.13, green: 0.16, blue: 0.24)],
                                                                startPoint: .topLeading, endPoint: .bottomTrailing))
                                 : AnyShapeStyle(Color(nsColor: .windowBackgroundColor)))
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -20000, y: -20000), size: size), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        windows.append(window)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        precondition(!window.isVisible)
        return host
    }

    @MainActor static func render(_ view: some View, dark: Bool, backdrop: Bool = false, to url: URL) -> CGSize {
        let host = host(view, dark: dark, backdrop: backdrop)
        Measure.settle(host)
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("no bitmap for \(url.lastPathComponent)") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try! bitmap.representation(using: .png, properties: [:])!.write(to: url)
        return host.bounds.size
    }
}

/// Times the main-thread work the panel does with a full conversation: a one-second tick, a new line arriving, and the
/// recorder's own snapshot publish and compare.
enum Measure {
    static let rounds = 60

    @MainActor static func run() async {
        for count in [4, RecorderSnapshot.lineLimit] {
            let lines = (0..<count).map { TranscriptLine(speaker: $0.isMultiple(of: 2) ? "me" : "them",
                                                         text: "Line \($0) about the SOP library and the Poland numbers for next week.",
                                                         at: Date(timeIntervalSince1970: 1_800_000_000 + Double($0) * 7)) }
            let started = Date(timeIntervalSince1970: 1_800_000_000 - 60)
            var snapshot = RecorderSnapshot(phase: .recording, sid: "20261026-150000-440d", title: "Weekly Sync with Dana",
                                            startedAt: started, lines: lines, marks: 0,
                                            feed: FeedBuilder.feed(at: Date(timeIntervalSince1970: 1_800_000_000)))
            var clock = Date(timeIntervalSince1970: 1_800_000_000 + Double(count) * 7)
            let store = PanelStore(snapshot: snapshot, actions: FakeRecorder(snapshot), clock: { clock }, openURL: { _ in })
            let view = PanelSnapshots.host(PanelView(store: store), dark: false)
            settle(view)
            func arrive() {
                snapshot.lines.append(TranscriptLine(speaker: "them", text: "A new line just finalized.", at: clock))
                if snapshot.lines.count > RecorderSnapshot.lineLimit { snapshot.lines.removeFirst() }
                store.update(snapshot)
            }
            let tick = time(rounds) {
                clock = clock.addingTimeInterval(1)
                store.tick()
                view.layoutSubtreeIfNeeded()
            }
            let line = time(rounds) {
                arrive()
                view.layoutSubtreeIfNeeded()
            }
            let draws = time(rounds) { draw(view) }
            let recorder = RecorderStore(snapshot)
            let same = time(rounds * 10) { recorder.update { $0.lines = snapshot.lines } }
            let changed = time(rounds * 10) {
                var next = snapshot.lines
                next[next.count - 1].text += "."
                recorder.update { $0.lines = next }
            }
            print("lines=\(count) tick+layout \(report(tick)) | new line+layout \(report(line)) | full redraw \(report(draws))")
            print("lines=\(count) recorder publish unchanged \(report(same)) | changed \(report(changed))")
        }
        scrolling()
    }

    /// Below the 400-line cap, so a new line only adds: the view opens at the newest line, follows new lines while at the
    /// bottom, and stays put once scrolled up.
    @MainActor static func scrolling() {
        var snapshot = RecorderSnapshot(phase: .recording, sid: "20261026-150000-440d", title: "Weekly Sync with Dana",
                                        startedAt: Date(timeIntervalSince1970: 1_800_000_000 - 60),
                                        lines: (0..<300).map { TranscriptLine(speaker: "them", text: "Line \($0)", at: Date(timeIntervalSince1970: 1_800_000_000 + Double($0) * 7)) },
                                        feed: FeedBuilder.feed(at: Date(timeIntervalSince1970: 1_800_000_000)))
        let clock = Date(timeIntervalSince1970: 1_800_000_000 + 2200)
        let store = PanelStore(snapshot: snapshot, actions: FakeRecorder(snapshot), clock: { clock }, openURL: { _ in })
        let view = PanelSnapshots.host(PanelView(store: store), dark: false)
        settle(view)
        guard let scroll = scrollView(in: view) else { print("no scroll view"); return }
        func arrive() {
            snapshot.lines.append(TranscriptLine(speaker: "me", text: "A new line just finalized.", at: clock))
            store.update(snapshot)
            settle(view)
        }
        let bottom = { scroll.contentView.bounds.maxY >= (scroll.documentView?.frame.height ?? 0) - 1 }
        print("opens at the newest line: \(bottom())")
        arrive()
        print("follows a new line while at the bottom: \(bottom())")
        snapshot.lines.insert(TranscriptLine(speaker: "them", text: String(repeating: "A long line that finalized late. ", count: 6),
                                             at: clock.addingTimeInterval(-1)), at: snapshot.lines.count - 1)
        store.update(snapshot)
        settle(view)
        print("follows a long line that finalized late while at the bottom: \(bottom())")
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 200))
        scroll.reflectScrolledClipView(scroll.contentView)
        settle(view)
        let height = scroll.documentView?.frame.height ?? 0
        arrive()
        let grown = (scroll.documentView?.frame.height ?? 0) - height
        print("stays put after scrolling up: \(abs(scroll.contentView.bounds.minY - 200) < 1) (y=\(scroll.contentView.bounds.minY), content grew \(grown))")
    }

    @MainActor static func settle(_ view: NSView) {
        for _ in 0..<5 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            view.layoutSubtreeIfNeeded()
        }
    }

    @MainActor static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, (scroll.documentView?.frame.height ?? 0) > scroll.contentView.bounds.height { return scroll }
        return view.subviews.lazy.compactMap(scrollView).first
    }

    @MainActor static func draw(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
    }

    static func time(_ rounds: Int, _ work: () -> Void) -> [Double] {
        (0..<rounds).map { _ in
            let start = DispatchTime.now().uptimeNanoseconds
            work()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }
    }

    static func report(_ samples: [Double]) -> String {
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2], p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
        return String(format: "median %.3f ms p95 %.3f ms max %.3f ms (n=%d)", median, p95, sorted.last ?? 0, sorted.count)
    }
}

struct IconSheet: View {
    static let icons: [StatusIcon] = [
        .idle, .armed, .recording, .paused, .filed, .marked, .markMissed,
        .problem(Health(micOK: false, audioOK: true, miniReachable: true, lastContact: nil)),
        .problem(Health(micOK: true, audioOK: false, miniReachable: true, lastContact: nil)),
        .problem(Health(micOK: true, audioOK: true, miniReachable: false, lastContact: nil))
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.icons.enumerated()), id: \.offset) { _, icon in
                HStack(spacing: 10) {
                    if let image = icon.image() {
                        Image(nsImage: image).frame(width: 22, height: 22)
                    } else {
                        Text("missing").foregroundStyle(.red)
                    }
                    Text(PanelCopy.accessibilityName(icon)).font(.callout)
                }
            }
        }
        .padding(12)
        .frame(width: 520, alignment: .leading)
    }
}
