import Foundation
import Testing
@testable import LMLCore

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
private func at(_ seconds: Double) -> Date { epoch.addingTimeInterval(seconds) }
private func snapshot(_ seconds: Double, _ rows: [ProcessRow]) -> ProcessSnapshot { ProcessSnapshot(procs: rows, ts: at(seconds)) }
private let browser = ProcessRow(bundle: "net.imput.helium.helper", input: true, pid: 4, inputDevices: [10])
private let output = ProcessRow(bundle: "net.imput.helium.helper", output: true, pid: 4)
private func temporary() throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lml-tests-\(UUID().uuidString)")
    try PrivateFiles.directory(directory); return directory
}

struct DetectorTests {
    @Test func testDebounceAndArmingDiscard() {
        var detector = Detector(ownPID: 100, clients: MeetingClients())
        #expect(detector.update(snapshot(0, [browser]), schedule: nil) == .arm)
        #expect(detector.update(snapshot(9, [browser]), schedule: nil) == nil)
        #expect(detector.update(snapshot(9.5, []), schedule: nil) == .discard)
        #expect(detector.state == .idle)
        #expect(detector.update(snapshot(10, [browser]), schedule: nil) == .arm)
        #expect(detector.update(snapshot(20, [browser]), schedule: nil) == .activate)
    }
    @Test func testHangoverAndRejoin() {
        var d = Detector(ownPID: 100, clients: MeetingClients()); d.forceActive()
        #expect(d.update(snapshot(20, []), schedule: nil) == nil)
        #expect(d.update(snapshot(139, []), schedule: nil) == nil)
        #expect(d.update(snapshot(139.5, [browser]), schedule: nil) == nil)
        #expect(d.update(snapshot(140, []), schedule: nil) == nil)
        #expect(d.update(snapshot(260, []), schedule: nil) == .close)
        d.reset()
        #expect(d.update(snapshot(261, [browser]), schedule: nil) == .arm)
    }
    @Test func testCalendarOutputStartsAndHoldsExtendedMute() {
        let schedule = Schedule(generated_at: at(0), events: [CalendarEvent(key: "call", start: at(100), end: at(800))])
        var d = Detector(ownPID: 100, clients: MeetingClients())
        #expect(d.update(snapshot(0, []), schedule: schedule) == nil)
        #expect(d.update(snapshot(0, [output]), schedule: schedule) == .arm)
        #expect(d.update(snapshot(10, [output]), schedule: schedule) == .activate)
        #expect(d.update(snapshot(400, [output]), schedule: schedule) == nil)
        #expect(d.update(snapshot(801, [output]), schedule: schedule) == nil)
        #expect(d.update(snapshot(921, [output]), schedule: schedule) == .close)
    }
    @Test func testStaleCalendarSoloEventAndUnlistedOutputDoNotStart() {
        let stale = Schedule(generated_at: at(-901), events: [CalendarEvent(key: "call", start: at(0), end: at(100))])
        var d = Detector(ownPID: 100, clients: MeetingClients())
        #expect(d.update(snapshot(0, [output]), schedule: stale) == nil)
        let solo = Schedule(generated_at: at(0), events: [CalendarEvent(key: "solo", start: at(0), end: at(100), has_conference: false, attendee_count: 1)])
        #expect(d.update(snapshot(0, [output]), schedule: solo) == nil)
        #expect(d.update(snapshot(0, [ProcessRow(bundle: "music", output: true)]), schedule: stale) == nil)
    }
    @Test func testGranolaStartsAndCoreSpeechOwnAndDictationAreIgnored() {
        var d = Detector(ownPID: 100, clients: MeetingClients())
        for bundle in ["com.apple.CoreSpeech", "com.openwispr.app"] {
            #expect(d.update(snapshot(0, [ProcessRow(bundle: bundle, input: true)]), schedule: nil) == nil)
        }
        #expect(d.update(snapshot(0, [ProcessRow(bundle: "us.zoom", input: true, pid: 100)]), schedule: nil) == nil)
        #expect(d.update(snapshot(1, [ProcessRow(bundle: "com.granola.app.helper", input: true)]), schedule: nil) == .arm)
    }
    @Test func testRealMeetingReplay() throws {
        let file = Bundle.module.url(forResource: "probe-live", withExtension: "jsonl", subdirectory: "Fixtures")!
        let rows = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map { try JSON.decoder().decode(ProcessSnapshot.self, from: Data($0.utf8)) }
        var d = Detector(ownPID: 100000, clients: MeetingClients())
        var arms: [Date] = []; var activations = 0; var closes = 0
        for row in rows {
            switch d.update(row, schedule: nil) {
            case .arm: arms.append(row.ts)
            case .activate: activations += 1
            case .close: closes += 1
            default: break
            }
        }
        #expect(arms.count == 1); #expect(activations == 1); #expect(closes == 0)
        let expected = ISO8601DateFormatter().date(from: "2026-10-13T23:59:44Z")!
        #expect(arms.first == expected); #expect(d.state == .active)
    }
}

