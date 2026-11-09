import Foundation
import Testing
@testable import LMLPanel

struct OverlayEdgeTests {
    @Test func onlyTheStripTakesRoom() {
        #expect(OverlayEdge(style: .strip, display: "A").width == 328)
        #expect(OverlayEdge(style: .card, display: "A").width == 0)
        #expect(OverlayEdge(style: .pill, display: "A").width == 0)
        #expect(OverlayEdge.off.environment == ["HEREBY_OVERLAY": "off", "HEREBY_OVERLAY_WIDTH": "0"])
        #expect(OverlayEdge(style: .strip, display: "A").environment
                == ["HEREBY_OVERLAY": "strip", "HEREBY_OVERLAY_WIDTH": "328", "HEREBY_OVERLAY_DISPLAY": "A"])
    }
    @Test func goingOffFreesTheDisplayTheOverlayWasOn() {
        let strip = OverlayEdge(style: .strip, display: "A")
        #expect(OverlayEdge.off.changes(from: strip) == [OverlayEdge(style: nil, width: 0, display: "A")])
        #expect(OverlayEdge.off.changes(from: OverlayEdge(style: nil, width: 0, display: "A")) == [])
        #expect(strip.changes(from: strip) == [])
    }
    @Test func aStripThatMovesScreensFreesTheOldOneFirst() {
        let a = OverlayEdge(style: .strip, display: "A"), b = OverlayEdge(style: .strip, display: "B")
        #expect(b.changes(from: a) == [OverlayEdge(style: nil, width: 0, display: "A"), b])
        let card = OverlayEdge(style: .card, display: "B")
        #expect(b.changes(from: card) == [b])
    }
}

struct OverlayCommandTests {
    func lines(_ file: URL) -> [String] {
        ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
    @Test func runsOncePerChangeInOrderAndFreesTheScreenWhenFinished() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("overlay-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: file) }
        let command = OverlayCommand("echo \"$HEREBY_OVERLAY $HEREBY_OVERLAY_WIDTH ${HEREBY_OVERLAY_DISPLAY:-none}\" >> '\(file.path)'")
        command.announce(OverlayEdge(style: .strip, display: "A"))
        command.announce(OverlayEdge(style: .strip, display: "A"))
        command.announce(OverlayEdge(style: .card, display: "A"))
        command.announce(OverlayEdge(style: .strip, display: "B"))
        command.finish()
        #expect(lines(file) == ["strip 328 A", "card 0 A", "strip 328 B", "off 0 B"])
    }
    @Test func aCommandThatHangsIsStopped() {
        let command = OverlayCommand("sleep 30", timeout: 0.2)
        let start = Date()
        command.announce(OverlayEdge(style: .strip, display: "A"))
        command.finish()
        #expect(Date().timeIntervalSince(start) < 5)
    }
    @Test func aTimedOutCommandTakesItsChildrenWithIt() throws {
        let mark = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("overlay-child-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: mark) }
        // The child ignores SIGTERM and would mark the file a second later if it outlived the timeout.
        OverlayCommand.run("(trap '' TERM; sleep 1; touch '\(mark.path)') & wait", environment: [:], timeout: 0.2, grace: 0.2)
        Thread.sleep(forTimeInterval: 1.5)
        #expect(!FileManager.default.fileExists(atPath: mark.path))
    }
}
