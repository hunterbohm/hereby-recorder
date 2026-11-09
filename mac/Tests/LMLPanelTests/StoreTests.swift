import Foundation
import Testing
import LMLCore
import LMLPanel
import LMLPanelFakes

@MainActor
final class Harness {
    var now: Date
    var opened: [URL] = []
    let recorder: FakeRecorder
    var store: PanelStore!

    init(_ snapshot: RecorderSnapshot, now: Date, actionTimeout: Duration = .seconds(30)) {
        self.now = now
        recorder = FakeRecorder(snapshot)
        store = PanelStore(snapshot: snapshot, actions: recorder, clock: { [unowned self] in self.now },
                           actionTimeout: actionTimeout, openURL: { [unowned self] in self.opened.append($0) })
    }

    func waitForCall() async {
        while recorder.calls.isEmpty { await Task.yield() }
    }
}

func recording(feedAt: String = "15:12") -> RecorderSnapshot {
    RecorderSnapshot(phase: .recording, sid: sid, title: "Sync with Dana", eventStart: at("15:00"), startedAt: at("15:00:26"),
                     feed: FeedBuilder.feed(at: at(feedAt)))
}

@MainActor
func conversation(_ store: PanelStore) -> [String] {
    let content: LiveContent
    switch store.screen {
    case .recording(let live), .paused(let live): content = live
    case .idle, .before, .after, .access: return []
    }
    return content.items.map { item in
        switch item {
        case .line(let line): line.text
        case .mark: "mark"
        case .warning(let warning): "warning \(warning.n) \(warning.text)"
        case .ask(let entry):
            switch entry.status {
            case .waiting: "ask \(entry.question) = waiting"
            case .streaming(let partial): "ask \(entry.question) = streaming \(partial)"
            case .answered(let answer): "ask \(entry.question) = \(answer)"
            case .failed: "ask \(entry.question) = failed"
            }
        }
    }
}

@MainActor
struct StoreActionTests {
    @Test func plainActionsCallTheRecorderOnceEach() async {
        let h = Harness(recording(), now: at("15:12:30"))
        await h.store.perform(.pause)
        await h.store.perform(.resume)
        await h.store.perform(.stop)
        await h.store.perform(.startInPerson)
        #expect(h.recorder.calls == [.pause, .resume, .stop, .startInPerson])
        #expect(h.store.action == .idle)
    }

    @Test func notAMeetingAsksFirstAndForgetsTheLiveSessionOnConfirm() async {
        let h = Harness(recording(), now: at("15:12:30"))
        await h.store.perform(.notAMeeting(sid: sid))
        #expect(h.recorder.calls.isEmpty)
        #expect(h.store.action == .confirming(.notAMeeting(sid: sid)))
        h.store.cancel()
        #expect(h.store.action == .idle)
        #expect(h.recorder.calls.isEmpty)
        await h.store.perform(.notAMeeting(sid: sid))
        await h.store.confirm()
        #expect(h.recorder.calls == [.forget(sid)])
    }

    @Test func forgetFromTheAfterCardForgetsThatSession() async {
        let h = Harness(idle(feedAt: "16:50", recent: [filedRow()]), now: at("16:52"))
        guard case .after(let content) = h.store.screen else { Issue.record("expected after"); return }
        await h.store.perform(.forget(sid: content.sid))
        await h.store.confirm()
        #expect(h.recorder.calls == [.forget(sid)])
    }

    @Test func markMomentDuringARecordingMarksWithoutANoteAndConfirmsBriefly() async {
        let h = Harness(recording(), now: at("15:12:30"))
        await h.store.markMoment()
        #expect(h.recorder.calls == [.markMoment(nil)])
        #expect(h.store.icon == .marked)
        h.now = at("15:12:32")
        h.store.tick()
        #expect(h.store.icon == .recording)
    }

