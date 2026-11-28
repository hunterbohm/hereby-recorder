import Foundation
import LMLCore

/// One line of the setup window: a permission by its macOS name, a leader that is dots until it is on, the one thing to
/// do about it, and a line under it saying what Hereby uses it for or how to turn it on.
public struct SetupRow: Equatable, Sendable, Identifiable {
    public enum Action: Equatable, Sendable { case allow, openSettings, restart }

    public var permission: Permission
    /// The permission as System Settings and the macOS prompt name it.
    public var name: String
    public var grant: Grant
    /// The button, when there is something to press now.
    public var action: Action?
    /// Stands where the button would be while nothing can be pressed: the macOS prompt is up, the restart runs, or a
    /// restart waits for the call to end.
    public var status: String?
    /// The line under the name: what Hereby uses the permission for, or, while it is off, how to turn it on.
    public var detail: String

    public var id: Permission { permission }
    public var done: Bool { grant == .granted }
}

/// What the setup window shows (STATES.md, Setup), from the recorder's permissions.
public struct SetupContent: Equatable, Sendable {
    public var rows: [SetupRow]
    /// The row whose button is filled: the first one with something to press. Nil once only Done is left.
    public var next: Permission?
    /// The call can be recorded; the screen may still be off.
    public var ready: Bool
    /// Everything shown is on: the window closes itself.
    public var complete: Bool

    public init(_ access: AccessState, asking: Set<Permission> = [], canRestart: Bool = true, restarting: Bool = false) {
        var rows: [SetupRow] = []
        func add(_ permission: Permission, _ grant: Grant) {
            var action: SetupRow.Action? = switch grant {
            case .granted: nil
            case .notAsked: .allow
            case .denied: .openSettings
            case .restart: .restart
            }
            var status: String?
            if asking.contains(permission), grant != .granted {
                action = nil
                status = "Waiting for macOS"
            } else if grant == .restart, restarting {
                action = nil
                status = "Restarting…"
            } else if grant == .restart, !canRestart {
                action = nil
                status = "Restart after the call"
            }
            let detail = switch grant {
            case .denied where permission == .systemAudio && !access.audioFromScreen:
                "Turn on Hereby under System Audio Recording Only"
            case .denied: "Off in System Settings"
            case .restart: "Starts working after a restart"
            case .granted, .notAsked: PanelCopy.setupPurpose(permission)
            }
            rows.append(SetupRow(permission: permission, name: PanelCopy.setupName(permission), grant: grant, action: action,
                                 status: status, detail: detail))
        }
        add(.microphone, access.microphone)
        add(.systemAudio, access.systemAudio)
        if let screen = access.screen { add(.screen, screen) }
        self.rows = rows
        next = rows.first { $0.action != nil }?.permission
        ready = access.ready
        complete = access.complete
    }
}

extension PanelCopy {
    /// The System Settings pane for `permission`. System audio from a tap is in the "System Audio Recording Only" list,
    /// at the bottom of the Screen & System Audio Recording pane.
    public static func settingsURL(_ permission: Permission) -> URL {
        URL(string: privacy + (permission == .microphone ? "Privacy_Microphone" : "Privacy_ScreenCapture"))!
    }

    public static let setupTitle = "Let Hereby hear your calls"
    public static let setupSubtitle = "Each Allow opens a prompt from macOS"

    /// The permission as System Settings and the macOS prompt name it.
    public static func setupName(_ permission: Permission) -> String {
        switch permission {
        case .microphone: "Microphone"
        case .systemAudio: "System audio"
        case .screen: "Screen recording"
        }
    }

    /// What Hereby uses the permission for, one short line.
    public static func setupPurpose(_ permission: Permission) -> String {
        switch permission {
        case .microphone: "To hear your side of the call"
        case .systemAudio: "To hear everyone else on the call"
        case .screen: "Optional, so answers can see your screen"
        }
    }

    public static func setupButton(_ action: SetupRow.Action) -> String {
        switch action {
        case .allow: "Allow"
        case .openSettings: "Open Settings"
        case .restart: "Restart Hereby"
        }
    }

    /// The leader's dots: all of a leader before its permission is on, and the pauses in its signal after.
    public static let flat: Character = "·"

    /// A permission's leader once it is on, `count` characters wide, with a space wherever the dots show.
    /// The two audio channels are bursts like syllables, rising and falling through `.:|`; the screen is runs of `=`
    /// like lines of text. The same channel always draws the same line.
    public static func signal(_ permission: Permission, count: Int) -> String {
        var random = switch permission {
        case .microphone: 11
        case .systemAudio: 29
        case .screen: 5
        }
        func next() -> Double {
            random = (random &* 1_103_515_245 &+ 12_345) & 0x7fff_ffff
            return Double(random) / Double(0x7fff_ffff)
        }
        func between(_ low: Int, _ high: Int) -> Int { low + Int(next() * Double(high - low + 1)) % (high - low + 1) }
        var line: [Character] = []
        while line.count < count {
            if permission == .screen {
                line += [" "] + Array(repeating: "=", count: between(1, 7))
                continue
            }
            line += Array(repeating: " ", count: between(1, 3))
            let length = between(2, 8), peak = 0.5 + 0.5 * next()
            for index in 0..<length {
                let level = sin(Double.pi * (Double(index) + 0.5) / Double(length)) * peak * (0.85 + 0.15 * next())
                line.append(Array(".:|")[min(2, Int(level * 3))])
            }
        }
        return String(line.prefix(max(0, count)))
    }
}
