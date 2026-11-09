import Foundation

public struct AppleWord: Sendable, Equatable {
    public var speaker: String?
    public var start: Double
    public var duration: Double
    public var text: String
    public init(speaker: String?, start: Double, duration: Double, text: String) {
        self.speaker = speaker; self.start = start; self.duration = duration; self.text = text
    }
}

public struct AudioRecordingDoc: Sendable, Equatable {
    public struct Fragment: Sendable, Equatable {
        public var identity: String?
        public var words: [AppleWord]
    }
    public var startTime: Date?
    public var localHandle: String?
    public var remoteHandle: String?
    public var fragments: [Fragment]
}

public enum CRDTError: Error, Equatable {
    case unsupported(String)
    case malformed(String)
}

/// Decodes the protobuf CRDT document Apple Notes stores for an audio recording attachment (ZMERGEABLEDATA1).
public enum AudioRecordingDecoder {
    public static func decode(_ data: Data, transcripts: Bool = true) throws -> AudioRecordingDoc {
        let bytes = [UInt8](data)
        if bytes.starts(with: [0x1f, 0x8b]) { throw CRDTError.unsupported("gzip") }
        let document = try Document(bytes)
        guard case .typed(let type, let root) = try document.object(0), type == "com.apple.notes.ICTTAudioRecording" else {
            throw CRDTError.unsupported("not an audio recording")
        }
        var fragments: [AudioRecordingDoc.Fragment] = []
        if let value = root["fragments"], case .orderedSet(let set) = try document.resolve(value) {
            for item in try set.messages(1) {
                guard let element = try item.message(2), case .typed(_, let fields) = try document.resolve(element) else {
                    throw CRDTError.malformed("fragment")
                }
                var words: [AppleWord] = []
                if transcripts, let transcript = fields["transcript"], case .array(let array) = try document.resolve(transcript) {
                    words = try document.elements(array).map { try document.word($0) }
                }
                fragments.append(.init(identity: try fields["identity"].flatMap(document.string), words: words))
            }
        }
        return AudioRecordingDoc(
            startTime: try root["callRecordingStartTime"].flatMap(document.number).map(Date.init(timeIntervalSince1970:)),
            localHandle: try root["callLocalSpeakerHandle"].flatMap(document.string),
            remoteHandle: try root["callRemoteSpeakerHandle"].flatMap(document.string),
            fragments: fragments)
    }
}

private struct Document {
    enum Resolved {
        case int(Int64), uint(UInt64), double(Double), string(String)
        case typed(String, [String: Proto])
        case orderedSet(Proto)
        case array(Proto)
        case none
    }

    let top: Proto
    let entries: [Proto.Field]
    let keys: [String]
    let types: [String]
    let uuids: [[UInt8]]

    init(_ bytes: [UInt8]) throws {
        let top = try Proto(bytes, bytes.indices)
        self.top = top
        entries = top.all(3)
        keys = top.all(4).map(top.string)
        types = top.all(5).map(top.string)
        uuids = top.all(6).map { Array(top.bytes($0)) }
    }

    func object(_ index: Int) throws -> Resolved {
        try object(index, depth: 0)
    }

    private func object(_ index: Int, depth: Int) throws -> Resolved {
        guard entries.indices.contains(index) else { throw CRDTError.malformed("object reference") }
        let entry = try top.message(entries[index])
        if let typed = try entry.message(13) {
            guard let type = typed.varint(1).flatMap({ types[safe: Int(clamping: $0)] }) else { throw CRDTError.malformed("type index") }
            var fields: [String: Proto] = [:]
            for field in try typed.messages(3) {
                guard let key = field.varint(1).flatMap({ keys[safe: Int(clamping: $0)] }) else { throw CRDTError.malformed("key index") }
                if let value = try field.message(2) { fields[key] = value }
            }
            return .typed(type, fields)
        }
        if let register = try entry.message(1) {
            guard let value = try register.message(2) else { return .none }
            return try resolve(value, depth: depth + 1)
        }
        if let set = try entry.message(5) { return .orderedSet(set) }
        if let array = try entry.message(15) { return .array(array) }
        return .none
    }

    func resolve(_ value: Proto) throws -> Resolved { try resolve(value, depth: 0) }

    private func resolve(_ value: Proto, depth: Int) throws -> Resolved {
        guard depth < 32 else { throw CRDTError.malformed("reference cycle") }
        if let index = value.varint(6) { return try object(Int(clamping: index), depth: depth + 1) }
        if let field = value.first(4) { return .string(value.string(field)) }
        if let bits = value.fixed64(3) { return .double(Double(bitPattern: bits)) }
        if let int = value.varint(1) { return .int(Int64(bitPattern: int)) }
        if let uint = value.varint(2) { return .uint(uint) }
        return .none
    }

    func string(_ value: Proto) throws -> String? {
        switch try resolve(value) {
        case .string(let string): return string
        case .typed("com.apple.CRDT.NSString", let fields):
            guard let inner = fields["self"], case .string(let string) = try resolve(inner) else { return nil }
            return string
        default: return nil
        }
    }

    func number(_ value: Proto) throws -> Double? {
        switch try resolve(value) {
        case .typed("com.apple.CRDT.NSNumber", let fields): return try (fields["integerValue"] ?? fields["doubleValue"]).flatMap(scalar)
        case .typed("com.apple.CRDT.NSDate", let fields): return try fields["doubleValue"].flatMap(scalar)
        case let resolved: return Self.scalar(resolved)
        }
    }

