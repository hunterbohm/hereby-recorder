import Foundation
import Synchronization

/// The runtime publishes into this store; the panel observes it (PLAN.md contract C7).
public final class RecorderStore: RecorderModel {
    private struct State {
        var snapshot: RecorderSnapshot
        var handlers: [@Sendable (RecorderSnapshot) -> Void] = []
    }
    private let state: Mutex<State>
    public init(_ snapshot: RecorderSnapshot = RecorderSnapshot()) { state = Mutex(State(snapshot: snapshot)) }
    public var snapshot: RecorderSnapshot { state.withLock { $0.snapshot } }
    public func observe(_ handler: @escaping @Sendable (RecorderSnapshot) -> Void) {
        let current = state.withLock { state in state.handlers.append(handler); return state.snapshot }
        handler(current)
    }
    public func update(_ change: (inout RecorderSnapshot) -> Void) {
        let delivery: (RecorderSnapshot, [@Sendable (RecorderSnapshot) -> Void])? = state.withLock { state in
            var next = state.snapshot
            change(&next)
            guard next != state.snapshot else { return nil }
            state.snapshot = next
            return (next, state.handlers)
        }
        guard let (snapshot, handlers) = delivery else { return }
        for handler in handlers { handler(snapshot) }
    }
}

public extension RecorderSnapshot {
    static let lineLimit = 400

    /// Names a capture after the feed's meeting while it is underway (2 min before its start to its end, or an hour
    /// without an end): its title, its start, and the other person on a 1:1.
    mutating func match(_ meeting: PanelMeeting?, at now: Date) {
        guard phase != .idle, phase != .paused, let meeting, now >= meeting.start.addingTimeInterval(-120),
              now <= (meeting.end ?? meeting.start.addingTimeInterval(3600)) else { return }
        title = meeting.title; eventStart = meeting.start; themName = meeting.with
    }
}

public struct RecorderError: Error, Equatable, Sendable {
    public let reply: String
    public init(reply: String) { self.reply = reply }
}

