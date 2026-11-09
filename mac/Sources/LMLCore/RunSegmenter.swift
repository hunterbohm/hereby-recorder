import Foundation

public struct RunSegmenter: Sendable {
    public private(set) var anchor: Date?
    private var expected: Date?
    private var source: UUID?
    public init() {}
    public mutating func accept(at: Date, duration: Double, source: UUID?) -> Bool {
        let startsRun = anchor == nil || self.source != source || expected.map { abs(at.timeIntervalSince($0)) > 0.5 } == true
        if startsRun { anchor = at; self.source = source }
        expected = at.addingTimeInterval(duration)
        return startsRun
    }
    public mutating func end() { anchor = nil; expected = nil; source = nil }
}
