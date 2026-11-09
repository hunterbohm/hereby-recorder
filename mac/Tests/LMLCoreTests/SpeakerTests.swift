import Foundation
import Testing
@testable import LMLCore

private let start = Date(timeIntervalSince1970: 1_800_000_000)

struct SpeakerTests {
    @Test func speakersAreNumberedInOrderOfFirstSpeechAtWallClockTimes() {
        let turns = SpeakerTurns(start: start, expected: 2, segments: [
            (speaker: "S7", from: 4, to: 6), (speaker: "S2", from: 0, to: 3), (speaker: "S7", from: 9, to: 9), (speaker: "S2", from: 7, to: 8)])
        #expect(turns.turns == [
            .init(t0: start, t1: start.addingTimeInterval(3), speaker: 1),
            .init(t0: start.addingTimeInterval(4), t1: start.addingTimeInterval(6), speaker: 2),
            .init(t0: start.addingTimeInterval(7), t1: start.addingTimeInterval(8), speaker: 1)])
        #expect(turns.expected == 2)
    }
    @Test func voicesThatSoundAlikeAreOnePerson() {
        let groups = SpeakerTurns.merged(["S1": [1, 0, 0], "S2": [0, 1, 0], "S3": [0.95, 0.2, 0], "S4": [0, 0.9, 0.3]])
        #expect(groups == ["S1": "S1", "S2": "S2", "S3": "S1", "S4": "S2"])
    }
    @Test func differentVoicesStaySeparate() {
        let groups = SpeakerTurns.merged(["S1": [1, 0], "S2": [0.79, 0.61]])
        #expect(groups == ["S1": "S1", "S2": "S2"])
    }
    @Test func theCalendarGivesTheVoiceCountOnlyWhenItsMeetingsAgree() throws {
        let schedule = try JSON.decoder().decode(Schedule.self, from: Data(#"""
        {"at":"2026-10-27T18:00:00Z","events":[
         {"key":"a","start":"2026-10-27T19:00:00Z","end":"2026-10-27T20:00:00Z","has_conference":true,"attendee_count":4,"others":3},
         {"key":"b","start":"2026-10-27T19:00:00Z","end":"2026-10-27T20:00:00Z","has_conference":true,"attendee_count":3,"others":2},
         {"key":"c","start":"2026-10-27T19:00:00Z","end":"2026-10-27T20:00:00Z","has_conference":true,"attendee_count":2}]}
        """#.utf8))
        #expect(schedule.others(keys: ["a"]) == 3)
        #expect(schedule.others(keys: ["a", "c"]) == 3)
        #expect(schedule.others(keys: ["a", "b"]) == nil)
        #expect(schedule.others(keys: ["c"]) == nil)
        #expect(schedule.others(keys: []) == nil)
    }
}
