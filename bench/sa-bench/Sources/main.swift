import AVFoundation
import Foundation
import Speech

// sa-bench file <wav>              offline transcription, prints JSON {text, seconds}
// sa-bench stream <wav> [<wav>...] real-time paced feed of every file concurrently, one analyzer each,
//                                  all in this process; prints one JSON line per file with latencies.
// word_final_*: per word (audioTimeRange run), wall time the final text arrived minus the word's audio end.
// visible_*: per volatile/final result, arrival minus the result's audio end (how stale the freshest text is).

func now() -> Double { Date().timeIntervalSince1970 }

final class Clock0: @unchecked Sendable {
    private let lock = NSLock()
    private var v = 0.0
    func set(_ x: Double) { lock.lock(); v = max(v, x); lock.unlock() }
    func get() -> Double { lock.lock(); defer { lock.unlock() }; return v }
}

func ensureAssets(_ t: SpeechTranscriber) async throws {
    if let req = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
        FileHandle.standardError.write("installing speech assets...\n".data(using: .utf8)!)
        try await req.downloadAndInstall()
    }
}

func locale() async throws -> Locale {
    guard let l = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else {
        throw NSError(domain: "sa-bench", code: 1, userInfo: [NSLocalizedDescriptionKey: "en-US unsupported"])
    }
    return l
}

func emit(_ obj: [String: Any]) {
    let d = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    print(String(data: d, encoding: .utf8)!)
}

func pct(_ a: [Double], _ p: Double) -> Double {
    guard !a.isEmpty else { return -1 }
    let s = a.sorted()
    return s[min(s.count - 1, Int(Double(s.count - 1) * p))]
}

func runFile(_ path: String) async throws {
    let t = SpeechTranscriber(locale: try await locale(), preset: .transcription)
    try await ensureAssets(t)
    let start = now()
    async let text = t.results.reduce(into: "") { acc, r in acc += String(r.text.characters) }
    let analyzer = SpeechAnalyzer(modules: [t])
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    if let last = try await analyzer.analyzeSequence(from: file) {
        try await analyzer.finalizeAndFinish(through: last)
    } else {
        await analyzer.cancelAndFinishNow()
    }
    let out = try await text
    let audioSeconds = Double(file.length) / file.processingFormat.sampleRate
    emit(["engine": "speechanalyzer", "mode": "file", "text": out, "seconds": now() - start, "audio_seconds": audioSeconds])
}

func streamOne(_ path: String, t0: Double) async throws -> [String: Any] {
    let t = SpeechTranscriber(locale: try await locale(), transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
    try await ensureAssets(t)
    let analyzer = SpeechAnalyzer(modules: [t])
    guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t]) else { throw NSError(domain: "sa-bench", code: 2) }
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let inFmt = file.processingFormat
    let conv = AVAudioConverter(from: inFmt, to: fmt)!
    let (seq, builder) = AsyncStream.makeStream(of: AnalyzerInput.self)
    try await analyzer.start(inputSequence: seq)
    let lastFinalEnd = Clock0()
    let collector = Task { () -> (String, [Double], [Double], [Double]) in
        var text = ""
        var wordFinal: [Double] = []
        var visible: [Double] = []
        var finalSeg: [Double] = []
        let traceDir = ProcessInfo.processInfo.environment["SA_TRACE_DIR"]
        var trace: FileHandle?
        if let traceDir {
            let p = "\(traceDir)/\((path as NSString).lastPathComponent).trace.jsonl"
            FileManager.default.createFile(atPath: p, contents: nil)
            trace = FileHandle(forWritingAtPath: p)
        }
        for try await r in t.results {
            let arrival = now() - t0
            if let trace {
                let row: [String: Any] = ["arrival": arrival, "final": r.isFinal, "start": r.range.start.seconds, "end": r.range.end.seconds, "text": String(r.text.characters)]
                trace.write(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data("\n".utf8))
            }
            visible.append(arrival - r.range.end.seconds)
            guard r.isFinal else { continue }
            lastFinalEnd.set(r.range.end.seconds)
            text += String(r.text.characters)
            finalSeg.append(arrival - r.range.end.seconds)
            for run in r.text.runs {
                guard let tr = run.audioTimeRange else { continue }
                let w = String(r.text[run.range].characters).trimmingCharacters(in: .whitespaces)
                if !w.isEmpty { wordFinal.append(arrival - tr.end.seconds) }
            }
        }
        return (text, wordFinal, visible, finalSeg)
    }
    let chunk = AVAudioFrameCount(inFmt.sampleRate / 10)
    var fed = 0.0
    let forceAfter = Double(ProcessInfo.processInfo.environment["SA_FORCE_FINAL_AFTER"] ?? "0") ?? 0
    var lastForce = 0.0
    while file.framePosition < file.length {
        let buf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: chunk)!
        try file.read(into: buf, frameCount: chunk)
        let ratio = fmt.sampleRate / inFmt.sampleRate
        let outBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(Double(buf.frameLength) * ratio) + 64)!
        var given = false
        var err: NSError?
        conv.convert(to: outBuf, error: &err) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return buf
        }
        if let err { throw err }
        builder.yield(AnalyzerInput(buffer: outBuf))
        fed += Double(buf.frameLength) / inFmt.sampleRate
        if forceAfter > 0, fed - lastFinalEnd.get() > forceAfter, fed - lastForce > forceAfter {
            lastForce = fed
            try await analyzer.finalize(through: CMTime(seconds: fed - 0.3, preferredTimescale: 1000))
        }
        let wait = (t0 + fed) - now()
        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
    }
    builder.finish()
    try await analyzer.finalizeAndFinishThroughEndOfInput()
    let (text, wordFinal, visible, finalSeg) = try await collector.value
    return [
        "engine": "speechanalyzer", "mode": "stream", "file": (path as NSString).lastPathComponent, "text": text,
        "final_count": finalSeg.count, "final_p50": pct(finalSeg, 0.5), "final_p95": pct(finalSeg, 0.95),
        "word_count": wordFinal.count, "word_final_p50": pct(wordFinal, 0.5), "word_final_p95": pct(wordFinal, 0.95), "word_final_max": pct(wordFinal, 1.0),
        "visible_count": visible.count, "visible_p50": pct(visible, 0.5), "visible_p95": pct(visible, 0.95),
        "wall_seconds": now() - t0,
    ]
}

func runStream(_ paths: [String]) async throws {
    let t0 = now()
    let n = paths.count
    try await withThrowingTaskGroup(of: String.self) { g in
        for p in paths {
            g.addTask {
                var r = try await streamOne(p, t0: t0)
                r["concurrent"] = n
                return String(data: try JSONSerialization.data(withJSONObject: r, options: [.sortedKeys]), encoding: .utf8)!
            }
        }
        for try await line in g { print(line) }
    }
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: sa-bench file <wav> | sa-bench stream <wav> [<wav>...]\n".data(using: .utf8)!)
    exit(2)
}
do {
    if args[1] == "file" { try await runFile(args[2]) } else { try await runStream(Array(args[2...])) }
} catch {
    FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
    exit(1)
}
