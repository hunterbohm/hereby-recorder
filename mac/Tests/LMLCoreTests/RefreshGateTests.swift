import Testing
@testable import LMLCore

@Suite struct RefreshGateTests {
    @Test func aBurstOfEventsSchedulesOneRefreshThatKeepsARestartRequest() {
        var gate = RefreshGate(interval: 0.25)
        #expect(gate.request(restart: false, now: 10) == 0)
        for _ in 0..<1000 { #expect(gate.request(restart: false, now: 10.01) == nil) }
        #expect(gate.request(restart: true, now: 10.02) == nil)
        let folded = gate.begin()
        #expect(folded)
        #expect(gate.request(restart: false, now: 10.03) == 0)
        let next = gate.begin()
        #expect(!next)
    }
    @Test func refreshesWaitOutTheIntervalAfterTheLastRead() {
        var gate = RefreshGate(interval: 0.25)
        _ = gate.request(restart: false, now: 0); _ = gate.begin(); gate.finishedRead(at: 1.0)
        #expect(gate.request(restart: false, now: 1.125) == 0.125)
        _ = gate.begin(); gate.finishedRead(at: 1.4)
        #expect(gate.request(restart: false, now: 5) == 0)
    }
    @Test func theLoopsOwnReadAlsoSpacesTheNextRefresh() {
        var gate = RefreshGate(interval: 0.25)
        gate.finishedRead(at: 2.0)
        #expect(gate.request(restart: false, now: 2.0625) == 0.1875)
    }
}