    private func scalar(_ value: Proto) throws -> Double? { Self.scalar(try resolve(value)) }

    private static func scalar(_ resolved: Resolved) -> Double? {
        switch resolved {
        case .int(let int): return Double(int)
        case .uint(let uint): return Double(uint)
        case .double(let double): return double
        default: return nil
        }
    }

    func uuid(_ value: Proto) throws -> [UInt8]? {
        guard case .typed("com.apple.CRDT.NSUUID", let fields) = try resolve(value),
              let index = try fields["UUIDIndex"].flatMap(scalar).flatMap({ Int(exactly: $0) }) else { return nil }
        return uuids[safe: index]
    }

    /// Array layout: {1: ordering {1: text {3: substrings}, 2: [{1: position, 2: uuid}]}, 2: {1: [{1: uuid key, 2: element}]}}.
    func elements(_ array: Proto) throws -> [Proto] {
        var positions: [[UInt8]: UInt64] = [:]
        if let ordering = try array.message(1) {
            if let text = try ordering.message(1), try text.messages(3).contains(where: { ($0.varint(4) ?? 0) != 0 }) {
                throw CRDTError.unsupported("edited transcript")
            }
            for item in try ordering.messages(2) {
                guard let field = item.first(2), item.bytes(field).count == 16 else { throw CRDTError.malformed("array uuid") }
                positions[Array(item.bytes(field))] = item.varint(1) ?? 0
            }
        }
        let items = try array.message(2)?.messages(1) ?? []
        return try items.enumerated().map { offset, item -> (UInt64, Int, Proto) in
            guard let key = try item.message(1), let uuid = try uuid(key), let position = positions[uuid],
                  let element = try item.message(2) else { throw CRDTError.malformed("array element") }
            return (position, offset, element)
        }
        .sorted { ($0.0, $0.1) < ($1.0, $1.1) }
        .map(\.2)
    }

    func word(_ element: Proto) throws -> AppleWord {
        guard case .typed("com.apple.notes.ICTTTranscriptSegment", let fields) = try resolve(element),
              let start = try fields["timestamp"].flatMap(number),
              let duration = try fields["duration"].flatMap(number) else { throw CRDTError.malformed("transcript segment") }
        return AppleWord(speaker: try fields["speaker"].flatMap(string), start: start, duration: duration,
            text: try fields["text"].flatMap(string) ?? "")
    }
}

struct Proto {
    struct Field {
        let number: Int
        let wire: UInt8
        let scalar: UInt64
        let range: Range<Int>
    }

    let buffer: [UInt8]
    let fields: [Field]

    init(_ buffer: [UInt8], _ range: Range<Int>) throws {
        self.buffer = buffer
        var fields: [Field] = []
        var index = range.lowerBound
        func varint() throws -> UInt64 {
            var result: UInt64 = 0, shift: UInt64 = 0
            while true {
                guard index < range.upperBound, shift < 64 else { throw CRDTError.malformed("varint") }
                let byte = buffer[index]; index += 1
                result |= UInt64(byte & 0x7f) << shift
                if byte < 0x80 { return result }
                shift += 7
            }
        }
        func take(_ count: Int) throws -> Range<Int> {
            guard count >= 0, range.upperBound - index >= count else { throw CRDTError.malformed("length") }
            defer { index += count }
            return index..<(index + count)
        }
        while index < range.upperBound {
            let key = try varint()
            let number = Int(key >> 3), wire = UInt8(key & 7)
            switch wire {
            case 0: fields.append(Field(number: number, wire: wire, scalar: try varint(), range: index..<index))
            case 1:
                let bytes = try take(8)
                let bits = bytes.reversed().reduce(UInt64(0)) { $0 << 8 | UInt64(buffer[$1]) }
                fields.append(Field(number: number, wire: wire, scalar: bits, range: bytes))
            case 2:
                let length = try varint()
                guard length <= UInt64(Int.max) else { throw CRDTError.malformed("length") }
                fields.append(Field(number: number, wire: wire, scalar: 0, range: try take(Int(length))))
            case 5: fields.append(Field(number: number, wire: wire, scalar: 0, range: try take(4)))
            default: throw CRDTError.malformed("wire type \(wire)")
            }
        }
        self.fields = fields
    }

    func all(_ number: Int) -> [Field] { fields.filter { $0.number == number } }
    func first(_ number: Int) -> Field? { fields.first { $0.number == number } }
    func varint(_ number: Int) -> UInt64? { fields.first { $0.number == number && $0.wire == 0 }?.scalar }
    func fixed64(_ number: Int) -> UInt64? { fields.first { $0.number == number && $0.wire == 1 }?.scalar }
    func bytes(_ field: Field) -> ArraySlice<UInt8> { buffer[field.range] }
    func string(_ field: Field) -> String { String(decoding: buffer[field.range], as: UTF8.self) }

    func message(_ field: Field) throws -> Proto {
        guard field.wire == 2 else { throw CRDTError.malformed("expected message") }
        return try Proto(buffer, field.range)
    }
    func message(_ number: Int) throws -> Proto? {
        try fields.first { $0.number == number && $0.wire == 2 }.map(message)
    }
    func messages(_ number: Int) throws -> [Proto] {
        try fields.filter { $0.number == number && $0.wire == 2 }.map(message)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
