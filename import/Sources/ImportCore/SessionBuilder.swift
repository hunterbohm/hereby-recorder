import Foundation
import CryptoKit

public enum SessionBuilder {
    public static let appleASR = "apple-notes/call-transcript"
    public static let speechASR = "speechanalyzer/en_US"

    public static func validID(_ sid: String) -> Bool {
        sid.range(of: #"^\d{8}-\d{6}-[0-9a-f]{4}$"#, options: .regularExpression) != nil
    }

    public static func sid(for recording: Recording, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = timeZone; formatter.dateFormat = "yyyyMMdd-HHmmss"
        let digest = SHA256.hash(data: Data(recording.id.utf8))
        return formatter.string(from: recording.startedAt) + "-" + digest.prefix(2).map { String(format: "%02x", $0) }.joined()
    }

    public static func build(_ recording: Recording, utterances: [Utterance], asr: String, timeZone: TimeZone = .current) -> Session {
        let cleaned = utterances.compactMap { utterance -> Utterance? in
            let words = utterance.words
                .filter { $0.end >= $0.start && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .sorted { $0.start < $1.start }
            return words.isEmpty ? nil : Utterance(speaker: utterance.speaker, words: words)
        }
        var others: [Speaker: Timeline] = [:]
        for speaker in Set(cleaned.map(\.speaker)) {
            others[speaker] = Timeline(cleaned.filter { $0.speaker != speaker }.flatMap(\.words))
        }
        let origin = recording.startedAt
        let unordered = cleaned.map { utterance in
            row(utterance, other: others[utterance.speaker]!, origin: origin)
        }
        let rows = unordered.enumerated()
            .sorted { ($0.element.ts0, $0.element.ch.rawValue, $0.offset) < ($1.element.ts0, $1.element.ch.rawValue, $1.offset) }
            .enumerated()
            .map { index, entry in var row = entry.element; row.seq = index + 1; return row }
        let ended = max(origin.addingTimeInterval(recording.duration), rows.map(\.ts1).max() ?? origin)
        let meta = SessionMeta(
            sid: sid(for: recording, timeZone: timeZone), started_at: origin, ended_at: ended, heartbeat_at: ended,
            apps: recording.source == .phone ? ["com.apple.mobilephone"] : [], asr: asr, segments: rows.count,
            me: cleaned.contains { $0.speaker == .call } ? "mixed (one channel)" : "on",
            warnings: recording.startEstimated ? ["start_estimated"] : [], source: recording.source)
        return Session(meta: meta, rows: rows)
    }

    private static func row(_ utterance: Utterance, other: Timeline, origin: Date) -> TranscriptRow {
        var groups: [[Word]] = []
        for word in utterance.words {
            if let previous = groups.last?.last, other.contains(previous.start) == other.contains(word.start) {
                groups[groups.count - 1].append(word)
            } else {
                groups.append([word])
            }
        }
        let parts = groups.map { group in
            let start = group[0].start, end = group.last!.end
            return TranscriptPart(
                t0: origin.addingTimeInterval(start), t1: origin.addingTimeInterval(end),
                text: group.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines),
                xo: other.coverage(from: start, to: end),
                words: group.map { [$0.start - start, $0.end - start] })
        }
        let start = utterance.words.first!.start, end = utterance.words.last!.end
        let ts1 = origin.addingTimeInterval(end)
        return TranscriptRow(seq: 0, ch: utterance.speaker, ts0: origin.addingTimeInterval(start), ts1: ts1, at: ts1,
            text: parts.map(\.text).joined(separator: " "), xo: other.coverage(from: start, to: end), parts: parts)
    }

    /// Words arrive in transcript order, which groups each speaker's words into runs.
    public static func utterances(_ words: [(speaker: Speaker, word: Word)]) -> [Utterance] {
        var result: [Utterance] = []
        for (speaker, word) in words {
            if let current = result.last, current.speaker == speaker, let previous = current.words.last,
               word.start - previous.end < 1.5,
               !(previous.end - current.words[0].start >= 20 && endsSentence(previous.text)) {
                result[result.count - 1].words.append(word)
            } else {
                result.append(Utterance(speaker: speaker, words: [word]))
            }
        }
        return result
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return last == "." || last == "?" || last == "!"
    }
}

struct Timeline {
    private var spans: [(start: Double, end: Double)] = []

    init(_ words: [Word]) {
        for word in words.sorted(by: { $0.start < $1.start }) where word.end > word.start {
            if let last = spans.last, word.start <= last.end { spans[spans.count - 1].end = max(last.end, word.end) }
            else { spans.append((word.start, word.end)) }
        }
    }

    private func firstEnding(after time: Double) -> Int {
        var low = 0, high = spans.count
        while low < high {
            let mid = (low + high) / 2
            if spans[mid].end <= time { low = mid + 1 } else { high = mid }
        }
        return low
    }

    func contains(_ time: Double) -> Bool {
        let index = firstEnding(after: time)
        return index < spans.count && spans[index].start <= time
    }

    func coverage(from start: Double, to end: Double) -> Double {
        guard end > start else { return 0 }
        var covered = 0.0
        var index = firstEnding(after: start)
        while index < spans.count, spans[index].start < end {
            covered += min(end, spans[index].end) - max(start, spans[index].start)
            index += 1
        }
        return min(1, covered / (end - start))
    }
}
