import Foundation
import Testing
import LMLCore
import LMLPanel
import LMLPanelFakes

struct TodayTests {
    @Test func idleShowsTheRestOfTodayAndDropsWhatEndedSinceTheFeed() {
        let today = [FeedBuilder.agenda("Standup", start: at("08:00"), end: at("08:15")),
                     FeedBuilder.agenda("Focus block", start: at("08:30"), end: at("10:00"), meeting: false),
                     FeedBuilder.agenda("Design review", start: at("11:00"), end: at("12:00"), url: "https://meet.google.com/abc")]
        let snapshot = RecorderSnapshot(feed: FeedBuilder.feed(at: at("08:05"), today: today))
        guard case .idle(let content) = PanelScreen.resolve(snapshot, now: at("09:00")) else {
            Issue.record("expected idle"); return
        }
        #expect(content.today.map(\.title) == ["Focus block", "Design review"])
        #expect(content.today[0].meeting == false && content.today[1].meetingURL == "https://meet.google.com/abc")
    }

    @Test func aFeedWithoutTodayDecodesAsNone() {
        let snapshot = RecorderSnapshot(feed: FeedBuilder.feed(at: at("08:05")))
        #expect(snapshot.feed?.today == nil)
        guard case .idle(let content) = PanelScreen.resolve(snapshot, now: at("09:00")) else {
            Issue.record("expected idle"); return
        }
        #expect(content.today.isEmpty)
    }
}

struct BeforeTodayTests {
    @Test func beforeACallTheRestOfTodayStays() {
        let today = [FeedBuilder.agenda("Sync", start: at("10:00"), end: at("10:30"), url: "https://meet.google.com/abc"),
                     FeedBuilder.agenda("Design review", start: at("11:00"), end: at("12:00"))]
        let next = FeedBuilder.meeting("Sync", start: at("10:00"), end: at("10:30"), url: "https://meet.google.com/abc")
        let snapshot = RecorderSnapshot(feed: FeedBuilder.feed(at: at("09:50"), next: next, today: today))
        guard case .before(let content) = PanelScreen.resolve(snapshot, now: at("09:50")) else {
            Issue.record("expected before"); return
        }
        #expect(content.today.map(\.title) == ["Sync", "Design review"])
    }
}
