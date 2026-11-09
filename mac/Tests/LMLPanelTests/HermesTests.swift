import Foundation
import Testing
import LMLCore
import LMLPanel
import LMLPanelFakes

private let meetURL = "https://meet.google.com/abc-defg-hij"
private let key = "5n3k0f2h8q1c7d9e_20261023T200000Z"

private func next(_ hermes: FeedBuilder.Object? = nil, url: String? = meetURL, key: String? = key) -> FeedBuilder.Object {
    FeedBuilder.meeting("Sync with Dana", start: at("15:00"), end: at("15:45"), url: url, key: key, hermes: hermes)
}

private func home(feedAt: String = "13:00", _ next: FeedBuilder.Object? = nil, today: [FeedBuilder.Object]? = nil) -> RecorderSnapshot {
    RecorderSnapshot(feed: FeedBuilder.feed(at: at(feedAt), next: next, today: today))
}

@MainActor
private func heroTarget(_ store: PanelStore) -> HermesTarget? {
    guard case .idle(let content) = store.screen, let meeting = content.next else { return nil }
    return store.hermesTarget(for: meeting)
}

struct HermesDecodingTests {
    private func feed(_ hermes: Any?, extra: [String: Any] = [:]) throws -> PanelFeed {
        var meeting: [String: Any] = ["title": "Sync", "start": "2026-10-23T15:00:00-05:00", "brief": [], "key": "k"]
        if let hermes { meeting["hermes"] = hermes }
        let object: [String: Any] = ["v": 1, "at": "2026-10-23T13:00:00-05:00", "next": meeting.merging(extra) { $1 }, "recent": []]
        return try JSON.decoder().decode(PanelFeed.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test func aMissingFieldIsOffAndKeepsTheRestOfTheFeed() throws {
        let feed = try feed(nil)
        #expect(feed.next?.hermes == nil)
        #expect(feed.next?.hermesState == .off)
        #expect(feed.next?.key == "k")
    }

    @Test func everyContractStateDecodesWithItsChatFlagAndReason() throws {
        let states: [(String, PanelHermes.Phase)] = [("off", .off), ("scheduled", .scheduled), ("joining", .joining),
                                                      ("waiting_room", .waitingRoom), ("in_call", .inCall), ("done", .done), ("failed", .failed)]
        for (raw, phase) in states {
            let decoded = try feed(["state": raw, "chat": true, "error": "no luck"]).next?.hermesState
            #expect(decoded == PanelHermes(phase: phase, chat: true, error: "no luck"), "\(raw)")
        }
        #expect(try feed(["state": "scheduled", "chat": false, "error": NSNull()]).next?.hermesState == PanelHermes(phase: .scheduled))
    }

    @Test func anUnknownOrMalformedValueIsOffAndNeverBreaksTheFeed() throws {
        #expect(try feed(["state": "teleporting", "chat": true]).next?.hermesState == PanelHermes(phase: .off, chat: true))
        #expect(try feed(["state": 7, "chat": "yes", "error": 3]).next?.hermesState == .off)
        #expect(try feed("in_call").next?.hermesState == .off)
        #expect(try feed([1, 2]).next?.hermesState == .off)
        #expect(try feed(NSNull()).next?.hermesState == .off)
        #expect(try feed([:]).next?.hermesState == .off)
        #expect(try feed("in_call").next?.title == "Sync")
    }

    @Test func aBlankReasonIsNoReason() throws {
        #expect(try feed(["state": "failed", "error": "  "]).next?.hermesState.error == nil)
    }

    @Test func todayItemsDecodeTheSameWay() throws {
        let object: [String: Any] = ["v": 1, "at": "2026-10-23T13:00:00-05:00", "recent": [], "next": NSNull(), "today": [
            ["title": "A", "start": "2026-10-23T14:00:00-05:00", "end": "2026-10-23T14:30:00-05:00", "meeting": true,
             "key": "a", "hermes": ["state": "joining", "chat": false, "error": NSNull()]],
            ["title": "B", "start": "2026-10-23T15:00:00-05:00", "end": "2026-10-23T15:30:00-05:00", "meeting": true, "hermes": 4]]]
        let feed = try JSON.decoder().decode(PanelFeed.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(feed.today?[0].key == "a" && feed.today?[0].hermesState.phase == .joining)
        #expect(feed.today?[1].key == nil && feed.today?[1].hermesState == .off)
    }
}

@MainActor
struct HermesControlTests {
    @Test func onlyMeetCallsWithAKeyOnAMiniGetControls() {
        let withMeet = PanelStore(snapshot: home(next()), actions: FakeRecorder(), clock: { at("13:00") }, openURL: { _ in })
        #expect(heroTarget(withMeet)?.key == key)
        let zoom = PanelStore(snapshot: home(next(url: zoomURL)), actions: FakeRecorder(), clock: { at("13:00") }, openURL: { _ in })
        #expect(heroTarget(zoom) == nil)
        let noLink = PanelStore(snapshot: home(next(url: nil)), actions: FakeRecorder(), clock: { at("13:00") }, openURL: { _ in })
        #expect(heroTarget(noLink) == nil)
        let oldMini = PanelStore(snapshot: home(next(key: nil)), actions: FakeRecorder(), clock: { at("13:00") }, openURL: { _ in })
        #expect(heroTarget(oldMini) == nil)
        let local = PanelStore(snapshot: home(next()), actions: FakeRecorder(), clock: { at("13:00") }, hasMini: false, openURL: { _ in })
        #expect(heroTarget(local) == nil)
    }

    @Test func rowsFollowTheSameRules() {
        let today = [FeedBuilder.agenda("A", start: at("14:00"), end: at("14:30"), url: meetURL, key: "a"),
                     FeedBuilder.agenda("B", start: at("15:00"), end: at("15:30"), url: zoomURL, key: "b"),
                     FeedBuilder.agenda("C", start: at("16:00"), end: at("16:30"), url: meetURL)]
        let store = PanelStore(snapshot: home(today: today), actions: FakeRecorder(), clock: { at("13:00") }, openURL: { _ in })
        guard case .idle(let content) = store.screen else { Issue.record("expected idle"); return }
        #expect(content.today.map { store.hermesTarget(for: $0)?.key } == ["a", nil, nil])
    }

    @Test func sendingHermesShowsAtOnceThenSticksOnceTheMiniAnswers() async throws {
        let h = Harness(home(next()), now: at("13:00"))
        let target = try #require(heroTarget(h.store))
        #expect(h.store.hermes(target).phase == .off)
        h.recorder.hold()
        let task = Task { await h.store.setHermes(target, .join) }
        await h.waitForCall()
        #expect(h.store.hermes(target) == PanelHermes(phase: .scheduled))
        #expect(h.store.isHermesPending(key))
        #expect(h.store.action == .idle)
        h.recorder.release()
        await task.value
        #expect(h.recorder.calls == [.hermesOptIn(key)])
        #expect(!h.store.isHermesPending(key))
        #expect(h.store.hermes(target).phase == .scheduled)
    }

    @Test func aFailedCommandPutsTheOldStateBackAndShowsTheFailureLine() async throws {
        let h = Harness(home(next()), now: at("13:00"))
        let target = try #require(heroTarget(h.store))
        h.recorder.failCalls(true)
        await h.store.setHermes(target, .join)
        #expect(h.store.hermes(target).phase == .off)
        #expect(h.store.action == .failed(.hermes(key: key, change: .join)))
        #expect(PanelCopy.failure(.hermes(key: key, change: .join)) == "Couldn't send Hermes. Try again.")
        #expect(!h.store.isHermesPending(key))
        // The next change clears the failure.
        h.recorder.failCalls(false)
        await h.store.setHermes(target, .join)
        #expect(h.store.action == .idle)
        #expect(h.store.hermes(target).phase == .scheduled)
    }

    @Test func aFailedCancelKeepsHermesScheduled() async throws {
        let h = Harness(home(next(FeedBuilder.hermes("scheduled", chat: true))), now: at("13:00"))
        let target = try #require(heroTarget(h.store))
        h.recorder.failCalls(true)
        await h.store.setHermes(target, .leave)
        #expect(h.store.hermes(target) == PanelHermes(phase: .scheduled, chat: true))
        #expect(h.store.action == .failed(.hermes(key: key, change: .leave)))
    }

    @Test func chatReplyChangesGoToTheMiniAndRollBackOnFailure() async throws {
        let h = Harness(home(next(FeedBuilder.hermes("scheduled"))), now: at("13:00"))
        let target = try #require(heroTarget(h.store))
        await h.store.setHermes(target, .chat(true))
        #expect(h.store.hermes(target) == PanelHermes(phase: .scheduled, chat: true))
        h.recorder.failCalls(true)
        await h.store.setHermes(target, .chat(false))
        #expect(h.recorder.calls == [.hermesChat(key, true), .hermesChat(key, false)])
        #expect(h.store.hermes(target).chat)
        #expect(PanelCopy.failure(.hermes(key: key, change: .chat(false))) == "Couldn't change chat replies. Try again.")
    }

    @Test func cancelAsksTheMiniToOptOutAndTurnsChatOff() async throws {
        let h = Harness(home(next(FeedBuilder.hermes("in_call", chat: true))), now: at("13:00"))
        let target = try #require(heroTarget(h.store))
        await h.store.setHermes(target, .leave)
        #expect(h.recorder.calls == [.hermesOptOut(key)])
        #expect(h.store.hermes(target) == .off)
    }

    @Test func joiningKeepsTheChatSettingTheMiniReported() async throws {
        let h = Harness(home(next(FeedBuilder.hermes("off", chat: true))), now: at("13:00"))
        let target = try #require(heroTarget(h.store))
        await h.store.setHermes(target, .join)
        #expect(h.store.hermes(target) == PanelHermes(phase: .scheduled, chat: true))
    }

    @Test func aChangeToTheStateItAlreadyShowsSendsNothing() async throws {
        let h = Harness(home(next(FeedBuilder.hermes("scheduled", chat: false))), now: at("13:00"))
        let target = try #require(heroTarget(h.store))
        await h.store.setHermes(target, .join)
        await h.store.setHermes(target, .chat(false))
        #expect(h.recorder.calls.isEmpty)
    }

    @Test func controlsForOneEventWaitWhileItsCommandIsOut() async throws {
        let h = Harness(home(next()), now: at("13:00"))
        let target = try #require(heroTarget(h.store))
        h.recorder.hold()
        let first = Task { await h.store.setHermes(target, .join) }
        await h.waitForCall()
        await h.store.setHermes(target, .chat(true))
        #expect(h.recorder.calls == [.hermesOptIn(key)])
        h.recorder.release()
        await first.value
    }

    @Test func aNewerFeedReplacesWhatTheUserAskedForAnOlderOneDoesNot() async throws {
        let h = Harness(home(feedAt: "12:59", next()), now: at("13:00"))
        let target = try #require(heroTarget(h.store))
        await h.store.setHermes(target, .join)
        h.now = at("13:00:30")
        // A feed the mini built before the command returned still says off.
        h.store.update(home(feedAt: "13:00", next()))
        #expect(h.store.hermes(target).phase == .scheduled)
        let fresh = home(feedAt: "13:01", next(FeedBuilder.hermes("joining")))
        h.now = at("13:01:10")
        h.store.update(fresh)
        let updated = try #require(heroTarget(h.store))
        #expect(h.store.hermes(updated).phase == .joining)
    }

    @Test func whatTheUserAskedForExpiresWithoutANewFeed() async throws {
        let h = Harness(home(feedAt: "12:59", next()), now: at("13:00"))
        let target = try #require(heroTarget(h.store))
        await h.store.setHermes(target, .join)
        h.now = at("13:03:01")
        h.store.tick()
        #expect(h.store.hermes(target).phase == .off)
    }

    @Test func whileACallIsLiveTheMatchedEventsHermesShowsAndCanBeRemoved() async throws {
        let live = RecorderSnapshot(phase: .recording, sid: sid, title: "Sync with Dana", eventStart: at("15:00"), startedAt: at("15:00:26"),
                                    feed: FeedBuilder.feed(at: at("15:12"), next: next(FeedBuilder.hermes("in_call", chat: true))))
        let h = Harness(live, now: at("15:12:30"))
        let target = try #require(h.store.liveHermes)
        #expect(target.key == key)
        #expect(h.store.hermes(target) == PanelHermes(phase: .inCall, chat: true))
        await h.store.setHermes(target, .leave)
        #expect(h.recorder.calls == [.hermesOptOut(key)])
        #expect(h.store.hermes(h.store.liveHermes!) == .off)
    }

    @Test func aLiveCallFindsItsEventAmongTodayWhenNextHasMovedOn() throws {
        let today = [FeedBuilder.agenda("Sync with Dana", start: at("15:00"), end: at("15:45"), url: meetURL, key: key,
                                        hermes: FeedBuilder.hermes("waiting_room"))]
        let later = FeedBuilder.meeting("Other", start: at("16:00"), url: meetURL, key: "other")
        let live = RecorderSnapshot(phase: .recording, sid: sid, title: "Sync with Dana", eventStart: at("15:00"), startedAt: at("15:00:26"),
                                    feed: FeedBuilder.feed(at: at("15:12"), next: later, today: today))
        let store = PanelStore(snapshot: live, actions: FakeRecorder(live), clock: { at("15:12:30") }, openURL: { _ in })
        #expect(store.liveHermes?.key == key)
        #expect(store.liveHermes.map { store.hermes($0).phase } == .waitingRoom)
    }

    @Test func anInPersonOrUnmatchedRecordingHasNoHermes() {
        let live = RecorderSnapshot(phase: .recording, sid: sid, kind: .inPerson, startedAt: at("15:00:26"),
                                    feed: FeedBuilder.feed(at: at("15:12"), next: next()))
        let store = PanelStore(snapshot: live, actions: FakeRecorder(live), clock: { at("15:12:30") }, openURL: { _ in })
        #expect(store.liveHermes == nil)
    }
}

struct HermesCopyTests {
    private func line(_ state: PanelHermes, now: String = "13:00") -> String {
        PanelCopy.hermesLine(state, start: at("15:00"), now: at(now), in: zone, locale: english).replacingOccurrences(of: "\u{202F}", with: " ")
    }

    @Test func theLineNamesWhenHermesJoinsOrWhereItStands() {
        #expect(line(PanelHermes(phase: .scheduled)) == "Hermes joins at 3:00 PM")
        #expect(line(PanelHermes(phase: .scheduled), now: "15:02") == "Hermes joins now")
        #expect(line(PanelHermes(phase: .joining)) == "Hermes is joining")
        #expect(line(PanelHermes(phase: .waitingRoom)) == "Hermes is waiting to be let in")
        #expect(line(PanelHermes(phase: .inCall)) == "Hermes is in the call")
        #expect(line(PanelHermes(phase: .failed, error: "Meet didn't let it in")) == "Hermes couldn't join: Meet didn't let it in")
        #expect(line(PanelHermes(phase: .failed)) == "Hermes couldn't join")
    }

    @Test func theChatHintAndStopWordFollowTheState() {
        #expect(PanelCopy.hermesChatHint(on: false) == "Off: Hermes listens and takes notes only.")
        #expect(PanelCopy.hermesChatHint(on: true) == "On: ask Hermes in the meeting chat and it texts you the answer.")
        #expect(PanelCopy.hermesStop(PanelHermes(phase: .inCall)) == "Remove")
        #expect(PanelCopy.hermesStop(PanelHermes(phase: .scheduled)) == "Cancel")
        #expect(PanelCopy.hermesStop(PanelHermes(phase: .waitingRoom)) == "Cancel")
    }

    @Test func onlyMeetLinksQualify() {
        #expect(PanelLinks.isMeet("https://meet.google.com/abc-defg-hij"))
        #expect(!PanelLinks.isMeet("https://us02web.zoom.us/j/1"))
        #expect(!PanelLinks.isMeet("https://teams.microsoft.com/l/meetup-join/x"))
        #expect(!PanelLinks.isMeet(nil))
    }
}