    @Test func markMomentOutsideARecordingCallsNothingAndSaysSo() async {
        let h = Harness(idle(feedAt: "17:00"), now: at("17:00:10"))
        await h.store.markMoment()
        #expect(h.recorder.calls.isEmpty)
        #expect(h.store.icon == .markMissed)
    }

    @Test func failedMarkSaysNotMarked() async {
        let h = Harness(recording(), now: at("15:12:30"))
        h.recorder.failCalls(true)
        await h.store.markMoment()
        #expect(h.store.icon == .markMissed)
    }

    @Test func failedActionShowsTheErrorAndARetryClearsIt() async {
        let h = Harness(recording(), now: at("15:12:30"))
        h.recorder.failCalls(true)
        await h.store.perform(.pause)
        #expect(h.store.action == .failed(.pause))
        #expect(PanelCopy.failure(.pause) == "Couldn't pause. Try again.")
        h.recorder.failCalls(false)
        await h.store.perform(.pause)
        #expect(h.recorder.calls == [.pause, .pause])
        #expect(h.store.action == .idle)
    }

    @Test func secondPressWhileAnActionRunsIsIgnored() async {
        let h = Harness(recording(), now: at("15:12:30"))
        h.recorder.hold()
        let first = Task { await h.store.perform(.stop) }
        await h.waitForCall()
        #expect(h.store.action == .running(.stop))
        await h.store.perform(.stop)
        await h.store.perform(.pause)
        #expect(h.recorder.calls == [.stop])
        h.recorder.release()
        await first.value
        #expect(h.store.action == .idle)
    }

    @Test func askSendsTheTrimmedQuestionAndTheAnswerJoinsTheConversationWhereItWasAsked() async {
        var snapshot = recording()
        snapshot.lines = [line("them", "Poland?")]
        let h = Harness(snapshot, now: at("15:12:30"))
        h.recorder.answer(with: "  He wants the folder map tonight.\n")
        h.store.askDraft = "  What did Dana say about Poland?  "
        await h.store.submitAsk()
        #expect(h.recorder.calls == [.askLive(.ask, "What did Dana say about Poland?")], "the fast answer is tried first")
        #expect(h.store.askDraft.isEmpty)
        snapshot.lines.append(TranscriptLine(speaker: "me", text: "Later", at: at("15:13")))
        h.store.update(snapshot)
        #expect(conversation(h.store) == ["Poland?", "ask What did Dana say about Poland? = He wants the folder map tonight.", "Later"])
    }

