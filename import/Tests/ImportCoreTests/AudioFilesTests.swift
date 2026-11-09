import AVFoundation
import Foundation
import Testing
@testable import ImportCore

private func silence(_ url: URL, seconds: Double = 1) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false])
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(16_000 * seconds))!
    buffer.frameLength = buffer.frameCapacity
    try file.write(from: buffer)
}

struct AudioFilesTests {
    @Test func fileRecordingIsIdentifiedByContentAndDatedFromItsEnd() async throws {
        let directory = try temporaryDirectory()
        let original = directory.appendingPathComponent("memo.wav"), copy = directory.appendingPathComponent("renamed.wav")
        try silence(original)
        try FileManager.default.copyItem(at: original, to: copy)
        let ended = Date(timeIntervalSince1970: 1_790_000_100)
        try FileManager.default.setAttributes([.modificationDate: ended], ofItemAtPath: original.path)

        let recording = try await AudioFiles.recording(at: original)
        #expect(recording.source == .file && recording.title == "memo.wav")
        #expect(abs(recording.duration - 1) < 0.01)
        #expect(abs(recording.startedAt.timeIntervalSince(ended.addingTimeInterval(-1))) < 0.01)
        #expect(recording.audio == .mixed(original))
        #expect(recording.startEstimated)
        #expect(recording.id.hasPrefix("file:sha256:"))
        #expect(try await AudioFiles.recording(at: copy).id == recording.id)
        let dated = try await AudioFiles.recording(at: original, started: epoch)
        #expect(dated.startedAt == epoch && !dated.startEstimated)
    }

    @Test func notAudioIsRejected() async throws {
        let file = try temporaryDirectory().appendingPathComponent("notes.m4a")
        try Data("not audio".utf8).write(to: file)
        await #expect(throws: (any Error).self) { try await AudioFiles.recording(at: file) }
    }

    @Test func inboxWaitsForAFileToStopChanging() async throws {
        let file = try temporaryDirectory().appendingPathComponent("copying.m4a")
        try Data().write(to: file)
        #expect(try await AudioFiles.waitUntilSettled(file, quiet: 0.3, limit: 5))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: file.path)
        #expect(try await !AudioFiles.waitUntilSettled(file, quiet: 0.3, limit: 0.6))
    }

    @Test func inboxListsAudioFilesAndArchivesWithoutOverwriting() throws {
        let inbox = try temporaryDirectory()
        for name in ["b.mp3", "a.M4A", ".hidden.wav", "notes.txt"] { try Data().write(to: inbox.appendingPathComponent(name)) }
        try FileManager.default.createDirectory(at: inbox.appendingPathComponent("folder.wav"), withIntermediateDirectories: true)
        #expect(try AudioFiles.inboxFiles(inbox).map(\.lastPathComponent) == ["a.M4A", "b.mp3"])

        let first = try AudioFiles.archive(inbox.appendingPathComponent("b.mp3"), inbox: inbox)
        try Data().write(to: inbox.appendingPathComponent("b.mp3"))
        let second = try AudioFiles.archive(inbox.appendingPathComponent("b.mp3"), inbox: inbox)
        #expect(first.path == inbox.appendingPathComponent("Imported/b.mp3").path)
        #expect(second.path == inbox.appendingPathComponent("Imported/b 2.mp3").path)
        #expect(try AudioFiles.inboxFiles(inbox).map(\.lastPathComponent) == ["a.M4A"])
    }
}
