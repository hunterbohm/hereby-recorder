import Foundation
import LMLCore
import LMLPanel

@MainActor final class Clock {
    var now: Date
    init(_ now: Date) { self.now = now }
}

public struct PanelScenario {
    public let name: String
    public let recorder: FakeRecorder
    public let store: PanelStore
}

@MainActor
public enum PanelScenarios {
    nonisolated public static let zone = TimeZone(identifier: "America/Chicago")!
    nonisolated public static let locale = Locale(identifier: "en_US")

    nonisolated public static func time(_ clock: String, day: Int = 26) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = clock.split(separator: ":").compactMap { Int($0) }
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: parts[0], minute: parts[1],
                                                  second: parts.count > 2 ? parts[2] : 0))!
    }

    public static func makeStore(_ snapshot: RecorderSnapshot, now: Date) -> (FakeRecorder, PanelStore) {
        let fake = FakeRecorder(snapshot)
        let store = PanelStore(snapshot: snapshot, actions: fake, clock: { now }, openURL: { _ in })
        store.timeZone = zone
        store.locale = locale
        return (fake, store)
    }

    static let maxSid = "20261026-150000-440d"
    static let title = "Weekly Sync with Dana"
    static let zoomURL = "https://us02web.zoom.us/j/8812345678"
    static let noteURL = "obsidian://open?vault=vault&file=Meetings%2F2026-10-26%20Weekly%20Sync%20with%20Rae"
    static let start = time("15:00")
    static let script: [(String, String)] = [
        ("me", "okay, where did we land on the SOP library?"),
        ("them", "most of it is written, the last few are in review"),
        ("them", "so the library goes live Friday?"),
        ("me", "yes, once the Klaviyo skill is in"),
        ("them", "and Poland, did we decide?"),
        ("me", "not yet, we wait for next week's numbers"),
        ("them", "okay. can you send me the SOP list after this?"),
        ("me", "yes, tonight"),
        ("them", "perfect. anything else from your side?"),
        ("me", "just the onboarding doc, that one is Monday"),
        ("them", "works for me"),
        ("me", "I'll share the draft before then"),
        ("them", "great, and loop me in on the numbers"),
        ("me", "will do")
    ]
    static let brief = ["Last call: SOP library, Poland decision", "You owe Dana: 2 open tasks"]
    static let owed = ["Send the SOP list", "Share the onboarding doc draft"]
    static let summary = ["Library goes live Friday, once the Klaviyo skill is in", "Poland waits for next week's numbers",
                          "You send Dana the SOP list tonight"]
    static let warnings = ["Last call you told Dana the onboarding doc would be ready today, not Monday.",
                           "Dana asked for the SOP list on the last call too."]

    static func at(_ elapsed: TimeInterval) -> Date { start.addingTimeInterval(elapsed) }
    static func line(_ index: Int, _ elapsed: TimeInterval) -> TranscriptLine {
        let (speaker, text) = script[index % script.count]
        return TranscriptLine(speaker: speaker, text: text, at: at(elapsed))
    }
    static let callLines = [line(0, 641), line(1, 662), line(2, 700), line(3, 718), line(4, 725)]
    static let upNext = FeedBuilder.meeting(title, start: start, end: time("15:45"), url: zoomURL, brief: brief, owed: owed, with: "Dana")

    static let meetURL = "https://meet.google.com/kqz-rtmv-hxd"
    static let meetKey = "5n3k0f2h8q1c7d9e_20261026T200000Z"

    /// The next call as a Google Meet event the mini sent a key for, with Hermes in the given state.
    static func meetNext(_ hermes: FeedBuilder.Object? = nil) -> FeedBuilder.Object {
        FeedBuilder.meeting(title, start: start, end: time("15:45"), url: meetURL, brief: [brief[0]], owed: owed, with: "Dana",
                            key: meetKey, hermes: hermes ?? FeedBuilder.hermes("off"))
    }

    /// The rest of today, each Meet event with its own key and Hermes state.
    static func meetToday(_ hermes: [String: FeedBuilder.Object] = [:]) -> [FeedBuilder.Object] {
        func state(_ key: String) -> FeedBuilder.Object { hermes[key] ?? FeedBuilder.hermes("off") }
        return [FeedBuilder.agenda("Design review", start: time("14:00"), end: time("14:30"), url: "https://meet.google.com/abc-defg-hij",
                                   key: "design-review", hermes: state("design-review")),
                FeedBuilder.agenda(title, start: start, end: time("15:45"), url: meetURL, key: meetKey, hermes: state(meetKey)),
                FeedBuilder.agenda("Intro with Larkspur", start: time("17:30"), end: time("18:00"), url: "https://zoom.us/j/5512345678",
                                   key: "larkspur", hermes: state("larkspur")),
                FeedBuilder.agenda("Pipeline review", start: time("18:00"), end: time("18:30"), url: "https://meet.google.com/lmn-opqr-stu",
                                   key: "pipeline", hermes: state("pipeline"))]
    }

    static func hermesHome(now: Date = time("13:40"), next: FeedBuilder.Object, today: [FeedBuilder.Object]) -> RecorderSnapshot {
        RecorderSnapshot(feed: FeedBuilder.feed(at: now.addingTimeInterval(-30), next: next, today: today, recent: Array(recentRows(now: now).prefix(2))))
    }

    static func recentRows(now: Date) -> [FeedBuilder.Object] {
        [
            FeedBuilder.recent("20261026-110000-1a2b", "Client check-in", endedAt: time("11:32"), state: .filed,
                               note: "in your vault and the Larkspur folder", noteURL: "obsidian://open?vault=vault&file=a",
                               review: (true, 3), durationS: 1920, snippet: "Agreed next steps on the proposal"),
            FeedBuilder.recent("20261023-100000-3c4d", "Intro call", endedAt: time("10:41", day: 23), state: .filed,
                               note: "in your vault", noteURL: "obsidian://open?vault=vault&file=b", review: (true, 1),
                               durationS: 2460, snippet: "Scoped a first project"),
            FeedBuilder.recent("20261023-090000-5e6f", "Team standup", endedAt: time("09:12", day: 23), state: .skipped,
                               note: "not a meeting", durationS: 720),
            FeedBuilder.recent("20261022-160000-7a8b", "Weekly dashboard review", endedAt: time("16:40", day: 22), state: .failed,
                               durationS: 2400)
        ]
    }

    static func recording(now: Date, lines: [TranscriptLine] = callLines, marks: [Date] = [at(724)],
                          warnings: [(at: Date, text: String)] = [(at(724.5), PanelScenarios.warnings[0])],
                          kind: CaptureKind = .call, title: String? = PanelScenarios.title, micOK: Bool = true,
                          next: FeedBuilder.Object? = nil) -> RecorderSnapshot {
        let live = warnings.isEmpty ? nil : FeedBuilder.live(maxSid, warnings: warnings)
        return RecorderSnapshot(phase: .recording, sid: maxSid, kind: kind, title: title, eventStart: title == nil ? nil : start,
                                startedAt: start, lines: lines, marks: marks.count, markTimes: marks, micOK: micOK,
                                feed: FeedBuilder.feed(at: now.addingTimeInterval(-40), next: next ?? upNext, live: live),
                                themName: kind == .call && title == PanelScenarios.title ? "Dana" : nil)
    }

    static func after(_ state: FilingState, name: String? = nil, note: String? = nil, noteURL: String? = nil,
                      review: (sent: Bool, tasks: Int)? = nil, summary: [String]? = nil,
                      moments: [(at: Date, text: String)]? = nil) -> PanelScenario {
        let now = time("15:48"), end = time("15:47:48")
        var rows = recentRows(now: now)
        rows.insert(FeedBuilder.recent(maxSid, title, endedAt: end, state: state, note: note, noteURL: noteURL, review: review,
                                       durationS: 2868, snippet: summary?.first, summary: summary, moments: moments), at: 0)
        let snapshot = RecorderSnapshot(phase: .ended, sid: maxSid, title: title, eventStart: start, startedAt: start,
                                        marks: moments?.count ?? 1,
                                        feed: FeedBuilder.feed(at: now.addingTimeInterval(-20), recent: rows))
        let (fake, store) = makeStore(snapshot, now: now)
        return PanelScenario(name: name ?? "after-\(state.rawValue)", recorder: fake, store: store)
    }

    static func longConversation() -> [TranscriptLine] {
        (0..<RecorderSnapshot.lineLimit).map { line($0, 120 + Double($0) * 7) }
    }

    public static func all() async -> [PanelScenario] {
        var list: [PanelScenario] = []
        func add(_ name: String, _ snapshot: RecorderSnapshot, now: Date, _ prepare: (FakeRecorder, PanelStore) async -> Void = { _, _ in }) async {
            let (fake, store) = makeStore(snapshot, now: now)
            await prepare(fake, store)
            list.append(PanelScenario(name: name, recorder: fake, store: store))
        }

        let idleNow = time("13:40")
        let today = [FeedBuilder.agenda("Design review", start: time("13:00"), end: time("14:00"), url: "https://meet.google.com/abc-defg-hij"),
                     FeedBuilder.agenda(title, start: start, end: time("15:45"), url: zoomURL),
                     FeedBuilder.agenda("Focus block", start: time("16:00"), end: time("17:30"), meeting: false),
                     FeedBuilder.agenda("Intro with Larkspur", start: time("17:30"), end: time("18:00"), url: "https://zoom.us/j/5512345678")]
        let idleFeed = FeedBuilder.feed(at: idleNow.addingTimeInterval(-30), next: upNext, today: today, recent: recentRows(now: idleNow))
        await add("idle", RecorderSnapshot(feed: idleFeed), now: idleNow)
        await add("idle-connecting", RecorderSnapshot(), now: idleNow)
        await add("idle-empty", RecorderSnapshot(feed: FeedBuilder.feed(at: idleNow)), now: idleNow)
        let stale = RecorderSnapshot(feed: FeedBuilder.feed(at: idleNow.addingTimeInterval(-25 * 60), next: upNext,
                                                            recent: recentRows(now: idleNow)))
        let launch = Clock(idleNow.addingTimeInterval(-3 * 60))
        let unreachable = PanelStore(snapshot: stale, actions: FakeRecorder(stale), clock: { launch.now }, openURL: { _ in })
        unreachable.timeZone = zone
        unreachable.locale = locale
        launch.now = idleNow
        unreachable.tick()
        list.append(PanelScenario(name: "idle-mini-unreachable", recorder: FakeRecorder(stale), store: unreachable))
        await add("idle-start-failed", RecorderSnapshot(feed: idleFeed), now: idleNow) { fake, store in
            fake.failCalls(true)
            await store.perform(.startInPerson)
        }
        await add("ask-any-waiting", RecorderSnapshot(feed: idleFeed), now: idleNow) { fake, store in
            fake.hold()
            Task { await store.submitAnyAsk("What do I owe Dana?") }
            while fake.calls.isEmpty { await Task.yield() }
        }
        await add("ask-any-answered", RecorderSnapshot(feed: idleFeed), now: idleNow) { fake, store in
            fake.answerAny(with: "Two open for Dana: send the SOP list, and share the onboarding doc draft by Monday.")
            await store.submitAnyAsk("What do I owe Dana?")
        }
        await add("ask-any-failed", RecorderSnapshot(feed: idleFeed), now: idleNow) { fake, store in
            fake.failCalls(true)
            await store.submitAnyAsk("What did we decide about Poland?")
        }

        // Hermes: Meet calls the mini sent a key for. Off, scheduled, in the call with chat on, and failed.
        let hermesNow = time("13:40"), hermesLive = at(727)
        await add("hermes-off", hermesHome(next: meetNext(), today: meetToday()), now: hermesNow)
        await add("hermes-scheduled", hermesHome(next: meetNext(FeedBuilder.hermes("scheduled")),
                                                 today: meetToday([meetKey: FeedBuilder.hermes("scheduled"),
                                                                   "pipeline": FeedBuilder.hermes("scheduled", chat: true)])),
                  now: hermesNow)
        await add("hermes-scheduled-chat", hermesHome(next: meetNext(FeedBuilder.hermes("scheduled", chat: true)),
                                                      today: meetToday()), now: hermesNow)
        await add("hermes-waiting-room", hermesHome(now: time("15:01"),
                                                    next: meetNext(FeedBuilder.hermes("waiting_room")), today: meetToday()),
                  now: time("15:01"))
        await add("hermes-in-call-chat", recording(now: hermesLive, next: meetNext(FeedBuilder.hermes("in_call", chat: true))), now: hermesLive)
        await add("hermes-in-call-list", recording(now: hermesLive, next: meetNext(FeedBuilder.hermes("in_call"))), now: hermesLive) { _, store in
            store.navigate(.list)
        }
        await add("hermes-failed", hermesHome(
                                              next: meetNext(FeedBuilder.hermes("failed", error: "Meet didn't let the notetaker in")),
                                              today: meetToday(["pipeline": FeedBuilder.hermes("failed", error: "Meet link not valid")])),
                  now: hermesNow)
        await add("hermes-action-failed", hermesHome(next: meetNext(), today: meetToday()), now: hermesNow) { fake, store in
            fake.failCalls(true)
            if case .idle(let content) = store.screen, let meeting = content.next, let target = store.hermesTarget(for: meeting) {
                await store.setHermes(target, .join)
            }
        }

        let beforeNow = time("14:55")
        await add("before", RecorderSnapshot(feed: FeedBuilder.feed(at: beforeNow, next: upNext)), now: beforeNow)
        await add("before-armed", RecorderSnapshot(phase: .armed, feed: FeedBuilder.feed(at: beforeNow, next: upNext)),
                  now: time("14:59:40"))
        await add("before-in-person", RecorderSnapshot(feed: FeedBuilder.feed(
            at: beforeNow,
            next: FeedBuilder.meeting("Coffee with Dana Whitfield at Houndstooth", start: time("15:05"), end: time("15:45"),
                                      brief: ["First meeting; intro came from Dana", "She runs ops at a 40-person logistics firm"]))),
                  now: beforeNow)
        await add("before-back-to-back", RecorderSnapshot(feed: FeedBuilder.feed(
            at: time("15:52"),
            next: FeedBuilder.meeting("Larkspur weekly planning", start: time("16:00"), end: time("16:30"),
                                      url: "https://meet.google.com/abc-defg-hij", brief: ["Agenda: Q4 pipeline, hiring"]),
            recent: [FeedBuilder.recent(maxSid, title, endedAt: time("15:47:48"), state: .filing, durationS: 2868)]
                + recentRows(now: time("15:52")))), now: time("15:52"))

        let liveNow = at(727)
        await add("recording", recording(now: liveNow), now: liveNow)
        await add("recording-just-started", recording(now: at(14), lines: [], marks: [], warnings: []), now: at(14))
        var browsing = recording(now: liveNow)
        browsing.feed = FeedBuilder.feed(at: liveNow.addingTimeInterval(-40), next: upNext, recent: recentRows(now: liveNow))
        await add("recording-list", browsing, now: liveNow) { _, store in store.navigate(.list) }
        await add("recording-marked", recording(now: liveNow), now: liveNow) { _, store in
            await store.markMoment()
        }
        await add("recording-in-person", recording(
            now: liveNow,
            lines: [TranscriptLine(speaker: "room", text: "So the warehouse lease ends in March, which gives us a window.", at: at(700))],
            marks: [], warnings: [], kind: .inPerson, title: nil), now: liveNow)
        await add("recording-long-text", recording(
            now: liveNow,
            lines: [
                TranscriptLine(speaker: "them", text: String(repeating: "We should circle back on the vendor consolidation and the procurement timeline. ", count: 4), at: at(690)),
                TranscriptLine(speaker: "me", text: "Agreed.", at: at(720))
            ],
            title: "Quarterly business review with Orchard leadership, finance, and the Poland expansion working group"),
                  now: liveNow)
        await add("recording-long-conversation", recording(
            now: at(3000), lines: longConversation(), marks: [at(1500), at(2900)],
            warnings: [(at(1900), warnings[0]), (at(2950), warnings[1])]), now: at(3000)) { _, store in
            await store.submitAsk("What did Dana say about Poland?")
        }
        await add("recording-mic-off", recording(now: liveNow, micOK: false), now: liveNow)
        await add("warning-inline", recording(now: at(760), lines: callLines + [line(5, 740), line(6, 752)],
                                              warnings: [(at(724.5), warnings[0]), (at(745), warnings[1])]), now: at(760))
        await add("ask-waiting", recording(now: liveNow), now: liveNow) { fake, store in
            fake.failLive(true)
            fake.hold()
            Task { await store.submitAsk("What did Dana say about Poland?") }
            while fake.calls.isEmpty { await Task.yield() }
        }
        await add("ask-streaming", recording(now: liveNow), now: liveNow) { fake, store in
            fake.answer(with: "Last call you agreed to hold Poland until next week's numbers.")
            fake.hold()
            Task { await store.submitAsk("What did we decide about Poland?") }
            while fake.calls.isEmpty { await Task.yield() }
            for _ in 0..<20 { await Task.yield() }
        }
        await add("ask-answered", recording(now: liveNow), now: liveNow) { fake, store in
            fake.answer(with: "Last call you agreed to hold Poland until next week's numbers. Nothing new since.")
            await store.submitAsk("What did we decide about Poland?")
        }
        await add("ask-failed", recording(now: liveNow), now: liveNow) { fake, store in
            fake.failCalls(true)
            await store.submitAsk("What did we decide about Poland?")
        }
        await add("confirm-not-a-meeting", recording(now: liveNow), now: liveNow) { _, store in
            await store.perform(.notAMeeting(sid: maxSid))
        }
        await add("action-running", recording(now: liveNow), now: liveNow) { fake, store in
            fake.hold()
            Task { await store.perform(.pause) }
            while fake.calls.isEmpty { await Task.yield() }
        }
        await add("action-failed", recording(now: liveNow), now: liveNow) { fake, store in
            fake.failCalls(true)
            await store.perform(.pause)
        }
        await add("paused", recording(now: at(724), lines: Array(callLines.prefix(4)), marks: [], warnings: []), now: at(724)) { _, store in
            store.update(RecorderSnapshot(phase: .paused, feed: FeedBuilder.feed(at: at(700), next: upNext)))
        }
        await add("paused-mark-missed", recording(now: at(724), lines: Array(callLines.prefix(4)), marks: [], warnings: []), now: at(724)) { _, store in
            store.update(RecorderSnapshot(phase: .paused, feed: FeedBuilder.feed(at: at(700), next: upNext)))
            await store.markMoment()
        }

        await add("paused-after-not-a-meeting", RecorderSnapshot(phase: .paused, feed: FeedBuilder.feed(at: at(700), next: upNext)),
                  now: at(724))

        let filedNote = "in your vault and the Orchard folder"
        list.append(after(.waiting))
        var held = RecorderSnapshot(phase: .ended, sid: maxSid, title: title, eventStart: start, startedAt: start, marks: 1,
                                    feed: FeedBuilder.feed(at: time("15:48").addingTimeInterval(-20), recent: recentRows(now: time("15:48"))))
        held.heldUntil = time("15:52:48")
        await add("after-held", held, now: time("15:48"))
        list.append(after(.filing))
        list.append(after(.filed, note: filedNote, noteURL: noteURL, review: (true, 6), summary: summary,
                          moments: [(at(719), "yes, once the Klaviyo skill is in")]))
        list.append(after(.filed, name: "after-filed-no-moments", note: filedNote, noteURL: noteURL, review: (true, 0),
                          summary: summary, moments: []))
        list.append(after(.skipped, note: "under 2 minutes of speech"))
        list.append(after(.failed))
        let confirmForget = after(.filed, note: filedNote, noteURL: noteURL, review: (true, 6), summary: summary,
                                  moments: [(at(719), "yes, once the Klaviyo skill is in")])
        await confirmForget.store.perform(.forget(sid: maxSid))
        list.append(PanelScenario(name: "confirm-forget", recorder: confirmForget.recorder, store: confirmForget.store))
        await add("after-from-list", RecorderSnapshot(feed: idleFeed), now: idleNow) { _, store in
            store.navigate(.call("20261023-090000-5e6f", fromList: true))
        }

        let accessNow = time("14:20")
        await add("access", RecorderSnapshot(audioOK: false, feed: FeedBuilder.feed(at: accessNow, next: upNext)), now: accessNow)
        await add("before-group", RecorderSnapshot(feed: FeedBuilder.feed(
            at: beforeNow,
            next: FeedBuilder.meeting("Orchard leadership review", start: time("15:00"), end: time("15:45"), url: zoomURL,
                                      brief: ["Last call: Q4 budget, Poland hiring"], owed: ["Send the revised Q4 budget"]))),
                  now: beforeNow)
        await add("before-audio-off", RecorderSnapshot(audioOK: false, feed: FeedBuilder.feed(at: beforeNow, next: upNext)), now: beforeNow)
        await add("access-mic", RecorderSnapshot(micOK: false, feed: FeedBuilder.feed(at: accessNow)), now: accessNow)
        return list
    }

    /// The overlay's states, each rendered in every style.
    public static func overlays() async -> [PanelScenario] {
        var list: [PanelScenario] = []
        func add(_ name: String, _ snapshot: RecorderSnapshot, now: Date, _ prepare: (FakeRecorder, PanelStore) async -> Void = { _, _ in }) async {
            let (fake, store) = makeStore(snapshot, now: now)
            await prepare(fake, store)
            list.append(PanelScenario(name: name, recorder: fake, store: store))
        }
        let liveNow = at(760)
        let lines = callLines + [line(5, 740), line(6, 752)]
        await add("overlay-live", recording(now: liveNow, lines: lines), now: liveNow)
        await add("overlay-just-started", recording(now: at(14), lines: [], marks: [], warnings: []), now: at(14))
        await add("overlay-say", recording(now: liveNow, lines: lines), now: liveNow) { fake, store in
            fake.answer(with: "Say you'll send the SOP list tonight, and confirm the onboarding doc is Monday, not today.")
            await store.quickAsk(.say)
        }
        await add("overlay-streaming", recording(now: liveNow, lines: lines), now: liveNow) { fake, store in
            fake.answer(with: "Dana asked for the SOP list and whether Poland is decided. Both are still open.")
            fake.hold()
            Task { await store.quickAsk(.asked) }
            while fake.calls.isEmpty { await Task.yield() }
            for _ in 0..<20 { await Task.yield() }
        }
        await add("overlay-paused", recording(now: at(724), lines: Array(callLines.prefix(4)), marks: [], warnings: []), now: at(724)) { _, store in
            store.update(RecorderSnapshot(phase: .paused, feed: FeedBuilder.feed(at: at(700), next: upNext)))
        }
        return list
    }
}
