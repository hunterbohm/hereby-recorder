import Foundation
import Testing
@testable import ImportCore

private let sample = [
    TestWord(speaker: "+15550000001", start: 0.0, duration: 0.4, text: "Hello"),
    TestWord(speaker: "+15550000001", start: 0.5, duration: 0.3, text: " there."),
    TestWord(speaker: "+15550000002", start: 0.2, duration: 0.5, text: " Hi."),
]

struct CRDTTests {
    @Test func decodesACallRecordingInArrayOrder() throws {
        let data = DocBuilder.call(words: sample, storage: [2, 0, 1], keys: DocBuilder.allKeys.reversed())
        let doc = try AudioRecordingDecoder.decode(data)
        #expect(doc.startTime == epoch)
        #expect(doc.localHandle == "+15550000001")
        #expect(doc.remoteHandle == "+15550000002")
        #expect(doc.fragments.count == 1)
        #expect(doc.fragments[0].identity == "FRAG-1")
        #expect(doc.fragments[0].words == sample.map { AppleWord(speaker: $0.speaker, start: $0.start, duration: $0.duration, text: $0.text) })
    }

    @Test func recordingWithoutCallFieldsHasNoStartTime() throws {
        let doc = DocBuilder()
        doc.root(start: nil, local: nil, remote: nil, fragments: [])
        let decoded = try AudioRecordingDecoder.decode(doc.data)
        #expect(decoded.startTime == nil)
        #expect(decoded.fragments.isEmpty)
    }

    @Test func editedTranscriptIsRefusedButTheRecordingStillDecodesWithoutIt() throws {
        let data = DocBuilder.call(words: sample, deleted: true)
        #expect(throws: CRDTError.unsupported("edited transcript")) { try AudioRecordingDecoder.decode(data) }
        let doc = try AudioRecordingDecoder.decode(data, transcripts: false)
        #expect(doc.startTime == epoch)
        #expect(doc.fragments.map(\.words) == [[]])
    }

    @Test func otherDocumentsAndDamagedBytesThrowInsteadOfCrashing() {
        let note = DocBuilder()
        _ = note.string("not a recording")
        #expect(throws: CRDTError.unsupported("not an audio recording")) { try AudioRecordingDecoder.decode(note.data) }
        #expect(throws: CRDTError.unsupported("gzip")) { try AudioRecordingDecoder.decode(Data([0x1f, 0x8b, 0, 0])) }
        let full = DocBuilder.call(words: sample)
        for cut in stride(from: 1, to: full.count, by: 5) {
            #expect(throws: CRDTError.self) { try AudioRecordingDecoder.decode(full.prefix(cut)) }
        }
    }
}
