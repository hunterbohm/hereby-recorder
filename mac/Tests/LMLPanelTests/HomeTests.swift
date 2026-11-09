import Foundation
import Testing
import LMLCore
import LMLPanel
import LMLPanelFakes

struct HomeTests {
    let zone = TimeZone(identifier: "America/Chicago")!
    let locale = Locale(identifier: "en_US")

    func countdown(_ start: String, now: String, end: String? = nil) -> String {
        let c = PanelText.countdown(to: at(start), end: end.map(at), now: at(now), in: zone, locale: locale)
        return [c.value, c.unit].filter { !$0.isEmpty }.joined(separator: " ")
    }

    @Test func countdownReadsInMinutesThenHoursThenNow() {
        #expect(countdown("15:00", now: "14:05") == "55 min")
        #expect(countdown("15:00", now: "13:40") == "1 h 20 min")
        #expect(countdown("15:00", now: "12:00") == "3 h")
        #expect(countdown("15:00", now: "15:02", end: "15:30").replacingOccurrences(of: "\u{202F}", with: " ") == "Now started 3:00 PM")
        #expect(countdown("15:00", now: "15:31", end: "15:30") == "Ended")
    }

    @Test func aFiledRecentCallNamesOnlyWhatIsLeft() {
        let snapshot = RecorderSnapshot(feed: FeedBuilder.feed(at: at("15:00"), recent: [
            FeedBuilder.recent("20261026-110000-1a2b", "Client check-in", endedAt: at("11:30"), state: .filed, review: (true, 3)),
            FeedBuilder.recent("20261026-120000-1a2c", "Standup", endedAt: at("12:30"), state: .filed),
            FeedBuilder.recent("20261026-130000-1a2d", "Review", endedAt: at("13:30"), state: .failed),
        ]))
        guard case .idle(let content) = PanelScreen.resolve(snapshot, now: at("15:00"), focus: .list) else {
            Issue.record("expected the list"); return
        }
        #expect(content.recent.map(PanelText.recentDetail).sorted() == ["3 tasks to approve", "Filed", "Filing failed"].sorted())
    }
}
