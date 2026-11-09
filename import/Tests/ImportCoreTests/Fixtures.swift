import Foundation
@testable import ImportCore

struct PB {
    var bytes: [UInt8] = []
    mutating func varint(_ value: UInt64) {
        var value = value
        while value >= 0x80 { bytes.append(UInt8(value & 0x7f) | 0x80); value >>= 7 }
        bytes.append(UInt8(value))
    }
    mutating func key(_ number: Int, _ wire: UInt8) { varint(UInt64(number) << 3 | UInt64(wire)) }
    mutating func int(_ number: Int, _ value: UInt64) { key(number, 0); varint(value) }
    mutating func data(_ number: Int, _ value: [UInt8]) { key(number, 2); varint(UInt64(value.count)); bytes += value }
    mutating func string(_ number: Int, _ value: String) { data(number, Array(value.utf8)) }
    mutating func double(_ number: Int, _ value: Double) {
        key(number, 1)
        var bits = value.bitPattern
        for _ in 0..<8 { bytes.append(UInt8(bits & 0xff)); bits >>= 8 }
    }
    mutating func message(_ number: Int, _ build: (inout PB) -> Void) { var inner = PB(); build(&inner); data(number, inner.bytes) }
}

enum CRValue { case ref(Int), string(String), double(Double), uint(UInt64) }

struct TestWord { var speaker: String; var start: Double; var duration: Double; var text: String }

final class DocBuilder {
    static let allKeys = ["identity", "toplineSummaryModelVersionInfo", "self", "callRecordingStartTime", "doubleValue", "fragments",
                          "transcriptVersion", "integerValue", "transcript", "speaker", "duration", "timestamp", "text", "UUIDIndex",
                          "createdDate", "callLocalSpeakerHandle", "callRemoteSpeakerHandle", "callType", "callRecording"]
    static let allTypes = ["com.apple.CRDT.NSNumber", "com.apple.CRDT.NSString", "com.apple.CRDT.NSUUID", "com.apple.CRDT.NSDate",
                           "com.apple.notes.ICTTAudioRecording", "com.apple.notes.ICTTAudioRecording.Fragment",
                           "com.apple.notes.ICTTTranscriptSegment"]
    let keys: [String]
    let types: [String]
    private var uuids: [[UInt8]] = []
    private var entries: [[UInt8]] = [[]]

    init(keys: [String] = DocBuilder.allKeys, types: [String] = DocBuilder.allTypes) { self.keys = keys; self.types = types }

    private func write(_ value: CRValue, _ message: inout PB) {
        switch value {
        case .ref(let index): message.int(6, UInt64(index))
        case .string(let string): message.string(4, string)
        case .double(let double): message.double(3, double)
        case .uint(let uint): message.int(2, uint)
        }
    }

    @discardableResult private func add(_ build: (inout PB) -> Void) -> Int {
        var entry = PB(); build(&entry); entries.append(entry.bytes); return entries.count - 1
    }

    private func objectBody(_ type: String, _ fields: [(String, CRValue)]) -> (inout PB) -> Void {
        { entry in
            entry.message(13) { object in
                object.int(1, UInt64(self.types.firstIndex(of: type)!))
                for (key, value) in fields {
                    object.message(3) { field in
                        field.int(1, UInt64(self.keys.firstIndex(of: key)!))
                        field.message(2) { self.write(value, &$0) }
                    }
                }
            }
        }
    }

    func object(_ type: String, _ fields: [(String, CRValue)]) -> Int { add(objectBody(type, fields)) }

    func register(_ value: CRValue?) -> Int {
        add { entry in
            entry.message(1) { register in
                register.message(1) { $0.int(1, 0); $0.int(2, 1) }
                if let value { register.message(2) { self.write(value, &$0) } }
            }
        }
    }

    func string(_ value: String?) -> Int { register(value.map { .ref(object("com.apple.CRDT.NSString", [("self", .string($0))])) }) }
    func number(_ value: Double) -> Int { register(.ref(object("com.apple.CRDT.NSNumber", [("doubleValue", .double(value))]))) }
    func date(_ value: Double?) -> Int { register(value.map { .ref(object("com.apple.CRDT.NSDate", [("doubleValue", .double($0))])) }) }

