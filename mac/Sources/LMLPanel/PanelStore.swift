import Foundation
import Observation
import Synchronization
import SwiftUI
import LMLCore

public enum PanelAction: Equatable, Sendable {
    case pause, resume, stop, startInPerson
    case notAMeeting(sid: String)
    case forget(sid: String)
    /// A change to Hermes for one calendar event. `PanelStore.setHermes` shows it at once and undoes it on failure.
    case hermes(key: String, change: HermesChange)

    public var needsConfirmation: Bool {
        switch self {
        case .notAMeeting, .forget: true
        case .pause, .resume, .stop, .startInPerson, .hermes: false
        }
    }
}

public enum ActionPhase: Equatable, Sendable {
    case idle
    case confirming(PanelAction)
    case running(PanelAction)
    case failed(PanelAction)
}

@MainActor @Observable
public final class PanelStore {
    public private(set) var snapshot: RecorderSnapshot
    public private(set) var now: Date
    public private(set) var action: ActionPhase = .idle
    public private(set) var memory: SessionMemory?
    public private(set) var anyAsk: AskEntry?
    public var askDraft = ""
    public var anyDraft = ""
    public private(set) var focus: PanelFocus = .auto
    public private(set) var forgotten: Set<String> = []
    public private(set) var flash: FlashState?
    public var shortcutAvailable = true
    /// The overlay's shortcuts as the Mac prints them, nil when off or taken by another app.
    public var overlayToggleHint: String? = "⌥\\"
    public var overlaySayHint: String? = "⌥↩"
    public var overlayStyle: OverlayStyle = .strip
    /// The user hid the overlay for this session; a new session shows it again.
    public private(set) var overlayHidden = false
    /// The top pill is opened into its full card.
    public var pillOpen = false
    public var timeZone: TimeZone = .autoupdatingCurrent
    public var locale: Locale = .autoupdatingCurrent
    /// What the user just asked of Hermes, per event key, until a newer feed from the mini says the same.
    public private(set) var hermesOverrides: [String: HermesOverride] = [:]
    /// Event keys with a Hermes command on its way to the mini; their controls wait.
    public private(set) var hermesPending: Set<String> = []

    @ObservationIgnored private var graceStart: Date
    @ObservationIgnored public let hasMini: Bool
    @ObservationIgnored private let actions: any RecorderActions
    @ObservationIgnored private let clock: @MainActor () -> Date
    @ObservationIgnored private let openURL: @MainActor (URL) -> Void
    @ObservationIgnored private let actionTimeout: Duration
    @ObservationIgnored private var actionToken: UUID?

    public init(snapshot: RecorderSnapshot, actions: any RecorderActions,
                clock: @escaping @MainActor () -> Date = { Date() },
                actionTimeout: Duration = PanelRules.actionTimeout,
                hasMini: Bool = true,
                openURL: @escaping @MainActor (URL) -> Void) {
        self.snapshot = snapshot
        self.hasMini = hasMini
        self.actions = actions
        self.clock = clock
        self.actionTimeout = actionTimeout
        self.openURL = openURL
        let start = clock()
        now = start
        graceStart = start
        remember(previous: snapshot, next: snapshot)
    }

    public var health: Health { Health.resolve(snapshot, now: now, graceStart: graceStart, hasMini: hasMini) }
    public var activeFlash: Flash? { flash?.active(at: now) }
    public var icon: StatusIcon { StatusIcon.resolve(snapshot, health: health, flash: activeFlash) }
    public var screen: PanelScreen {
        PanelScreen.resolve(snapshot, now: now, focus: focus, forgotten: forgotten, memory: memory, hasMini: hasMini)
    }
    public var isBusy: Bool { action != .idle && !isFailed }
    private var isFailed: Bool { if case .failed = action { true } else { false } }

    public func tick() {
        let subject = screen.subject
        now = clock()
        dropStaleHermes()
        settle(after: subject)
    }

    public func resetGrace() {
        graceStart = clock()
        tick()
    }

