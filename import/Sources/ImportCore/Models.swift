import Foundation
import Darwin

public enum Speaker: String, Codable, Sendable { case me, them, call }
public enum Source: String, Codable, Sendable { case phone, file }

public struct Word: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String
    public init(start: Double, end: Double, text: String) { self.start = start; self.end = end; self.text = text }
}

public struct Utterance: Sendable, Equatable {
    public var speaker: Speaker
    public var words: [Word]
    public init(speaker: Speaker, words: [Word]) { self.speaker = speaker; self.words = words }
}

public enum AudioPlan: Sendable, Equatable {
    case tracks(URL, [Speaker])
    case mixed(URL)
}

public struct Recording: Sendable {
    public var id: String
    public var source: Source
    public var title: String?
    public var startedAt: Date
    public var duration: Double
    public var audio: AudioPlan?
    public var transcript: [Utterance]?
    public var startEstimated: Bool
    public init(id: String, source: Source, title: String? = nil, startedAt: Date, duration: Double, audio: AudioPlan? = nil,
                transcript: [Utterance]? = nil, startEstimated: Bool = false) {
        self.id = id; self.source = source; self.title = title; self.startedAt = startedAt
        self.duration = duration; self.audio = audio; self.transcript = transcript; self.startEstimated = startEstimated
    }
}

public protocol AudioTranscriber: Sendable {
    func transcribe(_ plan: AudioPlan) async throws -> [Utterance]
}

public enum JSON {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = parseDate(value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date")
            }
            return date
        }
        return decoder
    }
    public static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

public enum PrivateFiles {
    public static func directory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    public static func write(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let file = try FileHandle(forWritingTo: temporary)
        do { try file.write(contentsOf: data); try file.synchronize(); try file.close() }
        catch { try? file.close(); throw error }
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

public struct TranscriptPart: Codable, Sendable, Equatable {
    public var t0: Date
    public var t1: Date
    public var text: String
    public var xo: Double
    public var words: [[Double]]
}

public struct TranscriptRow: Codable, Sendable, Equatable {
    public var v = 1
    public var seq: Int
    public var ch: Speaker
    public var ts0: Date
    public var ts1: Date
    public var at: Date
    public var text: String
    public var xo: Double
    public var parts: [TranscriptPart]
}

public struct SessionMeta: Codable, Sendable, Equatable {
    public var v = 1
    public var sid: String
    public var state = "closed"
    public var started_at: Date
    public var ended_at: Date
    public var heartbeat_at: Date
    public var apps: [String]
    public var cal_keys: [String] = []
    public var asr: String
    public var segments: Int
    public var test = false
    public var me: String
    public var warnings: [String] = []
    public var version = 1
    public var kind = "call"
    public var source: Source
}

public struct Session: Sendable, Equatable {
    public var meta: SessionMeta
    public var rows: [TranscriptRow]
}
