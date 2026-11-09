import CoreGraphics
import Testing
@testable import LMLPanel

struct TopBarTests {
    let screen = CGRect(x: -2560, y: 949, width: 2560, height: 1080)
    func bar(_ y: CGFloat = 949, width: CGFloat = 2560, height: CGFloat = 32, layer: Int = 101, pid: pid_t = 7) -> TopBar.Window {
        TopBar.Window(bounds: CGRect(x: -2560, y: y, width: width, height: height), layer: layer, pid: pid)
    }

    @Test func aBarAcrossTheTopPushesTheOverlayDown() {
        #expect(TopBar.inset(screen: screen, usableTop: 949, windows: [bar()], ownPid: 1) == 32)
    }
    @Test func aBarBelowTheMenuBarCountsFromTheMenuBar() {
        #expect(TopBar.inset(screen: screen, usableTop: 973, windows: [bar(973, height: 30)], ownPid: 1) == 30)
        #expect(TopBar.inset(screen: screen, usableTop: 973, windows: [bar(949, height: 24)], ownPid: 1) == 0)
    }
    @Test func otherWindowsDoNotCount() {
        let windows = [bar(layer: 0), bar(width: 600), bar(height: 400), bar(1500), bar(pid: 1),
                       TopBar.Window(bounds: CGRect(x: 0, y: 0, width: 1512, height: 32), layer: 101, pid: 7)]
        #expect(TopBar.inset(screen: screen, usableTop: 949, windows: windows, ownPid: 1) == 0)
    }
}
