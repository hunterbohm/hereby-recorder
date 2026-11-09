import Foundation
import Testing
import LMLCore
import LMLPanel
import LMLPanelFakes

let zone = TimeZone(identifier: "America/Chicago")!
let english = Locale(identifier: "en_US")

func at(_ clock: String) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let parts = clock.split(separator: ":").compactMap { Int($0) }
    return calendar.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: parts[0], minute: parts[1],
                                              second: parts.count > 2 ? parts[2] : 0))!
}
let sid = "20261023-150026-440d"
let zoomURL = "https://us02web.zoom.us/j/8812345678"
let noteURL = "obsidian://open?vault=vault&file=Meetings%2FSync"

func line(_ speaker: String, _ text: String) -> TranscriptLine { TranscriptLine(speaker: speaker, text: text, at: at("15:10")) }

func meeting(start: String, end: String? = "15:45", url: String? = zoomURL, brief: [String] = []) -> FeedBuilder.Object {
    FeedBuilder.meeting("Sync with Dana", start: at(start), end: end.map(at), url: url, brief: brief)
}

func filedRow(_ id: String = sid, ended: String = "16:47:40", state: FilingState = .filed) -> FeedBuilder.Object {
    FeedBuilder.recent(id, "Sync with Dana", endedAt: at(ended), state: state, note: "in your vault and the Orchard folder",
                       noteURL: noteURL, review: (true, 6))
}

func idle(feedAt: String, next: FeedBuilder.Object? = nil, recent: [FeedBuilder.Object] = []) -> RecorderSnapshot {
    RecorderSnapshot(feed: FeedBuilder.feed(at: at(feedAt), next: next, recent: recent))
}

struct ScreenTests {
    @Test func recordingShowsTheWholeConversationInTimeOrderWithMarksAndWarningsInline() throws {
        let lines = (0..<450).map { TranscriptLine(speaker: $0.isMultiple(of: 2) ? "me" : "them", text: "line \($0)",
                                                   at: at("15:00:26").addingTimeInterval(Double($0))) }
        let feed = FeedBuilder.feed(at: at("15:12"), next: meeting(start: "15:00"),
                                    live: FeedBuilder.live(sid, warnings: [(at("15:00:26").addingTimeInterval(448.5), "You said Friday last time.")]))
        let snapshot = RecorderSnapshot(phase: .recording, sid: sid, title: "Sync with Dana", eventStart: at("15:00"),
                                        startedAt: at("15:00:26"), lines: Array(lines.suffix(400)), marks: 1,
                                        markTimes: [at("15:00:26").addingTimeInterval(448)], feed: feed, themName: "Dana")
        guard case .recording(let content) = PanelScreen.resolve(snapshot, now: at("15:12:30")) else {
            Issue.record("expected recording"); return
        }
        let texts = content.items.map { item -> String in
            switch item {
            case .line(let line): line.text
            case .mark: "mark"
            case .warning(let warning): "warning \(warning.n)"
            case .ask(let entry): "ask \(entry.question)"
            }
        }
        #expect(texts.count == 402)
        #expect(texts.first == "line 50")
        #expect(texts.suffix(4) == ["line 448", "mark", "warning 1", "line 449"])
        #expect(content.title == "Sync with Dana")
        #expect(["them", "me", "room"].map { PanelText.speaker($0, them: content.themName) } == ["Dana", "You", "Room"])
        #expect(PanelText.speaker("them") == "Them")
        #expect(PanelText.liveDetail(content) == "Zoom · 1 marked")
        #expect(PanelText.stamp(at("15:12:30"), since: content.startedAt, in: zone, locale: english) == "12:04")
    }

    @Test func warningsForAnotherSessionStayOut() {
        let feed = FeedBuilder.feed(at: at("15:12"), live: FeedBuilder.live("20261023-090000-0000", warnings: [(at("15:05"), "Old")]))
        let snapshot = RecorderSnapshot(phase: .recording, sid: sid, startedAt: at("15:00"), lines: [line("me", "hi")], feed: feed)
        guard case .recording(let content) = PanelScreen.resolve(snapshot, now: at("15:12")) else {
            Issue.record("expected recording"); return
        }
        #expect(content.items == [.line(line("me", "hi"))])
    }

    @Test func untitledInPersonRecordingSaysSo() {
        let snapshot = RecorderSnapshot(phase: .recording, sid: sid, kind: .inPerson, startedAt: at("15:00"))
        guard case .recording(let content) = PanelScreen.resolve(snapshot, now: at("15:01")) else {
            Issue.record("expected recording"); return
        }
        #expect(content.title == "In-person meeting")
        #expect(PanelText.liveDetail(content) == "In person · mic only")
        #expect(content.items.isEmpty)
    }