struct GateTests {
    @Test func testMicFollowsOnlyExternalInputClientWithoutHoldover() {
        let selector = MicDeviceSelector(ownPID: 100, clients: MeetingClients())
        func eligible(_ rows: [ProcessRow], defaultInput: UInt32 = 10) -> UInt32? {
            selector.eligible(snapshot(0, rows), defaultInput: defaultInput)
        }
        #expect(eligible([]) == nil)
        #expect(eligible([browser]) == 10)
        #expect(eligible([]) == nil)
        #expect(eligible([browser], defaultInput: 11) == 10)
        var own = browser; own.pid = 100
        #expect(eligible([own]) == nil)
        #expect(eligible([ProcessRow(bundle: "com.granola.app.helper", input: true, inputDevices: [10])]) == 10)
        #expect(eligible([ProcessRow(bundle: "com.apple.CoreSpeech", input: true, inputDevices: [10])]) == nil)
        #expect(eligible([ProcessRow(bundle: "us.zoom", input: true)]) == nil)
    }
    @Test func testSilentWarningRequiresSixtySecondsOfRealZeroSamplesAndOutput() {
        var guardrail = SilenceGuard()
        guardrail.update(peak: 0, sampleCount: 100, outputRunning: true, at: at(0))
        guardrail.update(peak: 0, sampleCount: 100, outputRunning: true, at: at(59)); #expect(!(guardrail.warning))
        guardrail.update(peak: 0, sampleCount: 100, outputRunning: true, at: at(60)); #expect(guardrail.warning)
        guardrail.update(peak: 0.01, sampleCount: 100, outputRunning: true, at: at(61)); #expect(!(guardrail.warning))
        guardrail.update(peak: 0, sampleCount: 0, outputRunning: true, at: at(200)); #expect(!(guardrail.warning))
        guardrail.update(peak: 0, sampleCount: 100, outputRunning: false, at: at(300)); #expect(!(guardrail.warning))
    }
    @Test func testSilentWarningNeverReturnsOnceTheCallWasHeard() {
        var guardrail = SilenceGuard()
        guardrail.update(peak: 0.2, sampleCount: 100, outputRunning: true, at: at(0))
        guardrail.update(peak: 0, sampleCount: 100, outputRunning: true, at: at(1))
        guardrail.update(peak: 0, sampleCount: 100, outputRunning: true, at: at(600)); #expect(!(guardrail.warning))
    }
}

