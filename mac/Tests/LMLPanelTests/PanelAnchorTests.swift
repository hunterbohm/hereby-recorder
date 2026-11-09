import CoreGraphics
import Testing
@testable import LMLPanel

struct PanelAnchorTests {
    // A MacBook and a monitor to its left and below, bottom-left origin as AppKit reports them.
    let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let monitor = CGRect(x: -2560, y: -1047, width: 2560, height: 1080)
    // A window manager's 32-point bar across the top of each screen, over a hidden menu bar.
    func barred(_ screen: CGRect) -> PanelAnchor.Top { .init(y: screen.maxY - 32, covered: true) }
    func bare(_ screen: CGRect) -> PanelAnchor.Top { .init(y: screen.maxY, covered: false) }
    let hiddenItem = CGRect(x: -373, y: 33, width: 24, height: 24) // just above the monitor's top edge

    @Test func aVisibleMenuBarKeepsThePanelOnTheItem() {
        let item = CGRect(x: 1300, y: 958, width: 24, height: 24)
        let menuBar: (CGRect) -> PanelAnchor.Top = { .init(y: $0.maxY - 24, covered: false) }
        #expect(PanelAnchor.point(item: item, mouse: CGPoint(x: 1310, y: 970), screens: [laptop, monitor], top: menuBar) == nil)
    }

    @Test func aClickInAnotherAppsBarHangsThePanelUnderTheClick() {
        #expect(PanelAnchor.point(item: hiddenItem, mouse: CGPoint(x: -361, y: 20), screens: [laptop, monitor], top: barred)
                == CGPoint(x: -361, y: 1))
        #expect(PanelAnchor.point(item: hiddenItem, mouse: CGPoint(x: 1400, y: 970), screens: [laptop, monitor], top: barred)
                == CGPoint(x: 1400, y: 950))
    }

    @Test func aBarOverARevealedMenuBarStillHangsThePanelUnderTheBar() {
        let revealed = CGRect(x: -373, y: 9, width: 24, height: 24) // the menu bar slid down under the bar
        #expect(PanelAnchor.point(item: revealed, mouse: CGPoint(x: -361, y: 20), screens: [laptop, monitor], top: barred)
                == CGPoint(x: -361, y: 1))
    }

    @Test func aHiddenItemWithoutABarHangsThePanelFromTheTopOfThePointedScreen() {
        #expect(PanelAnchor.point(item: hiddenItem, mouse: CGPoint(x: 700, y: 975), screens: [laptop, monitor], top: bare)
                == CGPoint(x: 700, y: 982))
    }

    @Test func withThePointerElsewhereThePanelHangsUnderTheHiddenItem() {
        #expect(PanelAnchor.point(item: hiddenItem, mouse: CGPoint(x: 700, y: 400), screens: [laptop, monitor], top: barred)
                == CGPoint(x: -361, y: 1))
    }
}