    @Test func pausedPhaseShowsPaused() {
        let snapshot = RecorderSnapshot(phase: .paused, sid: sid, title: "Sync with Dana")
        guard case .paused(let content) = PanelScreen.resolve(snapshot, now: at("15:12")) else {
            Issue.record("expected paused"); return
        }
        #expect(content.sid == sid)
    }

    @Test func meetingWithinFifteenMinutesShowsBeforeWithJoinLinkBriefAndWhatIsOwed() throws {
        var next = meeting(start: "15:00", brief: ["a", "b", "c", "d"])
        next["owed"] = ["Send the SOP list", "Share the onboarding doc draft"]
        next["with"] = "Dana"
        let snapshot = idle(feedAt: "14:55", next: next)
        guard case .before(let content) = PanelScreen.resolve(snapshot, now: at("14:56")) else {
            Issue.record("expected before"); return
        }
        #expect(content.platform == "Zoom")
        #expect(content.joinURL == URL(string: zoomURL))
        #expect(content.brief == ["a", "b", "c"])
        #expect(content.owed == ["Send the SOP list", "Share the onboarding doc draft"])
        #expect(content.owedLabel == "You owe Dana")
        guard case .before(let group) = PanelScreen.resolve(idle(feedAt: "14:55", next: meeting(start: "15:00")), now: at("14:56")) else {
            Issue.record("expected before"); return
        }
        #expect(group.owedLabel == "You owe them")
        #expect(PanelText.startsIn(content.meeting.start, now: at("14:56")) == "Starts in 4 min")
    }

    @Test func beforeWindowOpensAtFifteenMinutesAndClosesAtTheEnd() {
        let snapshot = idle(feedAt: "14:40", next: meeting(start: "15:00", end: "15:45"))
        #expect(isIdle(PanelScreen.resolve(snapshot, now: at("14:44"))))
        #expect(isBefore(PanelScreen.resolve(snapshot, now: at("14:45"))))
        #expect(isBefore(PanelScreen.resolve(snapshot, now: at("15:44"))))
        #expect(isIdle(PanelScreen.resolve(snapshot, now: at("15:45"))))
        #expect(PanelText.startsIn(at("15:00"), now: at("15:30")) == "Started 30 min ago")
    }

    @Test func meetingWithoutEndKeepsBeforeFifteenMinutesPastStart() {
        let snapshot = idle(feedAt: "14:40", next: meeting(start: "15:00", end: nil))
        #expect(isBefore(PanelScreen.resolve(snapshot, now: at("15:14"))))
        #expect(isIdle(PanelScreen.resolve(snapshot, now: at("15:15"))))
    }

    @Test func recentlyEndedCallShowsAfterForThirtyMinutes() {
        let snapshot = idle(feedAt: "16:50", recent: [filedRow()])
        guard case .after(let content) = PanelScreen.resolve(snapshot, now: at("16:52")) else {
            Issue.record("expected after"); return
        }
        #expect(content.state == .filed)
        #expect(content.noteURL == URL(string: noteURL))
        #expect(content.review.map(PanelText.review)?.line == "Review sent to your phone")
        #expect(content.review.map(PanelText.review)?.detail == "6 tasks to approve")
        #expect(PanelText.review(PanelReview(sent: true, tasks: 6, answered: true)).line == "Review answered")
        #expect(content.pinned == false)
        #expect(isIdle(PanelScreen.resolve(snapshot, now: at("17:17:40"))))
    }

    @Test func filedCallShowsItsSummaryAndMarkedMomentsTimedFromTheStart() throws {
        let row = FeedBuilder.recent(sid, "Sync with Dana", endedAt: at("15:48"), state: .filed, durationS: 2880,
                                     summary: ["one", "two", "three", "four"],
                                     moments: [(at("15:11:59"), "yes, once the Klaviyo skill is in")])
        guard case .after(let content) = PanelScreen.resolve(idle(feedAt: "15:49", recent: [row]), now: at("15:50")) else {
            Issue.record("expected after"); return
        }
        #expect(content.summary == ["one", "two", "three"])
        let moment = try #require(content.moments?.first)
        #expect(PanelText.stamp(moment.at, since: content.startedAt, in: zone, locale: english) == "11:59")
        #expect(PanelText.afterFacts(content, in: zone, locale: english) == "48 min · ended 3:48\u{202F}PM")
    }