/// Panel actions over the recorder's control socket; Ask goes to the mini (PLAN.md contract C5).
public struct ControlActions: RecorderActions {
    public static let askTimeout: TimeInterval = 120
    public static let liveAskTimeout: TimeInterval = 30
    public static let liveLines = 40
    public static let hermesTimeout: TimeInterval = 20
    private let paths: SessionPaths
    private let mini: Mini?
    private let runner: any ProcessRunner
    private let screenContext: Bool
    private let grab: @Sendable (_ ask: Bool) async -> String?
    /// `screenContext` sends the screen with every live question; Read screen always sends it.
    public init(paths: SessionPaths, mini: Mini?, runner: any ProcessRunner = LocalProcessRunner(), screenContext: Bool = false,
                grab: @escaping @Sendable (_ ask: Bool) async -> String? = { await ScreenGrab.jpegBase64(ask: $0) }) {
        self.paths = paths; self.mini = mini; self.runner = runner; self.screenContext = screenContext; self.grab = grab
    }
    private func send(_ command: ControlCommand, expect: String) async throws {
        let reply = try await ControlClient.request(command, root: paths.root)
        guard reply == expect else { throw RecorderError(reply: reply) }
    }
    public func pause() async throws { try await send(ControlCommand(action: .pause), expect: "pause") }
    public func resume() async throws { try await send(ControlCommand(action: .resume), expect: "resume") }
    public func stop() async throws { try await send(ControlCommand(action: .stop), expect: "stop") }
    public func forget(sid: String) async throws {
        guard SessionPaths.validID(sid) else { throw CocoaError(.fileReadInvalidFileName) }
        try await send(ControlCommand(action: .forget, sid: sid), expect: "forgotten")
    }
    public func markMoment(note: String?) async throws { try await send(ControlCommand(action: .mark, note: note), expect: "mark") }
    public func startInPerson() async throws { try await send(ControlCommand(action: .start, kind: .inPerson), expect: "start") }
    public func ask(_ question: String) async throws -> String { try await ask(question, arguments: []) }
    public func askAnyMeeting(_ question: String) async throws -> String { try await ask(question, arguments: ["--any"]) }
    public func askLive(_ request: LiveAskRequest, onText: @escaping @Sendable (String) -> Void) async throws -> String {
        guard let mini else { throw RecorderError(reply: "no_mini") }
        var trimmed = request
        trimmed.lines = Array(request.lines.suffix(Self.liveLines))
        if request.kind == .screen || screenContext { trimmed.screen = await grab(request.kind == .screen) }
        if request.kind == .screen, trimmed.screen == nil { throw RecorderError(reply: "no_screen") }
        let input = try JSON.encoder().encode(trimmed)
        let command = Outbox.remoteCommand(paths: paths, mini: mini, "live-meeting-quick", [], input: input, timeout: Self.liveAskTimeout)
        let reader = LiveAnswerReader()
        let output = try await runner.stream(command) { piece in
            if let text = reader.feed(piece) { onText(text) }
        }
        return try reader.finish(status: output.status)
    }
    public func hermesOptIn(key: String) async throws { try await meetingBot(["optin", key], reply: "hermes_optin_failed") }
    public func hermesOptOut(key: String) async throws { try await meetingBot(["optout", key], reply: "hermes_optout_failed") }
    public func hermesChat(key: String, on: Bool) async throws {
        try await meetingBot(["chat", key, on ? "on" : "off"], reply: "hermes_chat_failed")
    }
    /// `meeting-bot` on the mini prints one JSON object and exits 0, or exits nonzero with a reason on stderr.
    private func meetingBot(_ arguments: [String], reply: String) async throws {
        guard let mini else { throw RecorderError(reply: "no_mini") }
        let command = Outbox.remoteCommand(paths: paths, mini: mini, "meeting-bot", arguments.map(Self.shellQuoted), timeout: Self.hermesTimeout)
        let output = try await runner.run(command)
        guard output.status == 0 else { throw RecorderError(reply: "\(reply) status=\(output.status)") }
    }
    /// The mini's shell reads ssh's arguments again, and an event key is calendar data: quote what isn't plainly safe.
    static func shellQuoted(_ argument: String) -> String {
        let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._@:=+,/-")
        if !argument.isEmpty, argument.allSatisfy({ safe.contains($0) }) { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    private func ask(_ question: String, arguments: [String]) async throws -> String {
        guard let mini else { throw RecorderError(reply: "no_mini") }
        let command = Outbox.remoteCommand(paths: paths, mini: mini, "live-meeting-ask", arguments, input: Data(question.utf8), timeout: Self.askTimeout)
        let output = try await runner.run(command)
        guard output.status == 0 else { throw RecorderError(reply: "ask_failed status=\(output.status)") }
        return String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Reads `live-meeting-quick` output: one JSON object per line, `{"d": text}` pieces, then `{"done": true}` or
/// `{"error": reason}`. Pieces can split a line anywhere, so it buffers to the newline.
final class LiveAnswerReader: Sendable {
    private struct State {
        var buffer = Data()
        var text = ""
        var done = false
        var error: String?
    }
    private struct Line: Decodable {
        var d: String?
        var done: Bool?
        var error: String?
    }
    private let state = Mutex(State())

    /// The answer so far when this piece added to it, else nil.
    func feed(_ piece: Data) -> String? {
        state.withLock { state in
            state.buffer.append(piece)
            var grew = false
            while let newline = state.buffer.firstIndex(of: 0x0A) {
                let line = state.buffer[state.buffer.startIndex..<newline]
                state.buffer.removeSubrange(state.buffer.startIndex...newline)
                guard let parsed = try? JSONDecoder().decode(Line.self, from: line) else { continue }
                if let d = parsed.d, !state.done { state.text += d; grew = true }
                if parsed.done == true { state.done = true }
                if let error = parsed.error { state.error = error }
            }
            return grew ? state.text : nil
        }
    }

    func finish(status: Int32) throws -> String {
        try state.withLock { state in
            let text = state.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard status == 0, state.done, state.error == nil, !text.isEmpty else {
                throw RecorderError(reply: "live_ask_failed status=\(status) error=\(state.error ?? "none")")
            }
            return text
        }
    }
}