    @Test func askShowsThinkingThenAnErrorAndTryAgainAsksOnce() async {
        let h = Harness(recording(), now: at("15:12:30"))
        h.recorder.hold()
        h.recorder.failCalls(true)
        let pending = Task { await h.store.submitAsk("Anything I owe him?") }
        await h.waitForCall()
        #expect(conversation(h.store) == ["ask Anything I owe him? = waiting"])
        #expect(h.store.isAsking)
        await h.store.submitAsk("A second question")
        h.recorder.release()
        await pending.value
        #expect(conversation(h.store) == ["ask Anything I owe him? = failed"])
        h.recorder.failCalls(false)
        guard case .recording(let content) = h.store.screen, case .ask(let failed)? = content.items.first else {
            Issue.record("no ask"); return
        }
        await h.store.retryAsk(failed.id)
        #expect(h.recorder.calls == [.askLive(.ask, "Anything I owe him?"), .ask("Anything I owe him?"),
                                     .askLive(.ask, "Anything I owe him?")], "the retry's fast answer works, so Hermes is not asked")
        #expect(conversation(h.store).count == 1)
    }

    @Test func emptyAnswerCountsAsNoAnswer() async {
        let h = Harness(recording(), now: at("15:12:30"))
        h.recorder.answer(with: " \n")
        await h.store.submitAsk("Anything?")
        #expect(conversation(h.store) == ["ask Anything? = failed"])
    }

    @Test func blankQuestionIsNotSent() async {
        let h = Harness(recording(), now: at("15:12:30"))
        h.store.askDraft = "   "
        await h.store.submitAsk()
        #expect(h.recorder.calls.isEmpty)
        #expect(conversation(h.store).isEmpty)
    }

    @Test func aNewSessionStartsWithNoQuestionsAndDropsALateAnswer() async {
        let h = Harness(recording(), now: at("15:12:30"))
        await h.store.submitAsk("Anything?")
        h.recorder.hold()
        let pending = Task { await h.store.submitAsk("Late?") }
        while h.recorder.calls.count < 2 { await Task.yield() }
        var next = recording()
        next.sid = "20261023-170000-0001"
        h.store.askDraft = "half typed"
        h.store.update(next)
        h.recorder.release()
        await pending.value
        #expect(conversation(h.store).isEmpty)
        #expect(h.store.askDraft.isEmpty)
    }

    @Test func aNewRecordingAfterAPauseShowsOnlyItsOwnConversation() {
        var first = recording()
        first.lines = [line("them", "before the pause")]
        let h = Harness(first, now: at("15:12:04"))
        h.store.update(RecorderSnapshot(phase: .paused, feed: first.feed))
        var second = recording()
        second.sid = "20261023-151500-0002"
        second.lines = [TranscriptLine(speaker: "me", text: "after resuming", at: at("15:15:10"))]
        h.store.update(second)
        guard case .recording(let content) = h.store.screen else { Issue.record("expected recording"); return }
        #expect(content.stoppedAt == nil)
        #expect(conversation(h.store) == ["after resuming"])
        h.store.update(RecorderSnapshot(phase: .paused, feed: first.feed))
        #expect(conversation(h.store) == ["after resuming"])
    }

    @Test func askAboutAnyMeetingUsesTheAnyCommandAndKeepsOnlyTheLatestAnswer() async {
        let h = Harness(idle(feedAt: "13:39"), now: at("13:40"))
        h.recorder.answerAny(with: "Two open for Dana.")
        h.store.anyDraft = " What do I owe Dana? "
        await h.store.submitAnyAsk()
        #expect(h.recorder.calls == [.askAny("What do I owe Dana?")])
        #expect(h.store.anyAsk?.status == .answered("Two open for Dana."))
        #expect(h.store.anyDraft.isEmpty)
        h.store.panelClosed()
        #expect(h.store.anyAsk == nil)
    }

    @Test func askAboutAnyMeetingShowsAFailureInsteadOfWaiting() async {
        let h = Harness(idle(feedAt: "13:39"), now: at("13:40"))
        h.recorder.failCalls(true)
        await h.store.submitAnyAsk("What did we decide about Poland?")
        #expect(h.store.anyAsk?.status == .failed)
        #expect(!h.store.isAskingAny)
    }

    @Test func aQuestionStillOutSurvivesClosingThePanel() async {
        let h = Harness(idle(feedAt: "13:39"), now: at("13:40"))
        h.recorder.hold()
        let pending = Task { await h.store.submitAnyAsk("Anything?") }
        await h.waitForCall()
        h.store.panelClosed()
        h.recorder.release()
        await pending.value
        #expect(h.store.anyAsk?.status == .answered("Last call with Dana covered the SOP library and Poland. You owe him 2 tasks."))
    }

    @Test func eachTextedWarningShowsOnceAtItsTimeEvenWhenALaterFeedDropsIt() {
        var snapshot = recording()
        snapshot.lines = [line("them", "first")]
        snapshot.feed = FeedBuilder.feed(at: at("15:11"), live: FeedBuilder.live(sid, warnings: [(at("15:10:30"), "You said Friday.")]))
        let h = Harness(snapshot, now: at("15:11"))
        h.store.update(snapshot)
        snapshot.feed = FeedBuilder.feed(at: at("15:12"))
        h.store.update(snapshot)
        #expect(conversation(h.store) == ["first", "warning 1 You said Friday."])
    }

    @Test func pausingKeepsTheConversationOnScreenWithTheTimerStopped() async {
        var snapshot = recording()
        snapshot.lines = [line("them", "before the pause")]
        snapshot.markTimes = [at("15:11")]
        let h = Harness(snapshot, now: at("15:12:04"))
        h.store.update(RecorderSnapshot(phase: .paused, feed: snapshot.feed))
        h.now = at("15:20")
        h.store.tick()
        guard case .paused(let content) = h.store.screen else { Issue.record("expected paused"); return }
        #expect(content.sid == sid)
        #expect(conversation(h.store) == ["before the pause", "mark"])
        #expect(content.stoppedAt == at("15:12:04"))
        await h.store.perform(.notAMeeting(sid: sid))
        await h.store.confirm()
        #expect(h.recorder.calls == [.forget(sid)])
        guard case .paused(let after) = h.store.screen else { Issue.record("expected paused"); return }
        #expect(after.sid == nil)
        #expect(after.items.isEmpty)
        #expect(after.title == "Recording paused")
        #expect(PanelText.liveDetail(after) == "Resumes 2 min after the call ends")
    }

    @Test func joinAndOpenNoteOpenTheLinksFromTheFeed() async {
        let h = Harness(idle(feedAt: "14:55", next: meeting(start: "15:00")), now: at("14:56"))
        guard case .before(let before) = h.store.screen, let join = before.joinURL else { Issue.record("expected join link"); return }
        h.store.open(join)
        h.store.update(idle(feedAt: "16:50", recent: [filedRow()]))
        h.now = at("16:52")
        h.store.tick()
        guard case .after(let after) = h.store.screen, let note = after.noteURL else { Issue.record("expected note link"); return }
        h.store.open(note)
        #expect(h.opened == [URL(string: zoomURL)!, URL(string: noteURL)!])
    }

    @Test func aCallThatJustFiledFlashesTheIcon() {
        let h = Harness(idle(feedAt: "16:49", recent: [filedRow(state: .filing)]), now: at("16:50"))
        #expect(h.store.icon == .idle)
        h.store.update(idle(feedAt: "16:50", recent: [filedRow(state: .filed)]))
        #expect(h.store.icon == .filed)
        h.now = at("16:50:11")
        h.store.tick()
        #expect(h.store.icon == .idle)
    }

    @Test func alreadyFiledCallsInTheFirstFeedDoNotFlash() {
        let h = Harness(RecorderSnapshot(), now: at("16:50"))
        h.store.update(idle(feedAt: "16:50", recent: [filedRow()]))
        #expect(h.store.icon == .idle)
    }

    @Test func closingThePanelDropsTheOpenedCallAndAConfirmation() async {
        let h = Harness(idle(feedAt: "17:29", recent: [filedRow()]), now: at("17:30"))
        h.store.navigate(.call(sid, fromList: true))
        await h.store.perform(.forget(sid: sid))
        h.store.panelClosed()
        #expect(h.store.focus == .auto)
        #expect(h.store.action == .idle)
        #expect(h.recorder.calls.isEmpty)
    }

    @Test func closingThePanelClearsAFailure() async {
        let h = Harness(recording(), now: at("15:12:30"))
        h.recorder.failCalls(true)
        await h.store.perform(.pause)
        h.store.panelClosed()
        #expect(h.store.action == .idle)
    }

    @Test func aConfirmationIsDroppedWhenItsCallLeavesTheScreen() async {
        let h = Harness(idle(feedAt: "16:50", recent: [filedRow()]), now: at("16:52"))
        await h.store.perform(.forget(sid: sid))
        #expect(h.store.action == .confirming(.forget(sid: sid)))
        let newer = "20261023-170000-0001"
        h.store.update(idle(feedAt: "17:20", recent: [filedRow(newer, ended: "17:15"), filedRow()]))
        #expect(h.store.action == .idle)
        await h.store.confirm()
        #expect(h.recorder.calls.isEmpty)
    }

    @Test func aConfirmationIsDroppedWhenTheAfterWindowCloses() async {
        let h = Harness(idle(feedAt: "16:50", recent: [filedRow()]), now: at("17:17"))
        await h.store.perform(.forget(sid: sid))
        h.now = at("17:18")
        h.store.tick()
        #expect(isIdle(h.store.screen))
        #expect(h.store.action == .idle)
    }

    @Test func aFailureAfterTheRecorderAlreadyMovedOnIsNotShown() async {
        let h = Harness(recording(), now: at("15:12:30"))
        h.recorder.hold()
        h.recorder.failCalls(true)
        let pending = Task { await h.store.perform(.stop) }
        await h.waitForCall()
        var ended = recording()
        ended.phase = .ended
        h.store.update(ended)
        h.recorder.release()
        await pending.value
        #expect(h.store.action == .idle)
    }

    @Test func aHungActionTimesOutAndItsLateResultIsIgnored() async throws {
        let h = Harness(recording(), now: at("15:12:30"), actionTimeout: .milliseconds(50))
        h.recorder.hold()
        let pending = Task { await h.store.perform(.stop) }
        await h.waitForCall()
        try await Task.sleep(for: .milliseconds(200))
        #expect(h.store.action == .failed(.stop))
        h.recorder.release()
        await pending.value
        #expect(h.store.action == .failed(.stop))
        await h.store.perform(.stop)
        #expect(h.recorder.calls == [.stop, .stop])
    }

    @Test func aForgottenCallLeavesThePanelAtOnce() async {
        let h = Harness(idle(feedAt: "16:50", recent: [filedRow()]), now: at("16:52"))
        await h.store.perform(.forget(sid: sid))
        await h.store.confirm()
        #expect(h.recorder.calls == [.forget(sid)])
        guard case .idle(let content) = h.store.screen else { Issue.record("expected idle"); return }
        #expect(content.recent.isEmpty)
    }

    @Test func forgettingAnOpenedCallReturnsToTheList() async {
        let other = "20261022-160000-3c4d"
        let h = Harness(idle(feedAt: "17:29", recent: [filedRow(), filedRow(other, ended: "09:00", state: .skipped)]), now: at("17:30"))
        h.store.navigate(.call(other, fromList: true))
        await h.store.perform(.forget(sid: other))
        await h.store.confirm()
        #expect(h.store.focus == .list)
        guard case .idle(let content) = h.store.screen else { Issue.record("expected the list"); return }
        #expect(content.recent.map(\.sid) == [sid])
    }

    @Test func lastCallRowOpensACallTheMiniHasNotReportedYet() {
        let snapshot = RecorderSnapshot(phase: .ended, sid: sid, title: "Sync with Dana", startedAt: at("15:00:26"), marks: 1,
                                        feed: FeedBuilder.feed(at: at("16:50"), next: meeting(start: "17:00", end: "17:30")))
        let h = Harness(snapshot, now: at("16:52"))
        guard case .before(let before) = h.store.screen, let last = before.lastCall else { Issue.record("expected last call"); return }
        h.store.navigate(.call(last.sid, fromList: false))
        guard case .after(let after) = h.store.screen else { Issue.record("expected after"); return }
        #expect(after.state == .waiting)
        #expect(after.pinned)
        h.store.back()
        #expect(isBefore(h.store.screen))
    }

    @Test func theAfterCardLinksToTheRecentList() {
        let h = Harness(idle(feedAt: "16:50", recent: [filedRow()]), now: at("16:52"))
        h.store.navigate(.list)
        #expect(isIdle(h.store.screen))
    }

    @Test func wakingFromSleepGivesTheHeartbeatTimeBeforeFlaggingTheMini() {
        let h = Harness(idle(feedAt: "08:00"), now: at("09:00"))
        h.now = at("09:03")
        h.store.tick()
        #expect(!h.store.health.miniReachable)
        h.store.resetGrace()
        #expect(h.store.health.miniReachable)
        h.now = at("09:05:01")
        h.store.tick()
        #expect(!h.store.health.miniReachable)
    }

}

