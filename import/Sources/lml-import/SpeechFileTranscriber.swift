import AVFoundation
import Speech
import ImportCore

/// Transcribes audio files on device with SpeechAnalyzer. Decodes through AVAssetReader only, so nothing plays.
struct SpeechFileTranscriber: AudioTranscriber {
    func transcribe(_ plan: AudioPlan) async throws -> [Utterance] {
        switch plan {
        case .tracks(let url, let speakers):
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard tracks.count == speakers.count else { throw ImportError.trackCount(expected: speakers.count, found: tracks.count) }
            var utterances: [Utterance] = []
            for (track, speaker) in zip(tracks, speakers) {
                utterances += try await Self.transcribe(asset: asset, speaker: speaker) { settings in
                    AVAssetReaderTrackOutput(track: track, outputSettings: settings)
                }
            }
            return utterances
        case .mixed(let url):
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard !tracks.isEmpty else { throw ImportError.trackCount(expected: 1, found: 0) }
            return try await Self.transcribe(asset: asset, speaker: .call) { settings in
                AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
            }
        }
    }

    private static func transcribe(asset: AVURLAsset, speaker: Speaker, output: ([String: Any]) -> AVAssetReaderOutput) async throws -> [Utterance] {
        // AssetInventory.status reports .supported to a client that never reserved the locale, even though the
        // system model is installed and the analyzer runs. Check system-wide installed locales; never download.
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_US")),
              await SpeechTranscriber.installedLocales.contains(where: { $0.identifier == locale.identifier }) else {
            throw ImportError.assetsNotInstalled
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw ImportError.unsupportedAudioFormat
        }
        let feed = try PCMFeed(asset: asset, format: format, output: output)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task {
            var utterances: [Utterance] = []
            for try await result in transcriber.results where result.isFinal {
                let words = result.text.runs.compactMap { run -> Word? in
                    guard let range = run.audioTimeRange else { return nil }
                    return Word(start: range.start.seconds, end: range.end.seconds, text: String(result.text[run.range].characters))
                }
                utterances.append(Utterance(speaker: speaker, words: words.isEmpty
                    ? [Word(start: result.range.start.seconds, end: result.range.end.seconds, text: String(result.text.characters))]
                    : words))
            }
            return utterances
        }
        do {
            try await analyzer.start(inputSequence: AsyncStream(unfolding: { feed.next() }))
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            collector.cancel()
            throw error
        }
        let utterances = try await collector.value
        if let failure = feed.failure { throw failure }
        return utterances
    }
}

/// Pulls PCM buffers from the asset reader only as fast as the analyzer consumes them.
private final class PCMFeed: @unchecked Sendable {
    private let reader: AVAssetReader
    private let output: AVAssetReaderOutput
    private let format: AVAudioFormat
    private var frames: AVAudioFramePosition = 0
    private(set) var failure: Error?

    init(asset: AVURLAsset, format: AVAudioFormat, output make: ([String: Any]) -> AVAssetReaderOutput) throws {
        let bits: Int, float: Bool
        switch format.commonFormat {
        case .pcmFormatInt16: (bits, float) = (16, false)
        case .pcmFormatInt32: (bits, float) = (32, false)
        case .pcmFormatFloat32: (bits, float) = (32, true)
        default: throw ImportError.unsupportedAudioFormat
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: bits, AVLinearPCMIsFloatKey: float, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: !format.isInterleaved
        ]
        reader = try AVAssetReader(asset: asset)
        output = make(settings)
        guard reader.canAdd(output) else { throw ImportError.unreadableAudio }
        reader.add(output)
        self.format = format
        guard reader.startReading() else { throw reader.error ?? ImportError.unreadableAudio }
    }

    func next() -> AnalyzerInput? {
        guard failure == nil else { return nil }
        while let sample = output.copyNextSampleBuffer() {
            let count = CMSampleBufferGetNumSamples(sample)
            guard count > 0 else { continue }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
                failure = ImportError.unreadableAudio; return nil
            }
            buffer.frameLength = AVAudioFrameCount(count)
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(count), into: buffer.mutableAudioBufferList)
            guard status == noErr else { failure = NSError(domain: NSOSStatusErrorDomain, code: Int(status)); return nil }
            let stamp = CMSampleBufferGetPresentationTimeStamp(sample)
            let start = stamp.isNumeric ? stamp : CMTime(value: frames, timescale: CMTimeScale(format.sampleRate))
            let input = AnalyzerInput(buffer: buffer, bufferStartTime: start)
            frames += AVAudioFramePosition(count)
            return input
        }
        if reader.status == .failed { failure = reader.error ?? ImportError.unreadableAudio }
        return nil
    }
}