struct WriterTests {
    private func writer(directory: URL? = nil) async -> SessionWriter {
        let writer = SessionWriter(sid: "20261013-190012-a3f1", startedAt: epoch, directory: directory, test: true)
        await writer.setAnchor(epoch, channel: .me); await writer.setAnchor(at(0.2), channel: .them)
        return writer
    }
    @Test func testSequenceAndCaptureClockIndependentOfArrival() async throws {
        let w = await writer()
        let them = try await w.receive(Recognition(ch: .them, start: 2, end: 3, words: [Word(start: 2, end: 3, text: "Remote")], final: true, at: at(20)))!
        let me = try await w.receive(Recognition(ch: .me, start: 0, end: 1, words: [Word(start: 0, end: 1, text: "Reply")], final: true, at: at(30)))!
        #expect(them.seq == 1); #expect(me.seq == 2)
        #expect(them.ts0 == at(2.2)); #expect(them.ts1 == at(3.2)); #expect(me.ts0 == at(0)); #expect(me.at == at(30))
    }
    @Test func testPartsSplitAtEnergyAndCalendarWindowWithPerPartOverlap() async throws {
        let w = await writer()
        var ring = EnergyRing()
        for index in Int64(epoch.timeIntervalSince1970 * 10 + 10)..<Int64(epoch.timeIntervalSince1970 * 10 + 20) { ring.record(index: index, speech: true) }
        await w.setEnergy(ring, channel: .them)
        let url = Bundle.module.url(forResource: "schedule", withExtension: "json", subdirectory: "Fixtures")!
        let schedule = try JSON.read(Schedule.self, from: url)
        #expect(schedule.windowStarts.last == at(2))
        await w.setSchedule(schedule)
        let words = [Word(start: 0, end: 0.9, text: "first "), Word(start: 1, end: 1.9, text: "overlap "), Word(start: 2, end: 2.9, text: "next")]
        let row = try await w.receive(Recognition(ch: .me, start: 0, end: 3, words: words, final: true, at: at(4)))!
        #expect(row.parts.map(\.text) == ["first", "overlap", "next"])
        #expect(abs(row.parts[0].xo - (0)) <= 0.0001); #expect(abs(row.parts[1].xo - (1)) <= 0.0001); #expect(abs(row.parts[2].xo - (0)) <= 0.0001)
        #expect(abs(row.xo - (1.0 / 3)) <= 0.0001)
        let live = await w.snapshot(at: at(4))
        #expect(live.speech["them"] == [[at(1), at(2)]])
    }
    @Test func testCalendarSplitsEvenWithoutEnergyChange() async throws {
        let w = await writer()
        let schedule = Schedule(generated_at: epoch, events: [CalendarEvent(key: "previous", start: at(-1000), end: at(2)), CalendarEvent(key: "next", start: at(2), end: at(100))])
        await w.setSchedule(schedule)
        let row = try await w.receive(Recognition(ch: .me, start: 0, end: 4, words: [Word(start: 0, end: 1, text: "old "), Word(start: 2, end: 4, text: "new")], final: false, at: at(5)))!
        #expect(row.parts.count == 2); #expect(row.parts[1].t0 == at(2))
    }
    @Test func testPhraseMovesFromPartialToFinalAndRemainingPartialIsPreserved() async throws {
        let w = await writer()
        let words = [Word(start: 0, end: 1, text: "A phrase. "), Word(start: 1, end: 2, text: "More.")]
        try await w.receive(Recognition(ch: .me, start: 0, end: 2, words: words, final: false))
        let before = await w.snapshot(at: at(3))
        #expect(before.partials["me"]??.text == "A phrase. More."); #expect(before.finals.isEmpty)
        try await w.receive(Recognition(ch: .me, start: 0, end: 1, words: [words[0]], final: true))
        let after = await w.snapshot(at: at(3))
        #expect(after.finals.first?.text == "A phrase."); #expect(after.partials["me"]??.text == "More.")
        #expect(after.partials["me"]??.ts0 == at(1)); #expect(after.seq_hi == 1)
        try await w.receive(Recognition(ch: .me, start: 1, end: 2, words: [words[1]], final: true))
        let last = await w.snapshot(at: at(3)); #expect(last.partials["me"]! == nil); #expect(last.finals.count == 2)
    }
    @Test func testArmingWritesNothingAndActivationPersistsPrivateFiles() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("session")
        let w = await writer(directory: directory)
        try await w.receive(Recognition(ch: .me, start: 0, end: 1, words: [Word(start: 0, end: 1, text: "private fixture")], final: true))
        try await w.publish(at: at(1)); #expect(!(FileManager.default.fileExists(atPath: directory.path)))
        try await w.activate(at: at(10))
        let live = try JSON.read(LiveSnapshot.self, from: directory.appendingPathComponent("live.json"))
        #expect(live.seq_hi == 1); #expect(live.finals.isEmpty)
        let meta = try JSON.read(SessionMeta.self, from: directory.appendingPathComponent("meta.json"))
        #expect(meta.test); #expect(meta.segments == 1)
        for name in ["transcript.jsonl", "live.json", "meta.json"] {
            let attrs = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)
            #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(try String(contentsOf: directory.appendingPathComponent("transcript.jsonl"), encoding: .utf8).split(separator: "\n").count == 1)
    }
    @Test func testSnapshotWindowAndHeartbeatCadencesAndClose() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let w = await writer(directory: root)
        try await w.activate(at: at(0))
        try await w.publish(at: at(4))
        var meta = try JSON.read(SessionMeta.self, from: root.appendingPathComponent("meta.json")); #expect(meta.heartbeat_at == at(0))
        try await w.publish(at: at(5))
        meta = try JSON.read(SessionMeta.self, from: root.appendingPathComponent("meta.json")); #expect(meta.heartbeat_at == at(5))
        try await w.receive(Recognition(ch: .me, start: 0, end: 1, words: [Word(start: 0, end: 1, text: "expired")], final: true))
        let live = await w.snapshot(at: at(902)); #expect(live.finals.isEmpty); #expect(live.seq_hi == 0)
        try await w.close(at: at(903))
        meta = try JSON.read(SessionMeta.self, from: root.appendingPathComponent("meta.json")); #expect(meta.state == .closed); #expect(meta.ended_at == at(903))
    }
}