@MainActor
struct LiveAskTests {
    @Test func theAnswerShowsWhileItArrivesThenSettles() async {
        let h = Harness(recording(), now: at("15:12:30"))
        h.recorder.answer(with: "Send the SOP list tonight.")
        h.recorder.hold()
        let pending = Task { await h.store.submitAsk("What next?") }
        await h.waitForCall()
        for _ in 0..<50 { await Task.yield() }
        #expect(conversation(h.store) == ["ask What next? = streaming Send the SOP list tonight."])
        #expect(h.store.isAsking, "a streaming answer still blocks a second question")
        h.recorder.release()
        await pending.value
        for _ in 0..<50 { await Task.yield() }
        #expect(conversation(h.store) == ["ask What next? = Send the SOP list tonight."], "a late piece never replaces the final answer")
    }

    @Test func aFastAnswerThatFailsBeforeAnyTextFallsBackToHermes() async {
        let h = Harness(recording(), now: at("15:12:30"))
        h.recorder.failLive(true)
        h.recorder.answer(with: "From Hermes.")
        await h.store.submitAsk("Budget?")
        #expect(h.recorder.calls == [.askLive(.ask, "Budget?"), .ask("Budget?")])
        #expect(conversation(h.store) == ["ask Budget? = From Hermes."])
    }