    @Test func upcomingMeetingWinsOverJustEndedCallAndKeepsItAsLastCall() {
        let snapshot = idle(feedAt: "16:50", next: meeting(start: "17:00", end: "17:30"), recent: [filedRow()])
        guard case .before(let content) = PanelScreen.resolve(snapshot, now: at("16:52")) else {
            Issue.record("expected before"); return
        }
        #expect(content.lastCall?.sid == sid)
    }

    @Test func callEndedLocallyBeforeTheMiniKnowsShowsWaiting() {
        let snapshot = RecorderSnapshot(phase: .ended, sid: sid, title: "Sync with Dana", startedAt: at("15:00:26"), marks: 3,
                                        feed: FeedBuilder.feed(at: at("16:40")))
        guard case .after(let content) = PanelScreen.resolve(snapshot, now: at("16:48")) else {
            Issue.record("expected after"); return
        }
        #expect(content.state == .waiting)
        #expect(content.title == "Sync with Dana")
        #expect(content.marks == 3)
        #expect(content.heldUntil == nil)
    }

    @Test func aCallHeldInCaseItComesBackSaysWhenItFiles() {
        var snapshot = RecorderSnapshot(phase: .ended, sid: sid, title: "Sync with Dana", startedAt: at("15:00:26"),
                                        feed: FeedBuilder.feed(at: at("16:40")))
        snapshot.heldUntil = at("16:53")
        guard case .after(let content) = PanelScreen.resolve(snapshot, now: at("16:48")) else {
            Issue.record("expected after"); return
        }
        #expect(content.state == .waiting)
        #expect(content.heldUntil == at("16:53"))
    }

    @Test func endedCallCombinesTheFeedRowWithLocalDurationAndMarks() {
        let snapshot = RecorderSnapshot(phase: .ended, sid: sid, title: "Sync with Dana", startedAt: at("15:00:26"), marks: 2,
                                        feed: FeedBuilder.feed(at: at("16:50"), recent: [filedRow()]))
        guard case .after(let content) = PanelScreen.resolve(snapshot, now: at("16:52")) else {
            Issue.record("expected after"); return
        }
        #expect(PanelText.afterFacts(content, in: zone, locale: english) == "1 h 47 min · ended 4:47\u{202F}PM")
        #expect(content.marks == 2)
        #expect(content.note == "in your vault and the Orchard folder")
    }

    @Test func selectingARecentRowShowsItsDetails() {
        let other = "20261022-160000-3c4d"
        let snapshot = idle(feedAt: "17:29", recent: [filedRow(), filedRow(other, ended: "09:00", state: .skipped)])
        guard case .after(let content) = PanelScreen.resolve(snapshot, now: at("17:30"), focus: .call(other, fromList: true)) else {
            Issue.record("expected after"); return
        }
        #expect(content.sid == other)
        #expect(content.pinned)
    }

