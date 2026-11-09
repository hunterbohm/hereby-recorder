import Foundation
import LMLCore

public enum PanelCopy {
    public static func quickLabel(_ kind: QuickAsk) -> String {
        switch kind {
        case .say: "What to say"
        case .recap: "Recap"
        case .asked: "Their questions"
        case .check: "Check a number"
        case .screen: "Read screen"
        case .ask: "Ask"
        }
    }

    /// The question shown above a button's answer, and sent to Hermes if the fast answer fails.
    public static func quickQuestion(_ kind: QuickAsk) -> String {
        switch kind {
        case .say: "What should I say next?"
        case .recap: "Recap the last five minutes."
        case .asked: "What have they asked that I haven't answered?"
        case .check: "Does the last number they said match what we have?"
        case .screen: "What on my screen matters for this call?"
        case .ask: ""
        }
    }

    /// Read screen's answer when the recorder can't take a picture of the screen.
    public static let noScreen = "Hereby can't see your screen. Turn on Screen Recording for LiveMeetingListener in System Settings › Privacy & Security, then try again."

    static let privacy = "x-apple.systempreferences:com.apple.preference.security?"

    public static func running(_ action: PanelAction) -> String {
        switch action {
        case .pause: "Pausing…"
        case .resume: "Resuming…"
        case .stop: "Stopping…"
        case .startInPerson: "Starting…"
        case .notAMeeting, .forget: "Deleting the transcript…"
        case .hermes: "Updating Hermes…"
        }
    }

    public static func failure(_ action: PanelAction) -> String {
        switch action {
        case .pause: "Couldn't pause. Try again."
        case .resume: "Couldn't resume. Try again."
        case .stop: "Couldn't stop. Try again."
        case .startInPerson: "Couldn't start recording. Try again."
        case .notAMeeting, .forget: "Couldn't delete the transcript. Try again."
        case .hermes(_, .join): "Couldn't send Hermes. Try again."
        case .hermes(_, .leave): "Couldn't cancel Hermes. Try again."
        case .hermes(_, .chat): "Couldn't change chat replies. Try again."
        }
    }

    public struct Confirmation: Equatable, Sendable {
        public var title: String
        public var detail: String
        public var button: String
    }

    public static func confirmation(_ action: PanelAction, hasMini: Bool = true) -> Confirmation? {
        let place = hasMini ? "this Mac and the mini" : "this Mac"
        return switch action {
        case .notAMeeting:
            Confirmation(title: "Not a meeting?",
                         detail: "Recording stops and this call's transcript is deleted from \(place).",
                         button: "Delete transcript")
        case .forget:
            Confirmation(title: "Forget this call?",
                         detail: "Its transcript is deleted from \(place).",
                         button: "Forget")
        case .pause, .resume, .stop, .startInPerson, .hermes:
            nil
        }
    }

    // MARK: Hermes

    /// Where Hermes stands for one call, in the words the hero and the live screen use.
    public static func hermesLine(_ state: PanelHermes, start: Date, now: Date, in zone: TimeZone, locale: Locale) -> String {
        switch state.phase {
        case .off: "Hermes is off"
        case .scheduled: start > now ? "Hermes joins at \(PanelText.clock(start, in: zone, locale: locale))" : "Hermes joins now"
        case .joining: "Hermes is joining"
        case .waitingRoom: "Hermes is waiting to be let in"
        case .inCall: "Hermes is in the call"
        case .done: "Hermes took notes in this call"
        case .failed: state.error.map { "Hermes couldn't join: \($0)" } ?? "Hermes couldn't join"
        }
    }

    /// One or two words for a Later today row.
    public static func hermesShort(_ state: PanelHermes) -> String {
        switch state.phase {
        case .off, .scheduled, .done: "Hermes"
        case .joining: "Joining"
        case .waitingRoom: "Waiting"
        case .inCall: "In call"
        case .failed: "Failed"
        }
    }

    public static let hermesChatLabel = "Chat replies"

    public static func hermesChatHint(on: Bool) -> String {
        on ? "On: ask Hermes in the meeting chat and it texts you the answer."
           : "Off: Hermes listens and takes notes only."
    }

    /// Hermes is on its way or already in the call: Cancel only makes sense before it has been let in.
    public static func hermesStop(_ state: PanelHermes) -> String { state.phase == .inCall ? "Remove" : "Cancel" }

    public struct Access: Equatable, Sendable {
        public var title: String
        public var detail: String
        public var next: String?
        public var settingsURL: URL?
    }

    public static func access(_ content: AccessContent, now: Date, in zone: TimeZone, locale: Locale) -> Access {
        let next = content.next.map {
            "\($0.title) is at \(PanelText.upcoming($0.start, now: now, in: zone, locale: locale)). "
                + "If this is still off 10 minutes before, you get a text."
        }
        return switch (content.micOK, content.audioOK) {
        case (true, false):
            Access(title: "Can't hear call audio", detail: "System audio access is off, so only your mic would be recorded.",
                   next: next, settingsURL: URL(string: privacy + "Privacy_ScreenCapture"))
        case (false, true):
            Access(title: "Can't hear your mic", detail: "Microphone access is off, so your side of calls wouldn't be recorded.",
                   next: next, settingsURL: URL(string: privacy + "Privacy_Microphone"))
        case (false, false), (true, true):
            Access(title: "Can't record calls", detail: "Microphone and system audio access are off, so nothing would be recorded.",
                   next: next, settingsURL: URL(string: privacy + "Privacy_Microphone"))
        }
    }

    public static func accessibilityName(_ icon: StatusIcon) -> String {
        switch icon {
        case .idle: "Meeting recorder, idle"
        case .armed: "Meeting recorder, call detected, about to record"
        case .recording: "Meeting recorder, recording"
        case .paused: "Meeting recorder, paused"
        case .filed: "Meeting recorder, notes filed"
        case .marked: "Meeting recorder, moment marked"
        case .markMissed: "Meeting recorder, moment not marked"
        case .problem(let health): "Meeting recorder needs attention, " + problems(health).map(\.headline).joined(separator: ", ")
        }
    }

    public struct Problem: Equatable, Sendable {
        public var headline: String
        public var detail: String
        public var settingsURL: URL?
    }

    public static func problems(_ health: Health, in zone: TimeZone = .current, locale: Locale = .current) -> [Problem] {
        var list: [Problem] = []
        switch (health.micOK, health.audioOK) {
        case (false, false):
            list.append(Problem(headline: "microphone and system audio access are off",
                                detail: "Calls can't be recorded until both are allowed again.",
                                settingsURL: URL(string: privacy + "Privacy_Microphone")))
        case (false, true):
            list.append(Problem(headline: "microphone access is off",
                                detail: "Your side of calls can't be recorded.",
                                settingsURL: URL(string: privacy + "Privacy_Microphone")))
        case (true, false):
            list.append(Problem(headline: "system audio access is off",
                                detail: "The other side of calls can't be recorded.",
                                settingsURL: URL(string: privacy + "Privacy_ScreenCapture")))
        case (true, true):
            break
        }
        if !health.miniReachable {
            let since = health.lastContact.map { " since \(PanelText.clock($0, in: zone, locale: locale))" } ?? ""
            list.append(Problem(headline: "can't reach the mini",
                                detail: "No word from the mini\(since). Recording still works; notes file once it's back.",
                                settingsURL: nil))
        }
        return list
    }
}
