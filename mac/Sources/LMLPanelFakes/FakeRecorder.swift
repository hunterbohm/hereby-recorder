import Foundation
import Synchronization
import LMLCore

public struct FakeFailure: Error {}

public final class FakeRecorder: RecorderModel, RecorderActions {
    public enum Call: Equatable, Sendable {
        case pause, resume, stop, startInPerson
        case forget(String)
        case markMoment(String?)
        case ask(String)
        case askLive(QuickAsk, String)
        case askAny(String)
        case hermesOptIn(String)
        case hermesOptOut(String)
        case hermesChat(String, Bool)
    }

    private struct State {
        var snapshot: RecorderSnapshot
        var handlers: [@Sendable (RecorderSnapshot) -> Void] = []
        var calls: [Call] = []
        var failing = false
        var answer = "Dana said the Poland decision waits on the SOP library audit."
        var anyAnswer = "Last call with Dana covered the SOP library and Poland. You owe him 2 tasks."
        var holding = false
        var liveFailing = false
        var liveError: RecorderError?
        var liveCutOff = false
        var lastLive: LiveAskRequest?
        var held: [CheckedContinuation<Void, Never>] = []
    }

    private let state: Mutex<State>

    public init(_ snapshot: RecorderSnapshot = RecorderSnapshot()) {
        state = Mutex(State(snapshot: snapshot))
    }

    public var snapshot: RecorderSnapshot { state.withLock { $0.snapshot } }
    public var calls: [Call] { state.withLock { $0.calls } }

    public func observe(_ handler: @escaping @Sendable (RecorderSnapshot) -> Void) {
        let current = state.withLock { state in
            state.handlers.append(handler)
            return state.snapshot
        }
        handler(current)
    }

    public func publish(_ snapshot: RecorderSnapshot) {
        let handlers = state.withLock { state in
            state.snapshot = snapshot
            return state.handlers
        }
        handlers.forEach { $0(snapshot) }
    }

    public func failCalls(_ failing: Bool) { state.withLock { $0.failing = failing } }
    public func answer(with text: String) { state.withLock { $0.answer = text } }
    public func answerAny(with text: String) { state.withLock { $0.anyAnswer = text } }
    /// The fast answer fails before any text, so the store falls back to `ask`.
    public func failLive(_ failing: Bool) { state.withLock { $0.liveFailing = failing } }
    /// The next fast answers fail with this recorder error, like `no_screen` when Read screen has no picture.
    public func failLive(with error: RecorderError?) { state.withLock { $0.liveError = error } }
    /// The fast answer sends its first half, then fails.
    public func cutLiveOff(_ cut: Bool) { state.withLock { $0.liveCutOff = cut } }
    public func hold() { state.withLock { $0.holding = true } }

    public func release() {
        let held = state.withLock { state in
            state.holding = false
            defer { state.held = [] }
            return state.held
        }
        held.forEach { $0.resume() }
    }

    public func pause() async throws { try await enter(.pause) }
    public func resume() async throws { try await enter(.resume) }
    public func stop() async throws { try await enter(.stop) }
    public func forget(sid: String) async throws { try await enter(.forget(sid)) }
    public func markMoment(note: String?) async throws { try await enter(.markMoment(note)) }
    public func startInPerson() async throws { try await enter(.startInPerson) }

    public func ask(_ question: String) async throws -> String {
        try await enter(.ask(question))
        return state.withLock { $0.answer }
    }

    public var lastLiveRequest: LiveAskRequest? { state.withLock { $0.lastLive } }

    public func askLive(_ request: LiveAskRequest, onText: @escaping @Sendable (String) -> Void) async throws -> String {
        state.withLock { $0.lastLive = request }
        let (answer, failing, cut) = state.withLock { state in
            state.calls.append(.askLive(request.kind, request.question))
            return (state.answer, state.liveFailing || state.failing, state.liveCutOff)
        }
        if let error = state.withLock({ $0.liveError }) { throw error }
        if failing { throw FakeFailure() }
        let words = answer.split(separator: " ").map(String.init)
        let sent = cut ? Array(words.prefix(max(1, words.count / 2))) : words
        for count in 1...sent.count { onText(sent.prefix(count).joined(separator: " ")) }
        try await enter(.askLive(request.kind, request.question), record: false)
        if cut { throw FakeFailure() }
        return answer
    }

    public func askAnyMeeting(_ question: String) async throws -> String {
        try await enter(.askAny(question))
        return state.withLock { $0.anyAnswer }
    }

    public func hermesOptIn(key: String) async throws { try await enter(.hermesOptIn(key)) }
    public func hermesOptOut(key: String) async throws { try await enter(.hermesOptOut(key)) }
    public func hermesChat(key: String, on: Bool) async throws { try await enter(.hermesChat(key, on)) }

    private func enter(_ call: Call, record: Bool = true) async throws {
        let holding = state.withLock { state in
            if record { state.calls.append(call) }
            return state.holding
        }
        if holding {
            await withCheckedContinuation { continuation in
                let stillHolding = state.withLock { state in
                    if state.holding { state.held.append(continuation) }
                    return state.holding
                }
                if !stillHolding { continuation.resume() }
            }
        }
        if state.withLock({ $0.failing }) { throw FakeFailure() }
    }
}