    @Test func readScreenWithoutAPictureShowsTheScreenRecordingHintAndSkipsHermes() async {
        let h = Harness(recording(), now: at("15:12:30"))
        h.recorder.failLive(with: RecorderError(reply: "no_screen"))
        await h.store.quickAsk(.screen)
        #expect(h.recorder.calls == [.askLive(.screen, PanelCopy.quickQuestion(.screen))])
        #expect(conversation(h.store) == ["ask \(PanelCopy.quickQuestion(.screen)) = \(PanelCopy.noScreen)"])
    }

    @Test func readScreenThatFailsOtherwiseOffersRetryNotAHermesGuess() async {
        let h = Harness(recording(), now: at("15:12:30"))
        h.recorder.failLive(true)
        await h.store.quickAsk(.screen)
        #expect(h.recorder.calls == [.askLive(.screen, PanelCopy.quickQuestion(.screen))])
        #expect(conversation(h.store) == ["ask \(PanelCopy.quickQuestion(.screen)) = failed"])
    }

    @Test func aFastAnswerCutOffKeepsWhatArrivedWithoutAskingAgain() async {
        let h = Harness(recording(), now: at("15:12:30"))
        h.recorder.answer(with: "one two three four")
        h.recorder.cutLiveOff(true)
        await h.store.submitAsk("Count?")
        for _ in 0..<50 { await Task.yield() }
        #expect(h.recorder.calls == [.askLive(.ask, "Count?")])
        #expect(conversation(h.store) == ["ask Count? = one two …"])
    }