    func orderedSet(_ items: [Int]) -> Int {
        add { entry in entry.message(5) { set in for item in items { set.message(1) { $0.message(2) { $0.int(6, UInt64(item)) } } } } }
    }

    /// `positions[i]` is element i's place in the array; elements are stored in the dictionary in the order given.
    func array(_ elements: [Int], positions: [Int], deleted: Bool = false) -> Int {
        var ids: [[UInt8]] = []
        var keyObjects: [Int] = []
        for _ in elements {
            var uuid = [UInt8](repeating: 0, count: 16)
            uuid[0] = UInt8(uuids.count + 1)
            uuids.append(uuid); ids.append(uuid)
            keyObjects.append(object("com.apple.CRDT.NSUUID", [("UUIDIndex", .uint(UInt64(uuids.count - 1)))]))
        }
        return add { entry in
            entry.message(15) { array in
                array.message(1) { ordering in
                    ordering.message(1) { text in
                        text.string(2, String(repeating: "x", count: elements.count))
                        text.message(3) { $0.message(1) { $0.int(1, 0); $0.int(2, 0) }; $0.int(2, 0); $0.int(5, 1) }
                        text.message(3) { sub in
                            sub.message(1) { $0.int(1, 1); $0.int(2, 0) }
                            sub.int(2, UInt64(elements.count))
                            if deleted { sub.int(4, 1) }
                            sub.int(5, 2)
                        }
                    }
                    for (index, uuid) in ids.enumerated() { ordering.message(2) { $0.int(1, UInt64(positions[index])); $0.data(2, uuid) } }
                }
                array.message(2) { dictionary in
                    for (index, element) in elements.enumerated() {
                        dictionary.message(1) { item in
                            item.message(1) { $0.int(6, UInt64(keyObjects[index])) }
                            item.message(2) { $0.int(6, UInt64(element)) }
                        }
                    }
                }
            }
        }
    }

    func segment(_ word: TestWord) -> Int {
        object("com.apple.notes.ICTTTranscriptSegment", [
            ("identity", .string(UUID().uuidString)), ("speaker", .ref(string(word.speaker))),
            ("text", .ref(string(word.text))), ("timestamp", .ref(number(word.start))), ("duration", .ref(number(word.duration)))])
    }

    func root(start: Double?, local: String?, remote: String?, fragments: [Int]) {
        var entry = PB()
        objectBody("com.apple.notes.ICTTAudioRecording", [
            ("identity", .string("00000000-0000-0000-0000-000000000000")),
            ("callRecordingStartTime", .ref(date(start))), ("callLocalSpeakerHandle", .ref(string(local))),
            ("callRemoteSpeakerHandle", .ref(string(remote))), ("fragments", .ref(orderedSet(fragments)))])(&entry)
        entries[0] = entry.bytes
    }

    var data: Data {
        var top = PB()
        for entry in entries { top.data(3, entry) }
        for key in keys { top.string(4, key) }
        for type in types { top.string(5, type) }
        for uuid in uuids { top.data(6, uuid) }
        return Data(top.bytes)
    }

    /// A call recording document whose single fragment holds `words`, stored in dictionary order `storage`.
    static func call(start: Double = 1_790_000_000, local: String = "+15550000001", remote: String = "+15550000002",
                     fragment: String = "FRAG-1", words: [TestWord], storage: [Int]? = nil, deleted: Bool = false,
                     keys: [String] = allKeys) -> Data {
        let doc = DocBuilder(keys: keys)
        let order = storage ?? Array(words.indices)
        let segments = order.map { doc.segment(words[$0]) }
        let transcript = doc.array(segments, positions: order, deleted: deleted)
        let fragmentObject = doc.object("com.apple.notes.ICTTAudioRecording.Fragment",
            [("identity", .string(fragment)), ("transcript", .ref(transcript))])
        doc.root(start: start, local: local, remote: remote, fragments: [fragmentObject])
        return doc.data
    }
}

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("lml-import-tests-\(UUID().uuidString)")
    try PrivateFiles.directory(url)
    return url
}

let epoch = Date(timeIntervalSince1970: 1_790_000_000)