    @Test func duringACallTheListAndPastCallsOpenFromItAndEverythingElseShowsTheCall() {
        let other = "20261022-160000-3c4d"
        var snapshot = idle(feedAt: "17:29", recent: [filedRow(other, ended: "09:00")])
        snapshot.phase = .recording
        snapshot.sid = sid
        #expect(isRecording(PanelScreen.resolve(snapshot, now: at("17:30"))))
        #expect(isIdle(PanelScreen.resolve(snapshot, now: at("17:30"), focus: .list)))
        guard case .after(let content) = PanelScreen.resolve(snapshot, now: at("17:30"), focus: .call(other, fromList: true)) else {
            Issue.record("expected after"); return
        }
        #expect(content.sid == other)
        #expect(content.pinned)
        #expect(isRecording(PanelScreen.resolve(snapshot, now: at("17:30"), focus: .call("20261001-090000-0000", fromList: true))),
                "a call the feed no longer lists falls back to the live call")
        snapshot.phase = .paused
        #expect(isIdle(PanelScreen.resolve(snapshot, now: at("17:30"), focus: .list)), "a paused call opens the list too")
    }

    @Test func noFeedYetIsConnecting() {
        guard case .idle(let content) = PanelScreen.resolve(RecorderSnapshot(), now: at("09:00")) else {
            Issue.record("expected idle"); return
        }
        #expect(content.connecting)
    }

    @Test func withoutAMiniTheIdleScreenNeverConnectsAndDeletesNameOnlyTheMac() {
        guard case .idle(let content) = PanelScreen.resolve(RecorderSnapshot(), now: at("09:00"), hasMini: false) else {
            Issue.record("expected idle"); return
        }
        #expect(!content.connecting)
        #expect(PanelCopy.confirmation(.forget(sid: "s"))?.detail == "Its transcript is deleted from this Mac and the mini.")
        #expect(PanelCopy.confirmation(.forget(sid: "s"), hasMini: false)?.detail == "Its transcript is deleted from this Mac.")
        #expect(PanelCopy.confirmation(.notAMeeting(sid: "s"), hasMini: false)?.detail == "Recording stops and this call's transcript is deleted from this Mac.")
    }

    @Test func idleListsNextMeetingAndTheFourNewestCalls() {
        let rows = (0..<6).map { filedRow("20261023-1\($0)0000-0000", ended: "1\($0):00") }
        let snapshot = idle(feedAt: "17:29", next: meeting(start: "19:00", end: "19:45"), recent: rows)
        guard case .idle(let content) = PanelScreen.resolve(snapshot, now: at("17:30")) else {
            Issue.record("expected idle"); return
        }
        #expect(content.next?.title == "Sync with Dana")
        #expect(content.recent.map(\.sid) == Array(rows.prefix(4)).map { $0["sid"] as! String })
        #expect(!content.connecting)
        #expect(PanelText.upcoming(at("19:00"), now: at("17:30"), in: zone, locale: english) == "7:00\u{202F}PM")
        #expect(PanelText.day(at("19:00"), now: at("17:30"), in: zone, locale: english) == "Today 7:00\u{202F}PM")
    }

    @Test func recentRowsSayWhenAndHowTheyFiled() {
        let now = at("17:30")
        #expect(PanelText.past(at("11:00"), now: now, in: zone, locale: english) == "11:00\u{202F}AM")
        #expect(PanelText.past(now.addingTimeInterval(-86400), now: now, in: zone, locale: english) == "Yesterday")
        #expect(PanelText.past(now.addingTimeInterval(-3 * 86400), now: now, in: zone, locale: english) == "Tue")
        #expect(PanelText.past(now.addingTimeInterval(-9 * 86400), now: now, in: zone, locale: english) == "Oct 14")
        let snapshot = idle(feedAt: "17:29", recent: [
            filedRow(), FeedBuilder.recent("20261022-090000-5e6f", "Standup", endedAt: at("09:12"), state: .skipped, note: "not a meeting"),
            FeedBuilder.recent("20261021-090000-5e6f", "Planning", endedAt: at("09:40"), state: .filed, review: (true, 3), answered: true),
            FeedBuilder.recent("20261020-090000-5e6f", "Retro", endedAt: at("09:50"), state: .filed, review: (false, 2))
        ])
        guard case .idle(let content) = PanelScreen.resolve(snapshot, now: now, focus: .list) else {
            Issue.record("expected idle"); return
        }
        #expect(content.recent.map(PanelText.filingTag) == ["Filed · 6 tasks to approve", "Skipped · Not a meeting", "Filed", "Filed · 2 tasks found"])
    }

    @Test func captureAccessOffReplacesOnlyTheIdleScreen() {
        var snapshot = idle(feedAt: "14:19", next: meeting(start: "15:00"))
        snapshot.audioOK = false
        guard case .access(let content) = PanelScreen.resolve(snapshot, now: at("14:20")) else {
            Issue.record("expected access"); return
        }
        let copy = PanelCopy.access(content, now: at("14:20"), in: zone, locale: english)
        #expect(copy.title == "Can't hear call audio")
        #expect(copy.next == "Sync with Dana is at 3:00\u{202F}PM. If this is still off 10 minutes before, you get a text.")
        #expect(copy.settingsURL?.absoluteString.hasSuffix("Privacy_ScreenCapture") == true)
        #expect(isIdle(PanelScreen.resolve(snapshot, now: at("14:20"), focus: .list)))
        #expect(isBefore(PanelScreen.resolve(snapshot, now: at("14:50"))))
        var ended = idle(feedAt: "14:19", recent: [filedRow(ended: "14:10")])
        ended.audioOK = false
        guard case .after = PanelScreen.resolve(ended, now: at("14:20")) else { Issue.record("expected after"); return }
        snapshot.phase = .recording
        #expect(isRecording(PanelScreen.resolve(snapshot, now: at("14:20"))))
        var noLink = idle(feedAt: "14:19", next: meeting(start: "15:00", url: nil))
        noLink.micOK = false
        guard case .access(let micOff) = PanelScreen.resolve(noLink, now: at("14:20")) else {
            Issue.record("expected access"); return
        }
        #expect(micOff.next == nil)
    }

    @Test func platformNamesComeFromTheCallLink() {
        let names = ["https://us02web.zoom.us/j/1", "https://meet.google.com/abc", "https://teams.microsoft.com/l/x",
                     "https://example.com/x", "https://notzoom.us/x"]
            .map { URL(string: $0).flatMap(PanelLinks.platform) }
        #expect(names == ["Zoom", "Google Meet", "Teams", nil, nil])
    }
}

