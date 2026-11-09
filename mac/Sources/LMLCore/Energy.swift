import Foundation

public struct EnergyRing: Sendable {
    public struct Frame: Sendable {
        public var index: Int64
        public var speech: Bool
    }
    private var frames: [Int64: Bool] = [:]
    private var pendingIndex: Int64?
    private var sumSquares = 0.0
    private var count = 0
    private var noiseRMS = 0.00001
    private var lastPrune: Int64?
    public init() {}
    public mutating func record(index: Int64, speech: Bool) { frames[index] = speech }
    public mutating func add(samples: [Float], sampleRate: Double, at start: Date) {
        guard sampleRate > 0 else { return }
        for (offset, sample) in samples.enumerated() {
            let index = Int64(floor((start.timeIntervalSince1970 + Double(offset) / sampleRate) * 10))
            if let previous = pendingIndex, previous != index { finishFrame(previous) }
            pendingIndex = index
            sumSquares += Double(sample) * Double(sample); count += 1
        }
        if let index = pendingIndex {
            frames[index] = count > 0 && sqrt(sumSquares / Double(count)) > noiseRMS * pow(10, 12.0 / 20)
            if lastPrune == nil || index - lastPrune! >= 100 {
                prune(before: index - 18_000); lastPrune = index
            }
        }
    }
    private mutating func finishFrame(_ index: Int64) {
        let rms = count > 0 ? sqrt(sumSquares / Double(count)) : 0
        let speaking = rms > noiseRMS * pow(10, 12.0 / 20)
        frames[index] = speaking
        if !speaking { noiseRMS = max(0.000001, noiseRMS * 0.98 + rms * 0.02) }
        else { noiseRMS = noiseRMS * 0.995 + min(rms, noiseRMS * 2) * 0.005 }
        sumSquares = 0; count = 0
    }
    public mutating func prune(before index: Int64) { frames = frames.filter { $0.key >= index } }
    public func speaking(at time: Date) -> Bool { frames[Int64(floor(time.timeIntervalSince1970 * 10))] ?? false }
    public func overlap(from start: Date, to end: Date) -> Double {
        let duration = end.timeIntervalSince(start)
        guard duration > 0 else { return 0 }
        let t0 = start.timeIntervalSince1970, t1 = end.timeIntervalSince1970
        var covered = 0.0
        for (index, speech) in frames where speech {
            let frameStart = Double(index) / 10
            covered += max(0, min(t1, frameStart + 0.1) - max(t0, frameStart))
        }
        return min(1, covered / duration)
    }
    private static func date(_ index: Int64) -> Date {
        Date(timeIntervalSince1970: Double(index / 10)).addingTimeInterval(Double(index % 10) / 10)
    }
    public func intervals(since start: Date, through end: Date) -> [[Date]] {
        let indices = frames.filter { $0.value && Double($0.key + 1) / 10 > start.timeIntervalSince1970 && Double($0.key) / 10 < end.timeIntervalSince1970 }.keys.sorted()
        var spans: [[Date]] = []
        for index in indices {
            let t0 = max(start, Self.date(index))
            let t1 = min(end, Self.date(index + 1))
            if let last = spans.last, abs(last[1].timeIntervalSince(t0)) < 0.0001 { spans[spans.count - 1][1] = t1 }
            else { spans.append([t0, t1]) }
        }
        return spans
    }
}

public enum PartSplitter {
    public static func split(words: [Word], anchor: Date, other: EnergyRing, boundaries: [Date]) -> [TranscriptPart] {
        var groups: [[Word]] = []
        for word in words.sorted(by: { $0.start < $1.start }) where word.end > word.start && !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let start = anchor.addingTimeInterval(word.start)
            if let previous = groups.last?.last {
                let previousStart = anchor.addingTimeInterval(previous.start)
                let boundary = boundaries.contains { $0 > previousStart && $0 <= start }
                let changed = other.speaking(at: previousStart) != other.speaking(at: start)
                if !boundary && !changed { groups[groups.count - 1].append(word); continue }
            }
            groups.append([word])
        }
        return groups.map { group in
            let t0 = anchor.addingTimeInterval(group[0].start)
            let end = anchor.addingTimeInterval(group.last!.end)
            let t1 = min(end, boundaries.first(where: { $0 > t0 && $0 < end }) ?? end)
            return TranscriptPart(t0: t0, t1: t1, text: group.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines), xo: other.overlap(from: t0, to: t1), words: group.map { [$0.start - group[0].start, $0.end - group[0].start] })
        }
    }
}