    public func update(_ next: RecorderSnapshot) {
        let previous = snapshot
        let subject = screen.subject
        if let sid = next.forgottenSid, !forgotten.contains(sid) {
            forgotten.insert(sid)
            if memory?.sid == sid { memory = nil }
        }
        snapshot = next
        now = clock()
        dropStaleHermes()
        remember(previous: previous, next: next)
        // A recording that starts, or a held call that comes back, takes the panel even if the list was open.
        if next.phase == .recording, previous.phase != .recording || previous.sid != next.sid { focus = .auto }
        if case .call(let sid, _) = focus, !AfterContent.known(next, forgotten: forgotten).contains(where: { $0.sid == sid }) {
            focus = focus.back
        }
        settle(after: subject)
        if let before = previous.feed {
            let filedBefore = Set(before.recent.filter { $0.state == .filed }.map(\.sid))
            if next.feed?.recent.contains(where: { $0.state == .filed && !filedBefore.contains($0.sid) }) == true {
                show(.filed, for: PanelRules.filedFlash)
            }
        }
    }

    public func perform(_ requested: PanelAction) async {
        guard !isBusy else { return }
        if requested.needsConfirmation {
            action = .confirming(requested)
            return
        }
        await run(requested)
    }

    public func confirm() async {
        guard case .confirming(let pending) = action else { return }
        await run(pending)
    }

    public func cancel() {
        if case .confirming = action { action = .idle }
    }

    public func markMoment() async {
        guard snapshot.phase == .recording else {
            show(.markMissed, for: PanelRules.markFlash)
            return
        }
        do {
            try await actions.markMoment(note: nil)
            show(.marked, for: PanelRules.markFlash)
            AccessibilityNotification.Announcement("Moment marked").post()
        } catch {
            show(.markMissed, for: PanelRules.markFlash)
            AccessibilityNotification.Announcement("Moment not marked").post()
        }
    }

    public var isAsking: Bool { memory?.asks.contains { $0.status.isPending } ?? false }
    public var isAskingAny: Bool { anyAsk?.status == .waiting }
    public var overlayVisible: Bool { liveSid != nil && !overlayHidden }

    public func toggleOverlay() { overlayHidden.toggle() }

    /// One of the overlay's buttons: the mini supplies the question, the label is what the user sees.
    public func quickAsk(_ kind: QuickAsk) async {
        await submitAsk(PanelCopy.quickQuestion(kind), kind: kind)
    }