func isIdle(_ screen: PanelScreen) -> Bool { if case .idle = screen { true } else { false } }
func isBefore(_ screen: PanelScreen) -> Bool { if case .before = screen { true } else { false } }
func isRecording(_ screen: PanelScreen) -> Bool { if case .recording = screen { true } else { false } }

struct IconTests {
    let healthy = Health(micOK: true, audioOK: true, miniReachable: true, lastContact: nil)

    @Test func phasesMapToTheirIcons() {
        let icons = [RecorderPhase.idle, .armed, .recording, .paused, .ended]
            .map { StatusIcon.resolve(RecorderSnapshot(phase: $0), health: healthy, flash: nil) }
        #expect(icons == [.idle, .armed, .recording, .paused, .idle])
    }

    @Test func lostMicOrAudioOutranksRecording() {
        let snapshot = RecorderSnapshot(phase: .recording, micOK: false, audioOK: true, feed: FeedBuilder.feed(at: at("15:00")))
        let health = Health.resolve(snapshot, now: at("15:01"), graceStart: at("09:00"))
        #expect(StatusIcon.resolve(snapshot, health: health, flash: nil) == .problem(health))
    }

    @Test func unreachableMiniFlagsIdleButKeepsTheRecordingIcon() {
        var snapshot = RecorderSnapshot(phase: .idle, feed: FeedBuilder.feed(at: at("15:00")))
        let stale = Health.resolve(snapshot, now: at("15:10:01"), graceStart: at("09:00"))
        #expect(!stale.miniReachable)
        #expect(Health.resolve(snapshot, now: at("15:10"), graceStart: at("09:00")).miniReachable)
        #expect(StatusIcon.resolve(snapshot, health: stale, flash: nil) == .problem(stale))
        snapshot.phase = .recording
        #expect(StatusIcon.resolve(snapshot, health: stale, flash: nil) == .recording)
    }

    @Test func noFeedIsAProblemOnlyAfterTheLaunchGrace() {
        #expect(Health.resolve(RecorderSnapshot(), now: at("09:02"), graceStart: at("09:00")).miniReachable)
        #expect(!Health.resolve(RecorderSnapshot(), now: at("09:02:01"), graceStart: at("09:00")).miniReachable)
    }

    @Test func withoutAMiniNoFeedIsEverAProblem() {
        let health = Health.resolve(RecorderSnapshot(), now: at("15:00"), graceStart: at("09:00"), hasMini: false)
        #expect(health.miniReachable)
        #expect(StatusIcon.resolve(RecorderSnapshot(), health: health, flash: nil) == .idle)
    }

    @Test func markConfirmationShowsEvenOverAProblem() {
        let broken = Health(micOK: false, audioOK: true, miniReachable: true, lastContact: nil)
        #expect(StatusIcon.resolve(RecorderSnapshot(phase: .recording), health: broken, flash: .marked) == .marked)
        #expect(StatusIcon.resolve(RecorderSnapshot(phase: .recording), health: healthy, flash: .filed) == .recording)
        #expect(StatusIcon.resolve(RecorderSnapshot(phase: .idle), health: healthy, flash: .filed) == .filed)
    }

    @Test func flashesExpire() {
        let flash = FlashState(kind: .marked, until: at("15:00:01"))
        #expect(flash.active(at: at("15:00")) == .marked)
        #expect(flash.active(at: at("15:00:01")) == nil)
    }

    @MainActor @Test func everyIconHasASymbolAndADistinctSpokenName() {
        let icons: [StatusIcon] = [.idle, .armed, .recording, .paused, .filed, .marked, .markMissed,
                                   .problem(Health(micOK: false, audioOK: true, miniReachable: true, lastContact: nil)),
                                   .problem(Health(micOK: true, audioOK: false, miniReachable: true, lastContact: nil)),
                                   .problem(Health(micOK: false, audioOK: false, miniReachable: true, lastContact: nil)),
                                   .problem(Health(micOK: true, audioOK: true, miniReachable: false, lastContact: nil))]
        #expect(icons.allSatisfy { $0.image() != nil })
        let names = icons.map(PanelCopy.accessibilityName)
        #expect(Set(names).count == icons.count)
        #expect(names[7] == "Meeting recorder needs attention, microphone access is off")
        #expect(names[10] == "Meeting recorder needs attention, can't reach the mini")
    }
}