    @Test func aButtonSendsItsKindTheRecentLinesAndShowsItsQuestion() async {
        var snapshot = recording()
        snapshot.lines = (0..<50).map { TranscriptLine(speaker: "them", text: "line \($0)", at: at("15:10").addingTimeInterval(Double($0))) }
        let h = Harness(snapshot, now: at("15:12:30"))
        await h.store.quickAsk(.say)
        #expect(h.recorder.calls == [.askLive(.say, PanelCopy.quickQuestion(.say))])
        guard case .recording(let content) = h.store.screen, case .ask(let entry)? = content.items.last else {
            Issue.record("no ask"); return
        }
        #expect(entry.kind == .say && entry.question == "What should I say next?")
        #expect(h.recorder.lastLiveRequest?.sid == sid, "the mini can tell this call from the one before")
        #expect(h.recorder.lastLiveRequest?.lines.count == ControlActions.liveLines)
    }

    @Test func noButtonWorksWhileNothingIsLive() async {
        let h = Harness(RecorderSnapshot(feed: FeedBuilder.feed(at: at("15:12"))), now: at("15:12:30"))
        await h.store.quickAsk(.recap)
        #expect(h.recorder.calls.isEmpty)
    }
}

@MainActor
struct OverlayStateTests {
    @Test func theOverlayShowsOnlyDuringALiveOrPausedCall() {
        let h = Harness(RecorderSnapshot(feed: FeedBuilder.feed(at: at("15:12"))), now: at("15:12:30"))
        #expect(!h.store.overlayVisible)
        h.store.update(recording())
        #expect(h.store.overlayVisible)
        h.store.update(RecorderSnapshot(phase: .paused, feed: recording().feed))
        #expect(h.store.overlayVisible, "a paused call keeps its overlay")
        h.store.update(RecorderSnapshot(phase: .ended, sid: sid, feed: recording().feed))
        #expect(!h.store.overlayVisible)
    }

