import AVFoundation
import Speech
import Synchronization
import LMLCore

protocol Transcriber: Sendable {
    func run(_ chunks: AsyncStream<CaptureEvent>) async throws
}

actor AppleTranscriber: Transcriber {
    let channel: Channel
    let writer: SessionWriter
    let printFinals: Bool
    let downloadAssets: Bool
    private var vocabulary: [String]
    init(channel: Channel, writer: SessionWriter, printFinals: Bool = false, downloadAssets: Bool = true, vocabulary: [String] = []) {
        self.channel = channel; self.writer = writer; self.printFinals = printFinals; self.downloadAssets = downloadAssets
        self.vocabulary = vocabulary
    }
    func run(_ events: AsyncStream<CaptureEvent>) async throws {
        var segmenter = RunSegmenter()
        var run: AnalyzerRun?
        do {
            for await event in events {
                try Task.checkCancellation()
                switch event {
                case .context(let terms):
                    vocabulary = terms
                    try await run?.setVocabulary(terms)
                case .endRun:
                    try await run?.finish()
                    run = nil; segmenter.end()
                    await writer.endRun(channel: channel)
                case .chunk(let chunk):
                    guard !chunk.samples.isEmpty, chunk.sampleRate > 0 else { continue }
                    if segmenter.accept(at: chunk.at, duration: chunk.duration, source: chunk.runID) {
                        try await run?.finish()
                        run = nil
                        await writer.beginRun(at: chunk.at, channel: channel)
                        run = try await AnalyzerRun(channel: channel, writer: writer, anchor: chunk.at, printFinals: printFinals, downloadAssets: downloadAssets, vocabulary: vocabulary)
                    }
                    try await run?.feed(chunk)
                }
            }
            try Task.checkCancellation()
            try await run?.finish()
            await writer.endRun(channel: channel)
        } catch {
            await run?.cancel()
            throw error
        }
    }
}

private actor AnalyzerRun {
    private let analyzer: SpeechAnalyzer
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let collector: Task<Void, Error>
    private let format: AVAudioFormat
    private let anchor: Date
    private var converter: AVAudioConverter?
    private var rate = 0.0; private var nextStart: CMTime?

    init(channel: Channel, writer: SessionWriter, anchor: Date, printFinals: Bool, downloadAssets: Bool, vocabulary: [String]) async throws {
        self.anchor = anchor
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_US")) else {
            throw NSError(domain: "lml.asr.locale", code: 1)
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            guard downloadAssets else { throw NSError(domain: "lml.asr.assets_not_installed", code: 1) }
            try await request.downloadAndInstall()
        }
        try Task.checkCancellation()
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { throw NSError(domain: "lml.asr.format", code: 1) }
        self.format = format
        analyzer = SpeechAnalyzer(modules: [transcriber])
        if !vocabulary.isEmpty { try await analyzer.setContext(Self.context(vocabulary)) }
        let (inputs, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.continuation = continuation
        try await analyzer.start(inputSequence: inputs)
        collector = Task {
            for try await result in transcriber.results {
                let runs = result.text.runs
                let words = runs.compactMap { run -> Word? in
                    guard let time = run.audioTimeRange else { return nil }
                    return Word(start: time.start.seconds, end: time.end.seconds, text: String(result.text[run.range].characters))
                }
                let recognition = Recognition(ch: channel, start: result.range.start.seconds, end: result.range.end.seconds,
                    words: words, final: result.isFinal,
                    text: String(result.text.characters), anchor: anchor)
                if let row = try await writer.receive(recognition), result.isFinal, printFinals {
                    FileHandle.standardOutput.write(try JSON.encoder().encode(row) + Data("\n".utf8))
                }
            }
        }
    }
    private static func context(_ vocabulary: [String]) -> AnalysisContext {
        let context = AnalysisContext()
        context.contextualStrings[.general] = vocabulary
        return context
    }
    func setVocabulary(_ vocabulary: [String]) async throws { try await analyzer.setContext(Self.context(vocabulary)) }
    func feed(_ chunk: AudioChunk) throws {
        if chunk.sampleRate != rate {
            rate = chunk.sampleRate
            let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
            converter = AVAudioConverter(from: inputFormat, to: format)
        }
        guard let converter, let buffer = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(chunk.samples.count)) else {
            throw NSError(domain: "lml.asr.convert", code: 1)
        }
        buffer.frameLength = buffer.frameCapacity
        chunk.samples.withUnsafeBufferPointer { samples in buffer.floatChannelData![0].update(from: samples.baseAddress!, count: samples.count) }
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * format.sampleRate / rate)) + 128
        let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)!
        let input = Mutex<AVAudioPCMBuffer?>(buffer)
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            input.withLock { available in
                guard let next = available else { status.pointee = .noDataNow; return nil }
                available = nil; status.pointee = .haveData; return next
            }
        }
        if let error { throw error }
        guard converted.frameLength > 0 else { return }; let start = nextStart ?? CMTime(seconds: max(0, chunk.at.timeIntervalSince(anchor)), preferredTimescale: 1_000_000); continuation.yield(AnalyzerInput(buffer: converted, bufferStartTime: start)); nextStart = start + CMTime(value: CMTimeValue(converted.frameLength), timescale: CMTimeScale(format.sampleRate))
    }
    func finish() async throws {
        continuation.finish()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            try await collector.value
        } onCancel: {
            Task { await self.cancel() }
        }
    }
    func cancel() async {
        continuation.finish(); await analyzer.cancelAndFinishNow(); collector.cancel()
        _ = await collector.result
    }
}

func injectFile(_ path: String, clock: CaptureClock, sink: @escaping @Sendable (AudioChunk) -> Void) async throws {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let format = file.processingFormat
    guard format.commonFormat == .pcmFormatFloat32 else { throw NSError(domain: "lml.file.format", code: 1) }
    let frames = AVAudioFrameCount(max(1, format.sampleRate / 10))
    var fed = 0.0
    let runID = UUID()
    while file.framePosition < file.length {
        try Task.checkCancellation()
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        try file.read(into: buffer, frameCount: frames)
        guard let channels = buffer.floatChannelData else { throw NSError(domain: "lml.file.samples", code: 1) }
        let count = Int(buffer.frameLength), channelCount = Int(format.channelCount)
        var samples = [Float](repeating: 0, count: count)
        for frame in 0..<count {
            for channel in 0..<channelCount { samples[frame] += format.isInterleaved ? channels[0][frame * channelCount + channel] : channels[channel][frame] }
            samples[frame] /= Float(channelCount)
        }
        sink(AudioChunk(samples: samples, sampleRate: format.sampleRate, at: clock.wall.addingTimeInterval(fed), runID: runID))
        fed += Double(count) / format.sampleRate
        let delay = clock.wall.addingTimeInterval(fed).timeIntervalSinceNow
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
    }
}
