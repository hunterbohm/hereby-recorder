import Foundation

public actor SessionWriter {
    public nonisolated let sid: String
    public nonisolated let kind: CaptureKind
    private let directory: URL?
    private var persisted = false
    private var discarded = false
    private var anchors: [Channel: Date] = [:]
    private var finals: [TranscriptRow] = []
    private var bufferedFinals: [TranscriptRow] = []
    private var partialResults: [Channel: Recognition] = [:]
    private var lastFinalEnd: [Channel: Date] = [:]
    private var rings: [Channel: EnergyRing]
    private var activity: Date
    private var markTimes: [Date] = []
    private var lines: [TranscriptLine] = []
    private var schedule: Schedule?
    private var sequence = 0
    private var meta: SessionMeta
    private var lastPublish: Date?
    private var lastHeartbeat: Date?
    public init(sid: String, startedAt: Date, directory: URL?, test: Bool = false, kind: CaptureKind = .call) {
        self.sid = sid; self.kind = kind; self.directory = directory; meta = SessionMeta(sid: sid, started_at: startedAt, test: test, kind: kind)
        rings = Dictionary(uniqueKeysWithValues: Channel.channels(for: kind).map { ($0, EnergyRing()) })
        activity = startedAt
    }
    public func setAnchor(_ anchor: Date, channel: Channel) { if anchors[channel] == nil { anchors[channel] = anchor } }
    public func beginRun(at anchor: Date, channel: Channel) {
        anchors[channel] = anchor; partialResults[channel] = nil
    }
    public func endRun(channel: Channel) { partialResults[channel] = nil }
    public func anchor(for channel: Channel) -> Date? { anchors[channel] }
    public func setSchedule(_ schedule: Schedule?) { self.schedule = schedule }
    public func setContext(apps: [String], calKeys: [String], micOpen: Bool, silent: Bool) {
        meta.apps = Array(Set(meta.apps + apps)).sorted()
        meta.cal_keys = Array(Set(meta.cal_keys + calKeys)).sorted()
        if meta.kind == .call && (micOpen || meta.me != "on") { meta.me = micOpen ? "on" : "off (no other input client)" }
        meta.warnings = silent ? ["them_silent"] : []
    }
    public func addEnergy(channel: Channel, samples: [Float], sampleRate: Double, at start: Date) {
        rings[channel, default: EnergyRing()].add(samples: samples, sampleRate: sampleRate, at: start)
    }
    public func setEnergy(_ ring: EnergyRing, channel: Channel) { rings[channel] = ring }
    public func activate(at now: Date) throws {
        guard !discarded, !persisted, let directory else { return }
        try PrivateFiles.directory(directory)
        try PrivateFiles.write(Data(), to: directory.appendingPathComponent("transcript.jsonl"))
        for row in bufferedFinals { try append(row) }
        bufferedFinals.removeAll()
        persisted = true
        activity = max(activity, now)
        try publish(at: now, force: true)
    }
    /// Appends a marked moment to `marks.jsonl` and returns the session's mark count.
    public func mark(note: String?, at now: Date) throws -> Int {
        guard !discarded, persisted, meta.state == .active, let directory else { throw CocoaError(.fileWriteNoPermission) }
        let url = directory.appendingPathComponent("marks.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) { try PrivateFiles.write(Data(), to: url) }
        let handle = try FileHandle(forWritingTo: url)
        do {
            try handle.seekToEnd(); try handle.write(contentsOf: Mark(at: now, note: note).line()); try handle.synchronize(); try handle.close()
        } catch { try? handle.close(); throw error }
        markTimes.append(now)
        return markTimes.count
    }
    public func markCount() -> Int { markTimes.count }
    public func marks() -> [Date] { markTimes }
    /// Seconds since the last final transcript row, or since activation when nothing was said.
    public func silence(at now: Date) -> TimeInterval { now.timeIntervalSince(activity) }
    public func isPersisted() -> Bool { persisted }
    /// The session's last `RecorderSnapshot.lineLimit` final lines, oldest first. Returned without copying.
    public func transcriptLines() -> [TranscriptLine] { lines }
    @discardableResult public func receive(_ result: Recognition) throws -> TranscriptRow? {
        guard !discarded, let row = makeRow(result) else { return nil }
        if result.final {
            if result.ch == .me && isEcho(row) {
                lastFinalEnd[.me] = max(lastFinalEnd[.me] ?? row.ts1, row.ts1)
                return nil
            }
            sequence += 1
            var final = row; final.seq = sequence
            if persisted { try append(final) } else { bufferedFinals.append(final) }
            finals.append(final); meta.segments += 1
            addLine(final)
            recordFinalSpeech(from: final.ts0, to: final.ts1)
            lastFinalEnd[result.ch] = max(lastFinalEnd[result.ch] ?? final.ts1, final.ts1)
            activity = max(activity, final.ts1)
            if result.ch == .them { retractEchoLines(near: final) }
            return final
        }
        partialResults[result.ch] = result
        return row
    }
    private func isEcho(_ row: TranscriptRow) -> Bool {
        let window = EchoGate.tolerance
        let calls = finals.filter { $0.ch == .them && $0.ts1 > row.ts0.addingTimeInterval(-window) && $0.ts0 < row.ts1.addingTimeInterval(window) }
            + [partialResults[.them].flatMap(makeRow)].compactMap { $0 }
        return EchoGate.isEcho(row, of: calls)
    }
    /// A call final can land after the mic final that echoes it. The panel drops that line; the file keeps it for the mini's pass.
    private func retractEchoLines(near call: TranscriptRow) {
        let window = EchoGate.tolerance
        for row in finals where row.ch == .me && row.ts1 > call.ts0.addingTimeInterval(-window) && row.ts0 < call.ts1.addingTimeInterval(window) && isEcho(row) {
            if let index = lines.firstIndex(where: { $0.speaker == "me" && $0.at == row.ts0 && $0.text == row.text }) { lines.remove(at: index) }
        }
    }
    private func addLine(_ row: TranscriptRow) {
        let line = TranscriptLine(speaker: row.ch.rawValue, text: row.text, at: row.ts0)
        let index = lines.lastIndex { $0.at <= line.at }.map { $0 + 1 } ?? 0
        lines.insert(line, at: index)
        if lines.count > RecorderSnapshot.lineLimit { lines.removeFirst(lines.count - RecorderSnapshot.lineLimit) }
    }
    private func makeRow(_ result: Recognition) -> TranscriptRow? {
        guard let anchor = result.anchor ?? anchors[result.ch] else { return nil }
        let cutoff = lastFinalEnd[result.ch] ?? .distantPast
        let words = result.words.compactMap { word -> Word? in
            guard anchor.addingTimeInterval(word.end) > cutoff else { return nil }
            var word = word; word.start = max(word.start, cutoff.timeIntervalSince(anchor)); return word
        }
        let boundaries = schedule?.isFresh(at: result.at) == true ? schedule!.windowStarts : []
        let other = result.ch.other.flatMap { rings[$0] } ?? EnergyRing()
        let t0 = max(anchor.addingTimeInterval(result.start), cutoff)
        let t1 = anchor.addingTimeInterval(result.end)
        guard t1 > t0 else { return nil }
        let parts: [TranscriptPart]
        if result.words.isEmpty {
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            parts = [TranscriptPart(t0: t0, t1: t1, text: text, xo: other.overlap(from: t0, to: t1))]
        } else {
            parts = PartSplitter.split(words: words, anchor: anchor, other: other, boundaries: boundaries)
        }
        guard !parts.isEmpty else { return nil }
        return TranscriptRow(ch: result.ch, ts0: t0, ts1: t1, at: result.at, text: parts.map(\.text).joined(separator: " "), xo: other.overlap(from: t0, to: t1), parts: parts)
    }
    private func append(_ row: TranscriptRow) throws {
        guard let directory else { return }
        let handle = try FileHandle(forWritingTo: directory.appendingPathComponent("transcript.jsonl"))
        do {
            try handle.seekToEnd(); try handle.write(contentsOf: JSON.encoder().encode(row) + Data("\n".utf8)); try handle.synchronize(); try handle.close()
        } catch { try? handle.close(); throw error }
    }
    public func snapshot(at now: Date) -> LiveSnapshot {
        let since = now.addingTimeInterval(-900)
        let visible = finals.filter { $0.ts1 >= since }
        var partials: [String: TranscriptRow?] = [:]
        var speech: [String: [[Date]]] = [:]
        for channel in Channel.channels(for: meta.kind) {
            partials[channel.rawValue] = .some(partialResults[channel].flatMap(makeRow).flatMap { $0.ts1 >= since ? $0 : nil })
            speech[channel.rawValue] = (rings[channel] ?? EnergyRing()).intervals(since: since, through: now)
        }
        return LiveSnapshot(sid: sid, at: now, seq_hi: visible.compactMap(\.seq).max() ?? 0, finals: visible, partials: partials, speech: speech)
    }
    public func publish(at now: Date, force: Bool = false) throws {
        guard !discarded, persisted, let directory else { return }
        if force || lastPublish == nil || now.timeIntervalSince(lastPublish!) >= 1 {
            var live = snapshot(at: now)
            live.finals = []
            try PrivateFiles.write(live, to: directory.appendingPathComponent("live.json")); lastPublish = now
            finals.removeAll { $0.ts1 < now.addingTimeInterval(-1800) }
        }
        if force || lastHeartbeat == nil || now.timeIntervalSince(lastHeartbeat!) >= 5 {
            if meta.state == .active { meta.heartbeat_at = now }
            meta.version += 1
            try PrivateFiles.write(meta, to: directory.appendingPathComponent("meta.json")); lastHeartbeat = now
        }
    }
    public func saveSpeakers(_ turns: SpeakerTurns) throws {
        guard !discarded, persisted, let directory else { return }
        try PrivateFiles.write(turns, to: directory.appendingPathComponent(SyncFile.speakers.rawValue))
    }
    public func discard() {
        discarded = true; persisted = false; bufferedFinals.removeAll(); partialResults.removeAll(); finals.removeAll(); lines.removeAll()
    }
    public func close(at now: Date) throws {
        meta.state = .closed; meta.ended_at = now
        try publish(at: now, force: true)
    }
    public func fail(at now: Date) throws {
        meta.state = .failed; meta.ended_at = now
        defer { discard() }
        try publish(at: now, force: true)
    }
    public func metadata() -> SessionMeta { meta }
    public func shouldDiscardShortSession() -> Bool {
        guard !meta.test && meta.cal_keys.isEmpty else { return false }
        return finalDuration < 60
    }
    private var finalDuration: Double = 0
    private var finalSpans: [(Date, Date)] = []
    private func recordFinalSpeech(from start: Date, to end: Date) {
        finalSpans.append((start, end)); finalSpans.sort { $0.0 < $1.0 }
        var merged: [(Date, Date)] = []
        for span in finalSpans {
            if let last = merged.last, span.0 <= last.1 { merged[merged.count - 1].1 = max(last.1, span.1) }
            else { merged.append(span) }
        }
        finalSpans = merged; finalDuration = merged.reduce(0) { $0 + $1.1.timeIntervalSince($1.0) }
    }
}