    @Test func aCallForgottenOutsideThePanelLeavesTheScreenAndTheOverlay() {
        var live = recording()
        live.lines = [line("them", "private words")]
        let h = Harness(live, now: at("15:12:30"))
        #expect(h.store.overlayVisible)
        h.store.update(RecorderSnapshot(phase: .paused, feed: live.feed, forgottenSid: sid))
        #expect(!h.store.overlayVisible, "a forget from the command line or the mini hides the overlay")
        #expect(conversation(h.store).isEmpty, "the forgotten call's lines are not kept as the paused frame")
    }

    @Test func hidingLastsForTheSessionAndANewCallShowsItAgain() {
        let h = Harness(recording(), now: at("15:12:30"))
        h.store.toggleOverlay()
        #expect(!h.store.overlayVisible)
        h.store.update(recording())
        #expect(!h.store.overlayVisible, "a new snapshot of the same call keeps it hidden")
        var next = recording()
        next.sid = "20261023-170000-0001"
        h.store.update(next)
        #expect(h.store.overlayVisible)
        h.store.toggleOverlay(); h.store.toggleOverlay()
        #expect(h.store.overlayVisible, "the shortcut shows it again")
    }
}

@MainActor
struct BrowseDuringACallTests {
    @Test func theListOpensFromACallWithTheCallOnTopAndTheOverlayKept() {
        let h = Harness(recording(), now: at("15:12:30"))
        h.store.navigate(.list)
        #expect(isIdle(h.store.screen))
        #expect(h.store.live?.content.sid == sid, "the list keeps the call on top")
        #expect(h.store.overlayVisible, "browsing the list does not hide the overlay")
        h.store.update(recording())
        #expect(isIdle(h.store.screen), "a new snapshot of the same call keeps the list open")
        h.store.navigate(.auto)
        #expect(isRecording(h.store.screen))
    }

    @Test func askAboutAnyMeetingWorksDuringACall() async {
        let h = Harness(recording(), now: at("15:12:30"))
        h.store.navigate(.list)
        h.recorder.answerAny(with: "Last Tuesday.")
        await h.store.submitAnyAsk("When did we last talk to Dana?")
        #expect(h.recorder.calls == [.askAny("When did we last talk to Dana?")])
        #expect(h.store.anyAsk?.status == .answered("Last Tuesday."))
    }

    @Test func aRecordingThatStartsTakesThePanelFromTheList() {
        let h = Harness(idle(feedAt: "15:12"), now: at("15:12:30"))
        h.store.navigate(.list)
        h.store.update(recording())
        #expect(isRecording(h.store.screen))
    }

    @Test func aHeldCallThatComesBackKeepsItsQuestionsAndTakesThePanel() async {
        let h = Harness(recording(), now: at("15:12:30"))
        await h.store.submitAsk("Anything?")
        #expect(conversation(h.store).count == 1)
        var held = RecorderSnapshot(phase: .ended, sid: sid, feed: recording().feed)
        held.heldUntil = at("15:18")
        h.store.update(held)
        h.store.navigate(.list)
        h.store.update(recording())
        #expect(isRecording(h.store.screen))
        #expect(conversation(h.store).count == 1, "the question asked before the call dropped is still there")
    }
}