    /// Asks the mini's fast model first and shows the answer as it arrives. When that fails before any text, the
    /// slower Hermes answer is the fallback.
    public func submitAsk(_ question: String? = nil, kind: QuickAsk = .ask) async {
        let text = (question ?? askDraft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isAsking, let sid = liveSid else { return }
        if question == nil { askDraft = "" }
        if memory?.sid != sid { memory = SessionMemory(sid: sid) }
        let entry = AskEntry(question: text, kind: kind, at: clock())
        memory?.asks.append(entry)
        pillOpen = true
        let request = LiveAskRequest(kind: kind, question: text, sid: sid, lines: Array(snapshot.lines.suffix(ControlActions.liveLines)))
        let status: AskEntry.Status
        let arrived = Mutex("")
        do {
            let full = try await actions.askLive(request) { partial in
                arrived.withLock { $0 = partial }
                Task { @MainActor [weak self] in self?.stream(partial, into: entry.id) }
            }.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !full.isEmpty else { throw RecorderError(reply: "empty") }
            AccessibilityNotification.Announcement("Answer ready").post()
            status = .answered(full)
        } catch {
            let partial = arrived.withLock { $0 }.trimmingCharacters(in: .whitespacesAndNewlines)
            if !partial.isEmpty {
                status = .answered(partial + " …")
            } else if (error as? RecorderError)?.reply == "no_screen" {
                status = .answered(PanelCopy.noScreen)
            } else if kind == .screen {
                // Hermes can't see the screen, so its answer would be a guess.
                status = .failed
            } else {
                status = await answer { try await self.actions.ask(text) }
            }
        }
        guard let index = memory?.asks.firstIndex(where: { $0.id == entry.id }) else { return }
        memory?.asks[index].status = status
    }

    public func retryAsk(_ id: UUID) async {
        guard !isAsking, liveSid != nil, let index = memory?.asks.firstIndex(where: { $0.id == id }),
              let entry = memory?.asks[index], entry.status == .failed else { return }
        memory?.asks.remove(at: index)
        await submitAsk(entry.question, kind: entry.kind)
    }

    /// Partial answers hop to the main actor one task each, so a late one must not replace a longer or final answer.
    private func stream(_ partial: String, into id: UUID) {
        guard let index = memory?.asks.firstIndex(where: { $0.id == id }), let current = memory?.asks[index].status else { return }
        switch current {
        case .waiting: memory?.asks[index].status = .streaming(partial)
        case .streaming(let shown) where partial.count > shown.count: memory?.asks[index].status = .streaming(partial)
        case .streaming, .answered, .failed: break
        }
    }

    public func submitAnyAsk(_ question: String? = nil) async {
        let text = (question ?? anyDraft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isAskingAny else { return }
        if question == nil { anyDraft = "" }
        let entry = AskEntry(question: text, at: clock())
        anyAsk = entry
        let status = await answer { try await self.actions.askAnyMeeting(text) }
        guard anyAsk?.id == entry.id else { return }
        anyAsk?.status = status
    }

    // MARK: Hermes

    /// Hermes controls need the mini, which holds the bot, and an event key to send back to it.
    public func hermesTarget(for meeting: PanelMeeting) -> HermesTarget? {
        guard hasMini, PanelLinks.isMeet(meeting.meetingURL) else { return nil }
        return HermesTarget(meeting)
    }

    public func hermesTarget(for item: PanelAgendaItem) -> HermesTarget? {
        guard hasMini, PanelLinks.isMeet(item.meetingURL) else { return nil }
        return HermesTarget(item)
    }

    /// The live or paused call's event, whichever screen the panel shows.
    public var liveHermes: HermesTarget? { hasMini ? live?.content.hermes : nil }

    /// The state to show: what the user just asked for, else what the feed says.
    public func hermes(_ target: HermesTarget) -> PanelHermes { hermesOverrides[target.key]?.state ?? target.feed }

    public func isHermesPending(_ key: String) -> Bool { hermesPending.contains(key) }

    /// Shows the change at once, sends it to the mini, and puts the old state back with the panel's failure line if
    /// the mini refuses or can't be reached. Controls for the same event wait while it runs.
    public func setHermes(_ target: HermesTarget, _ change: HermesChange) async {
        let key = target.key
        guard hasMini, !hermesPending.contains(key), !isBusy else { return }
        let previous = hermesOverrides[key]
        let shown = hermes(target).applying(change)
        guard shown != hermes(target) else { return }
        if isFailed { action = .idle }
        hermesOverrides[key] = HermesOverride(state: shown, confirmedAt: nil)
        hermesPending.insert(key)
        let subject = screen.subject
        do {
            try await callHermes(key: key, change: change)
            hermesPending.remove(key)
            hermesOverrides[key]?.confirmedAt = clock()
        } catch {
            hermesPending.remove(key)
            hermesOverrides[key] = previous
            let failed = PanelAction.hermes(key: key, change: change)
            if screen.subject == subject, action == .idle || isFailed {
                action = .failed(failed)
                AccessibilityNotification.Announcement(PanelCopy.failure(failed)).post()
            }
        }
    }

    private func callHermes(key: String, change: HermesChange) async throws {
        switch change {
        case .join: try await actions.hermesOptIn(key: key)
        case .leave: try await actions.hermesOptOut(key: key)
        case .chat(let on): try await actions.hermesChat(key: key, on: on)
        }
    }

    /// An answer the mini has had time to reflect stands in for what the user asked: the first feed built after the
    /// command returned replaces it, and so does three minutes without one.
    private func dropStaleHermes() {
        guard !hermesOverrides.isEmpty else { return }
        let built = snapshot.feed?.at
        hermesOverrides = hermesOverrides.filter { _, override in
            guard let confirmed = override.confirmedAt else { return true }
            if let built, built > confirmed { return false }
            return now.timeIntervalSince(confirmed) < PanelRules.hermesHold
        }
    }

    public func open(_ url: URL) { openURL(url) }

    public func navigate(_ next: PanelFocus) {
        focus = next
        cancel()
    }

    public func back() { navigate(focus.back) }

    public func panelClosed() {
        focus = .auto
        cancel()
        if isFailed { action = .idle }
        if !isAskingAny { anyAsk = nil }
    }

    /// The live or paused call, if any, whichever screen the panel shows: the overlay keeps it while the panel shows
    /// earlier meetings.
    public var live: (content: LiveContent, paused: Bool)? {
        switch liveScreen {
        case .recording(let content): (content, false)
        case .paused(let content): (content, true)
        case .idle, .before, .after, .access: nil
        }
    }

    private var liveScreen: PanelScreen {
        PanelScreen.resolve(snapshot, now: now, focus: .auto, forgotten: forgotten, memory: memory, hasMini: hasMini)
    }

    private var liveSid: String? {
        switch liveScreen {
        case .recording(let content), .paused(let content): content.sid
        case .idle, .before, .after, .access: nil
        }
    }

    private func answer(_ ask: @escaping () async throws -> String) async -> AskEntry.Status {
        let reply = try? await ask()
        if let text = reply?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            AccessibilityNotification.Announcement("Answer ready").post()
            return .answered(text)
        }
        AccessibilityNotification.Announcement("No answer").post()
        return .failed
    }

    /// Keeps the session's asks and warnings across snapshots, and keeps a paused session on screen: the recorder ends
    /// the capture on pause, so the paused snapshot has no session of its own.
    private func remember(previous: RecorderSnapshot, next: RecorderSnapshot) {
        switch next.phase {
        case .recording:
            guard let sid = next.sid else { break }
            if memory?.sid != sid { begin(sid) }
            if memory?.pausedFrom != nil {
                memory?.pausedFrom = nil
                memory?.pausedAt = nil
            }
        case .paused:
            if let sid = next.sid, memory?.sid != sid {
                begin(sid)
            } else if next.sid == nil, previous.phase == .recording, let sid = previous.sid, memory?.sid == sid {
                memory?.pausedFrom = previous
                memory?.pausedAt = now
            }
        case .ended where next.heldUntil != nil && next.sid == memory?.sid:
            break   // A call the recorder holds after its signal went away keeps its questions in case it comes back.
        case .idle, .armed, .ended:
            if memory != nil { begin(nil) }
        }
        if let live = next.feed?.live, live.sid == memory?.sid {
            for warning in live.warnings where memory?.warnings[warning.n] == nil { memory?.warnings[warning.n] = warning }
        }
    }

    private func begin(_ sid: String?) {
        memory = sid.map { SessionMemory(sid: $0) }
        overlayHidden = false
        pillOpen = false
        if !askDraft.isEmpty { askDraft = "" }
    }

    private func settle(after subject: String) {
        guard screen.subject != subject else { return }
        switch action {
        case .confirming, .failed: action = .idle
        case .idle, .running: break
        }
    }

    private func run(_ pending: PanelAction) async {
        let token = UUID()
        actionToken = token
        let subject = screen.subject
        action = .running(pending)
        let timeout = actionTimeout
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.finish(token, pending, succeeded: false, subject: nil)
        }
        let succeeded: Bool
        do {
            switch pending {
            case .pause: try await actions.pause()
            case .resume: try await actions.resume()
            case .stop: try await actions.stop()
            case .startInPerson: try await actions.startInPerson()
            case .notAMeeting(let sid), .forget(let sid): try await actions.forget(sid: sid)
            case .hermes(let key, let change): try await callHermes(key: key, change: change)
            }
            succeeded = true
        } catch {
            succeeded = false
        }
        finish(token, pending, succeeded: succeeded, subject: subject)
    }

    private func finish(_ token: UUID, _ pending: PanelAction, succeeded: Bool, subject: String?) {
        guard actionToken == token else { return }
        actionToken = nil
        if succeeded {
            action = .idle
            switch pending {
            case .forget(let sid), .notAMeeting(let sid):
                forgotten.insert(sid)
                if memory?.sid == sid { memory = nil }
            case .pause, .resume, .stop, .startInPerson, .hermes:
                break
            }
            if case .call(let sid, _) = focus, forgotten.contains(sid) { focus = focus.back }
        } else if let subject, screen.subject != subject {
            action = .idle
        } else {
            action = .failed(pending)
            AccessibilityNotification.Announcement(PanelCopy.failure(pending)).post()
        }
    }

    private func show(_ kind: Flash, for seconds: TimeInterval) {
        now = clock()
        flash = FlashState(kind: kind, until: now.addingTimeInterval(seconds))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            self?.tick()
        }
    }
}

/// An optimistic Hermes state. `confirmedAt` is when the mini accepted the command; before that it is only a request.
public struct HermesOverride: Equatable, Sendable {
    public var state: PanelHermes
    public var confirmedAt: Date?
}