struct EnergyTests {
    @Test func testRMSAdaptiveThresholdAndSharedHundredMillisecondGrid() {
        var ring = EnergyRing()
        ring.add(samples: Array(repeating: 0, count: 100), sampleRate: 1000, at: epoch)
        ring.add(samples: Array(repeating: 0.1, count: 100), sampleRate: 1000, at: at(0.1))
        ring.add(samples: Array(repeating: 0, count: 100), sampleRate: 1000, at: at(0.2))
        #expect(!(ring.speaking(at: at(0.05)))); #expect(ring.speaking(at: at(0.15)))
        #expect(abs(ring.overlap(from: at(0), to: at(0.3)) - (1.0 / 3)) <= 0.001)
        #expect(ring.intervals(since: at(0), through: at(0.3)) == [[at(0.1), at(0.2)]])
    }
    @Test func testOverlapClipsFramesAndEmptySpans() {
        var ring = EnergyRing(); ring.record(index: Int64(epoch.timeIntervalSince1970 * 10), speech: true)
        #expect(abs(ring.overlap(from: at(0.05), to: at(0.15)) - (0.5)) <= 0.001)
        #expect(ring.overlap(from: epoch, to: epoch) == 0)
    }
}

struct RetentionTests {
    @Test func testSettingUnlessTheMiniScheduleNamesOne() {
        #expect(Retention.days(Settings().retentionDays, schedule: nil) == 14)
        #expect(Retention.days(3, schedule: nil) == 3)
        #expect(Retention.days(3, schedule: Schedule(generated_at: epoch)) == 3)
        #expect(Retention.days(3, schedule: Schedule(generated_at: epoch, retention_days: 2)) == 2)
    }
    @Test func testExpiredClosedSessionsOnly() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let paths = SessionPaths(root: root)
        for (sid, state, ended) in [("20261013-190012-a3f1", SessionMeta.State.closed, at(-86400 * 15)), ("20261013-190013-a3f1", .closed, epoch), ("20261013-190014-a3f1", .active, at(-86400 * 15))] {
            let directory = paths.session(sid); try PrivateFiles.directory(directory)
            var meta = SessionMeta(sid: sid, started_at: at(-86400 * 20)); meta.state = state; meta.ended_at = ended
            try PrivateFiles.write(meta, to: directory.appendingPathComponent("meta.json"))
        }
        #expect(try Retention.expired(in: paths, days: 14, now: epoch) == ["20261013-190012-a3f1"])
    }
    @Test func testSessionIDsAndRoots() {
        let sid = SessionPaths.id(at: epoch, suffix: 0xa3f1)
        #expect(SessionPaths.validID(sid)); #expect(sid.hasSuffix("-a3f1"))
        #expect(!(SessionPaths.validID("../unsafe")))
        #expect(SessionPaths(home: URL(fileURLWithPath: "/tmp/home"), test: true).sessions.path.hasSuffix("LiveMeetingListener-test/sessions"))
    }
}

