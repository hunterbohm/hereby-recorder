import Foundation
import Testing
@testable import LMLCore

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
private let selector = MicDeviceSelector(ownPID: 100, clients: MeetingClients())
private func meeting(_ devices: [UInt32]?, input: Bool = true, pid: Int32 = 4) -> ProcessRow {
    ProcessRow(bundle: "net.imput.helium.helper", input: input, pid: pid, inputDevices: devices)
}
private func granola(_ devices: [UInt32]) -> ProcessRow {
    ProcessRow(bundle: "com.granola.app.helper", input: true, pid: 5, inputDevices: devices)
}
private func snapshot(_ rows: [ProcessRow]) -> ProcessSnapshot { ProcessSnapshot(procs: rows, ts: epoch) }

struct MicDeviceTests {
    @Test func meetingOnSevenNeverSelectsDefaultThree() {
        let device = selector.eligible(snapshot([meeting([7]), granola([3])]), defaultInput: 3)
        #expect(device == 7)
        #expect(device != 3)
    }
    @Test func meetingOnDefaultSelectsDefault() {
        #expect(selector.eligible(snapshot([meeting([7, 3])]), defaultInput: 3) == 3)
    }
    @Test func granolaAloneSelectsItsDevice() {
        #expect(selector.eligible(snapshot([granola([7])]), defaultInput: 3) == 7)
        #expect(selector.eligible(snapshot([granola([7, 3])]), defaultInput: 3) == 3)
        #expect(selector.eligible(snapshot([granola([7, 3])]), defaultInput: 9) == 3)
    }
    @Test func ownPIDCannotOpenGateOrContributeDefaultDevice() {
        #expect(selector.eligible(snapshot([meeting([3], pid: 100)]), defaultInput: 3) == nil)
        #expect(selector.eligible(snapshot([meeting([3], pid: 100), meeting([7])]), defaultInput: 3) == 7)
        var ownGranola = granola([3]); ownGranola.pid = 100
        #expect(selector.eligible(snapshot([ownGranola]), defaultInput: 3) == nil)
    }
    @Test func defaultChangeKeepsMeetingDeviceAndRun() throws {
        let processes = snapshot([meeting([7])])
        var capture = MicCaptureState()
        #expect(capture.update(device: selector.eligible(processes, defaultInput: 7)) == true)
        let run = try #require(capture.runID)
        #expect(capture.update(device: selector.eligible(processes, defaultInput: 3)) == false)
        #expect(capture.device == 7)
        #expect(capture.runID == run)
    }
    @Test func lowestDeviceWinsRegardlessOfProcessAndDeviceOrder() {
        let rows = [meeting([9, 7]), meeting([5, 8], pid: 6), granola([3])]
        #expect(selector.eligible(snapshot(rows), defaultInput: 3) == 5)
        #expect(selector.eligible(snapshot(Array(rows.reversed())), defaultInput: 3) == 5)
    }
    @Test func defaultWinsOnlyWithinMeetingCandidates() {
        #expect(selector.eligible(snapshot([meeting([9, 7]), meeting([5], pid: 6), granola([3])]), defaultInput: 7) == 7)
    }
    @Test func noEligibleInputClosesGate() {
        for rows in [[], [meeting([7], input: false)], [meeting(nil)], [meeting([])], [meeting([0])],
                     [ProcessRow(bundle: "com.apple.CoreSpeech", input: true, pid: 8, inputDevices: [3])]] {
            #expect(selector.eligible(snapshot(rows), defaultInput: 3) == nil)
        }
        #expect(selector.eligible(snapshot([meeting([7])]), defaultInput: 0) == 7)
        #expect(selector.eligible(snapshot([meeting([]), granola([7])]), defaultInput: 3) == 7)
    }
    @Test func meetingMovesFromSevenToThreeStartsNewRunWithTrueTime() async throws {
        var capture = MicCaptureState()
        var segmenter = RunSegmenter()
        let writer = SessionWriter(sid: "20261013-190012-a3f1", startedAt: epoch, directory: nil)
        #expect(capture.update(device: selector.eligible(snapshot([meeting([7])]), defaultInput: 3)) == true)
        let first = try #require(capture.runID)
        #expect(segmenter.accept(at: epoch, duration: 1, source: first) == true)
        await writer.beginRun(at: epoch, channel: .me)
        let before = try #require(await writer.receive(Recognition(ch: .me, start: 0, end: 1,
            words: [Word(start: 0, end: 1, text: "before")], final: true, anchor: epoch)))
        await writer.endRun(channel: .me)
        #expect(capture.update(device: selector.eligible(snapshot([meeting([3])]), defaultInput: 3)) == true)
        let second = try #require(capture.runID)
        #expect(capture.device == 3)
        #expect(second != first)
        let nextTime = epoch.addingTimeInterval(1)
        #expect(segmenter.accept(at: nextTime, duration: 1, source: second) == true)
        #expect(segmenter.anchor == nextTime)
        await writer.beginRun(at: nextTime, channel: .me)
        let after = try #require(await writer.receive(Recognition(ch: .me, start: 0, end: 1,
            words: [Word(start: 0, end: 1, text: "after")], final: true, anchor: segmenter.anchor)))
        #expect(before.ts0 == epoch)
        #expect(after.ts0 == nextTime)
        #expect(after.seq == 2)
        #expect(await writer.snapshot(at: epoch.addingTimeInterval(2)).finals.map(\.text) == ["before", "after"])
    }
    @Test func configurationAndDeviceListChangesRestartSameDevice() throws {
        var capture = MicCaptureState()
        let processes = snapshot([meeting([7])])
        capture.update(device: selector.eligible(processes, defaultInput: 3))
        let first = try #require(capture.runID)
        #expect(capture.update(device: selector.eligible(processes, defaultInput: 3), restart: true) == true)
        let second = try #require(capture.runID)
        #expect(second != first)
        #expect(capture.device == 7)
        #expect(capture.update(device: selector.eligible(processes, defaultInput: 3), restart: true) == true)
        #expect(capture.runID != second)
        #expect(capture.device == 7)
    }
    @Test func lastClientReleaseClosesImmediatelyAndReopenStartsNewRun() throws {
        var capture = MicCaptureState()
        capture.update(device: selector.eligible(snapshot([meeting([7])]), defaultInput: 3))
        let first = try #require(capture.runID)
        #expect(capture.update(device: selector.eligible(snapshot([]), defaultInput: 3)) == true)
        #expect(capture.device == nil)
        #expect(capture.runID == nil)
        #expect(capture.update(device: nil, restart: true) == false)
        #expect(capture.update(device: selector.eligible(snapshot([meeting([7])]), defaultInput: 3)) == true)
        #expect(capture.runID != first)
    }
}
