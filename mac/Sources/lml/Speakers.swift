import AVFoundation
import FluidAudio
import LMLCore
import Synchronization

/// The other side of a call at 16 kHz, kept on disk only until its speakers are labeled. A gap in the tap is
/// written as silence so a second into the file stays a second after `start`.
actor ThemRecording {
    static let rate = 16_000.0
    let url: URL
    private(set) var start: Date?
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var inputRate = 0.0
    private var frames: AVAudioFramePosition = 0
    private var failed = false
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    init(url: URL) { self.url = url }

    func append(_ chunk: AudioChunk) {
        guard !failed, !chunk.samples.isEmpty, chunk.sampleRate > 0 else { return }
        do {
            if file == nil {
                try PrivateFiles.directory(url.deletingLastPathComponent())
                file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.rate,
                    AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false],
                    commonFormat: .pcmFormatFloat32, interleaved: false)
                _ = chmod(url.path, 0o600)
                start = chunk.at
            }
            let gap = chunk.at.timeIntervalSince(start!) - Double(frames) / Self.rate
            if gap > 0.5 { try silence(AVAudioFrameCount(gap * Self.rate)) }
            try write(convert(chunk))
        } catch {
            failed = true; file = nil
            FileHandle.standardError.write(Data("them_audio_failed\n".utf8))
        }
    }
    /// Closes the file and returns its first sample's time, or nil, with the file deleted, when nothing usable was written.
    func finish() -> Date? {
        file = nil
        guard !failed, frames > 0 else { delete(); return nil }
        return start
    }
    func delete() {
        file = nil; failed = true
        try? FileManager.default.removeItem(at: url)
    }

    private func convert(_ chunk: AudioChunk) throws -> AVAudioPCMBuffer {
        if chunk.sampleRate != inputRate {
            inputRate = chunk.sampleRate
            converter = AVAudioConverter(from: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false)!, to: format)
        }
        guard let converter, let input = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(chunk.samples.count)) else {
            throw NSError(domain: "lml.speakers.convert", code: 1)
        }
        input.frameLength = input.frameCapacity
        chunk.samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(ceil(Double(input.frameLength) * Self.rate / inputRate)) + 128)!
        let pending = Mutex<AVAudioPCMBuffer?>(input)
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            pending.withLock { next in
                guard let buffer = next else { status.pointee = .noDataNow; return nil }
                next = nil; status.pointee = .haveData; return buffer
            }
        }
        if let error { throw error }
        return output
    }
    private func silence(_ count: AVAudioFrameCount) throws {
        var left = count
        while left > 0 {
            let size = min(left, AVAudioFrameCount(Self.rate) * 10)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: size)!
            buffer.frameLength = size
            buffer.floatChannelData![0].update(repeating: 0, count: Int(size))
            try write(buffer); left -= size
        }
    }
    private func write(_ buffer: AVAudioPCMBuffer) throws {
        guard buffer.frameLength > 0 else { return }
        try file?.write(from: buffer)
        frames += AVAudioFramePosition(buffer.frameLength)
    }
}

enum SpeakerLabeler {
    /// Splits the recording into speaker turns. `expected`, the calendar's count of other attendees, is passed as the
    /// speaker count: without it the clustering merges similar voices. An invitee who never speaks makes it split one
    /// voice in two, so groups that sound alike are merged after.
    static func label(_ url: URL, start: Date, expected: Int?) async throws -> SpeakerTurns {
        var config = OfflineDiarizerConfig()
        if let expected, expected >= 1 { config.clustering.numSpeakers = expected }
        let manager = OfflineDiarizerManager(config: config)
        try await manager.prepareModels()
        let result = try await manager.process(url)
        let same = SpeakerTurns.merged(result.speakerDatabase ?? [:])
        return SpeakerTurns(start: start, expected: expected, segments: result.segments.map {
            (speaker: same[$0.speakerId] ?? $0.speakerId, from: Double($0.startTimeSeconds), to: Double($0.endTimeSeconds))
        })
    }
}