extension WriterTests {
    @Test func testDiscardDropsLateFinalsAndNeverCreatesSession() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("discarded")
        let w = await writer(directory: directory)
        await w.discard()
        let row = try await w.receive(Recognition(ch: .me, start: 0, end: 1, words: [Word(start: 0, end: 1, text: "discarded")], final: true))
        #expect(row == nil)
        try await w.activate(at: at(10)); #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
    @Test func testSnapshotInvariantAcrossOneHundredFinalizations() async throws {
        let w = await writer()
        for index in 0..<100 {
            let start = Double(index * 2), end = start + 1, text = "phrase-\(index)"
            let words = [Word(start: start, end: end, text: text)]
            try await w.receive(Recognition(ch: .me, start: start, end: end, words: words, final: false, at: at(end)))
            let before = await w.snapshot(at: at(end))
            #expect(before.partials["me"]??.text == text)
            #expect(!before.finals.contains { $0.text == text })
            try await w.receive(Recognition(ch: .me, start: start, end: end, words: words, final: true, at: at(end)))
            let after = await w.snapshot(at: at(end))
            #expect(after.partials["me"]! == nil)
            #expect(after.finals.filter { $0.text == text }.count == 1)
        }
    }
    @Test func testShortUnmatchedSessionDiscardsButCalendarAndTestSessionsStay() async throws {
        let w = SessionWriter(sid: "20261013-190012-a3f1", startedAt: epoch, directory: nil)
        await w.setAnchor(epoch, channel: .me)
        try await w.receive(Recognition(ch: .me, start: 0, end: 59, words: [Word(start: 0, end: 59, text: "short")], final: true))
        #expect(await w.shouldDiscardShortSession())
        await w.setContext(apps: [], calKeys: ["call"], micOpen: false, silent: false)
        #expect(!(await w.shouldDiscardShortSession()))
        let testWriter = await writer()
        #expect(!(await testWriter.shouldDiscardShortSession()))
    }
}

extension WriterTests {
    @Test func testWordAcrossCalendarBoundaryStaysWithItsStartAndDoesNotSpanParts() async throws {
        let w = await writer()
        await w.setSchedule(Schedule(generated_at: epoch, events: [CalendarEvent(key: "previous", start: at(-1000), end: at(2)), CalendarEvent(key: "next", start: at(2), end: at(100))]))
        let row = try await w.receive(Recognition(ch: .me, start: 1.8, end: 3, words: [Word(start: 1.8, end: 2.2, text: "boundary "), Word(start: 2.4, end: 3, text: "next")], final: true, at: at(4)))!
        #expect(row.parts.count == 2); #expect(row.parts[0].t1 == at(2)); #expect(row.parts[1].t0 == at(2.4))
        #expect(row.parts.map(\.text) == ["boundary", "next"])
    }
}

struct LoopWatchTests {
    private let second: UInt64 = 1_000_000_000
    @Test func testStallNamesTheStepThatStoppedTurning() {
        let watch = LoopWatch(limit: 60, now: 100 * second)
        watch.enter("arm", now: 110 * second)
        #expect(watch.stall(now: 169 * second) == nil)
        #expect(watch.stall(now: 170 * second) == LoopWatch.Stall(step: "arm", seconds: 60))
    }
    @Test func testEnteringAStepResetsTheClock() {
        let watch = LoopWatch(limit: 60, now: 0)
        watch.enter("capture", now: 50 * second)
        watch.enter("idle", now: 100 * second)
        #expect(watch.stall(now: 150 * second) == nil)
    }
}

struct CallHoldTests {
    private let meet = "net.imput.helium.helper", zoom = "us.zoom.xos"
    @Test func theHeldCallWaitsFiveMinutesFromWhenItEnded() {
        let hold = CallHold(endedAt: at(0), apps: [meet], calKeys: [])
        #expect(!hold.expired(at: at(299)))
        #expect(hold.expired(at: at(300)))
    }
    @Test func theSameAppWithNoNewCalendarMeetingContinuesTheCall() {
        let adHoc = CallHold(endedAt: at(0), apps: [meet], calKeys: [])
        #expect(adHoc.continues(apps: [meet], calKeys: []))
        #expect(!adHoc.continues(apps: [zoom], calKeys: []), "a call in another app is a new call")
        #expect(!adHoc.continues(apps: [meet], calKeys: ["next"]), "a meeting that starts on the calendar is a new call")
        let scheduled = CallHold(endedAt: at(0), apps: [meet, zoom], calKeys: ["sync"])
        #expect(scheduled.continues(apps: [zoom], calKeys: ["sync"]))
        #expect(scheduled.continues(apps: [meet], calKeys: []), "a call that runs past its calendar end still continues")
        #expect(!scheduled.continues(apps: [meet], calKeys: ["sync", "next"]))
    }
    @Test func callAppsAreTheMeetingAppsUsingAudioExceptOurOwn() {
        let clients = MeetingClients()
        let own = ProcessRow(bundle: meet, input: true, pid: 100, inputDevices: [10])
        let idleApp = ProcessRow(bundle: zoom, pid: 7)
        let music = ProcessRow(bundle: "com.spotify.client", output: true, pid: 8)
        #expect(clients.callApps(snapshot(0, [browser, own, idleApp, music]), ownPID: 100) == [meet])
    }
}
