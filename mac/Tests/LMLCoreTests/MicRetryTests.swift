import Foundation
import Testing
@testable import LMLCore

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

struct MicRetryTests {
    @Test func eachFailureWaitsLongerThenRetriesAtTheLastDelayForever() {
        var retry = MicRetry()
        #expect(retry.allows(at: epoch))
        var now = epoch
        for delay in MicRetry.delays + Array(repeating: MicRetry.delays.last!, count: 500) {
            #expect(retry.failed(at: now) == now.addingTimeInterval(delay))
            #expect(!retry.allows(at: now.addingTimeInterval(delay - 0.001)))
            now = now.addingTimeInterval(delay)
            #expect(retry.allows(at: now))
        }
    }
    @Test func aSuccessfulStartResetsTheBudget() {
        var retry = MicRetry()
        _ = retry.failed(at: epoch); _ = retry.failed(at: epoch.addingTimeInterval(1))
        retry.succeeded()
        #expect(retry == MicRetry())
        #expect(retry.failed(at: epoch.addingTimeInterval(10)) == epoch.addingTimeInterval(11))
    }
}
