import Foundation

/// The mic hears the call through the speakers. A mic row whose words each match a word of the call channel
/// spoken within a second of it is that sound coming back, not the user.
public enum EchoGate {
    public static let tolerance: TimeInterval = 1
    public static let share = 0.8

    private struct Spoken { var token: String; var at: Date }

    private static func spoken(_ row: TranscriptRow) -> [Spoken]? {
        var result: [Spoken] = []
        for part in row.parts {
            guard let timings = part.words else { return nil }
            let texts = part.text.split(whereSeparator: \.isWhitespace)
            guard texts.count == timings.count else { return nil }
            for (text, timing) in zip(texts, timings) where timing.count == 2 {
                let token = text.lowercased().filter { $0.isLetter || $0.isNumber }
                if !token.isEmpty { result.append(Spoken(token: token, at: part.t0.addingTimeInterval(timing[0]))) }
            }
        }
        return result
    }

    public static func isEcho(_ row: TranscriptRow, of calls: [TranscriptRow]) -> Bool {
        guard let mine = spoken(row), !mine.isEmpty else { return false }
        var theirs = calls.flatMap { spoken($0) ?? [] }
        var matched = 0
        for word in mine {
            let nearest = theirs.indices
                .filter { theirs[$0].token == word.token && abs(theirs[$0].at.timeIntervalSince(word.at)) <= tolerance }
                .min { abs(theirs[$0].at.timeIntervalSince(word.at)) < abs(theirs[$1].at.timeIntervalSince(word.at)) }
            if let index = nearest { theirs.remove(at: index); matched += 1 }
        }
        return Double(matched) / Double(mine.count) >= share
    }
}
