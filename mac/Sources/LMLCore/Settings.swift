import Foundation

/// The recorder's settings from `recorder.toml`: where meetings sync and who the user is. The Mac and the mini read
/// the same file, the mini through `mini/lml_settings.py`, and both accept the same keys. `lml-import` compiles this
/// file too, so it uses Foundation only.
public struct Settings: Sendable, Equatable {
    public static let defaultMeetingApps = ["us.zoom", "com.google.Chrome", "net.imput.helium", "company.thebrowser", "app.zen-browser",
                                            "com.apple.Safari", "com.microsoft.teams", "com.tinyspeck.slackmacgap", "com.apple.FaceTime",
                                            "com.hnc.Discord", "com.webex"]
    public static let defaultMicApps = ["com.granola.app.helper"]
    /// The mini's ssh host. Without one, meetings stay on this Mac.
    public var sshHost: String?
    /// The folder the mini keeps sessions in.
    public var storageRoot = "~/.local/state/live-meeting"
    /// Bundle id prefixes of the apps whose calls are recorded.
    public var meetingApps = Settings.defaultMeetingApps
    /// Bundle id prefixes of apps that count only while they hold the microphone, like a notetaker's helper.
    public var micApps = Settings.defaultMicApps
    /// Microphone name fragments, most wanted first.
    public var micOrder: [String] = []
    public var retentionDays = 14
    /// What runs when a meeting has ended, as a command line. Nil means the handoff script.
    public var doneCommand: String?
    /// The overlay's global shortcuts; nil turns one off.
    public var overlayToggleKey: Shortcut? = Shortcut(keyCode: 42, modifiers: Shortcut.option)
    public var overlaySayKey: Shortcut? = Shortcut(keyCode: 36, modifiers: Shortcut.option)
    /// What runs each time the overlay shows, hides or changes style, as a command line, with `HEREBY_OVERLAY`,
    /// `HEREBY_OVERLAY_WIDTH` and `HEREBY_OVERLAY_DISPLAY` set. A tiling window manager uses it to keep windows
    /// clear of the side strip.
    public var overlayCommand: String?
    /// Sends a picture of the screen with every live question, so answers can use what is on it. Read screen sends one
    /// either way.
    public var screenContext = true
    public init() {}

    public var mini: Mini? { sshHost.map { Mini(host: $0, root: storageRoot) } }

    /// `$XDG_CONFIG_HOME/hereby/recorder.toml`, or `~/.config/hereby/recorder.toml` without it.
    public static func url(environment: [String: String] = ProcessInfo.processInfo.environment,
                           home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".config")
        return base.appendingPathComponent("hereby/recorder.toml")
    }

    /// The settings in `url`, or nil when there is no file there.
    public static func load(_ url: URL) throws -> Settings? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do { return try Settings(toml: String(contentsOf: url, encoding: .utf8)) }
        catch var error as SettingsError { error.file = url.path; throw error }
    }

    enum Kind {
        case text, list, days, host, root, shortcut, flag
        var problem: String {
            switch self {
            case .text: "must be a string"
            case .list: "must be a list of strings"
            case .days: "must be a whole number of days, 1 or more"
            case .host: "must be an ssh host with no spaces"
            case .root: "must be a path that starts with ~/ or /, with no quotes, $, or backslashes"
            case .shortcut: "must be a shortcut like \"option+return\", or \"off\""
            case .flag: "must be true or false"
            }
        }
        func accepts(_ value: TOML.Value) -> Bool {
            switch (self, value) {
            case (.text, .string(let text)): !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case (.list, .array(let items)): items.allSatisfy { Kind.text.accepts($0) }
            case (.days, .integer(let days)): days >= 1
            case (.host, .string(let host)): !host.isEmpty && !host.hasPrefix("-") && !host.contains { $0.isWhitespace }
            case (.root, .string(let root)): (root.hasPrefix("~/") || root.hasPrefix("/")) && !root.contains { "\"$`\\".contains($0) }
            case (.shortcut, .string(let text)): Shortcut.parse(text) != nil
            case (.flag, .bool): true
            default: false
            }
        }
    }

    static let fields: [String: Kind] = [
        "ssh_host": .host, "storage_root": .root, "user_name": .text, "emails": .list, "calendars": .list, "domains": .list, "vault": .text,
        "meeting_apps": .list, "mic_apps": .list, "mic_order": .list, "retention_days": .days, "done_command": .text,
        "calendar_collector": .text, "project_map": .text,
        "overlay_toggle_key": .shortcut, "overlay_say_key": .shortcut, "overlay_command": .text,
        "screen_context": .flag
    ]

    public init(toml text: String) throws {
        self.init()
        for (key, value) in try TOML.parse(text).sorted(by: { $0.key < $1.key }) {
            guard let kind = Self.fields[key] else { throw SettingsError(field: key, problem: "is not a setting") }
            guard kind.accepts(value) else { throw SettingsError(field: key, problem: kind.problem) }
            switch (key, value) {
            case ("ssh_host", .string(let host)): sshHost = host
            case ("storage_root", .string(let root)): storageRoot = root
            case ("meeting_apps", .array(let apps)): meetingApps = apps.compactMap(\.string)
            case ("mic_apps", .array(let apps)): micApps = apps.compactMap(\.string)
            case ("mic_order", .array(let mics)): micOrder = mics.compactMap(\.string)
            case ("retention_days", .integer(let days)): retentionDays = days
            case ("done_command", .string(let command)): doneCommand = command
            case ("overlay_toggle_key", .string(let text)): overlayToggleKey = Shortcut.parse(text) ?? nil
            case ("overlay_say_key", .string(let text)): overlaySayKey = Shortcut.parse(text) ?? nil
            case ("overlay_command", .string(let command)): overlayCommand = command
            case ("screen_context", .bool(let on)): screenContext = on
            default: break
            }
        }
    }
}

/// Where sessions sync: the mini's ssh host and the folder it keeps sessions in.
public struct Mini: Sendable, Equatable {
    public var host: String
    public var root: String
    public init(host: String, root: String = Settings().storageRoot) { self.host = host; self.root = root }
    /// The multiplexed connection's socket name, one per host so a changed `ssh_host` never reuses the old host's connection.
    public var controlName: String { "ssh-" + host.replacingOccurrences(of: "/", with: "_") }
    /// `root` for the mini's shell, with `~` as `$HOME`. Test sessions live in the `-test` folder beside it.
    public func shellRoot(test: Bool) -> String {
        var path = root.hasPrefix("~/") ? "$HOME/" + root.dropFirst(2) : root
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path + (test ? "-test" : "")
    }
}

public struct SettingsError: Error, Equatable, CustomStringConvertible {
    public var file: String?
    public var field: String?
    public var problem: String
    public init(file: String? = nil, field: String? = nil, problem: String) { self.file = file; self.field = field; self.problem = problem }
    public var description: String { [file.map { $0 + ":" }, field, problem].compactMap { $0 }.joined(separator: " ") }
}

/// The part of TOML that settings use: `key = value` lines whose values are strings, integers, booleans, or arrays.
enum TOML {
    indirect enum Value: Equatable {
        case string(String), integer(Int), bool(Bool), array([Value])
        var string: String? { if case .string(let text) = self { text } else { nil } }
    }

    static func parse(_ text: String) throws -> [String: Value] {
        var reader = Reader(Array(text.unicodeScalars))
        var values: [String: Value] = [:]
        while true {
            reader.skipBlank()
            guard !reader.atEnd else { return values }
            let key = try reader.key()
            reader.skipSpaces()
            guard reader.take("=") else { throw reader.error("expected = after \(key)") }
            reader.skipSpaces()
            let value = try reader.value()
            reader.skipSpaces(); reader.skipComment()
            guard reader.atEnd || reader.take("\n") || reader.take("\r\n") else { throw reader.error("unexpected text after \(key)") }
            guard values[key] == nil else { throw SettingsError(field: key, problem: "is set twice") }
            values[key] = value
        }
    }

    struct Reader {
        let scalars: [Unicode.Scalar]
        var index = 0
        var line = 1
        init(_ scalars: [Unicode.Scalar]) { self.scalars = scalars }
        var atEnd: Bool { index >= scalars.count }
        var next: Unicode.Scalar? { atEnd ? nil : scalars[index] }
        func error(_ problem: String) -> SettingsError { SettingsError(problem: "line \(line): \(problem)") }

        mutating func take(_ word: String) -> Bool {
            let wanted = Array(word.unicodeScalars)
            guard index + wanted.count <= scalars.count, Array(scalars[index..<index + wanted.count]) == wanted else { return false }
            index += wanted.count
            if wanted.last == "\n" { line += 1 }
            return true
        }
        mutating func skipSpaces() { while next == " " || next == "\t" { index += 1 } }
        mutating func skipComment() { if next == "#" { while let scalar = next, scalar != "\n", scalar != "\r" { index += 1 } } }
        /// Spaces, comments, and line breaks.
        mutating func skipBlank() {
            while true {
                skipSpaces(); skipComment()
                guard take("\n") || take("\r\n") else { return }
            }
        }
        mutating func key() throws -> String {
            var key = ""
            while let scalar = next, scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-" {
                key.unicodeScalars.append(scalar); index += 1
            }
            guard !key.isEmpty else { throw error(next == "[" ? "tables are not supported" : "expected a setting name") }
            return key
        }
        mutating func value() throws -> Value {
            switch next {
            case "\"":
                guard !take("\"\"\"") else { throw error("multi-line strings are not supported") }
                index += 1
                return .string(try basicString())
            case "'":
                guard !take("'''") else { throw error("multi-line strings are not supported") }
                index += 1
                var text = ""
                while let scalar = next, scalar != "'" {
                    guard scalar != "\n" else { throw error("unterminated string") }
                    guard !scalar.isControl else { throw error("control character in a string") }
                    text.unicodeScalars.append(scalar); index += 1
                }
                guard take("'") else { throw error("unterminated string") }
                return .string(text)
            case "[":
                index += 1
                var items: [Value] = []
                while true {
                    skipBlank()
                    if take("]") { return .array(items) }
                    items.append(try value())
                    skipBlank()
                    if take(",") { continue }
                    guard take("]") else { throw error("expected , or ] in a list") }
                    return .array(items)
                }
            default:
                var word = ""
                while let scalar = next, !" \t\r\n,]#".unicodeScalars.contains(scalar) { word.unicodeScalars.append(scalar); index += 1 }
                if word == "true" { return .bool(true) }
                if word == "false" { return .bool(false) }
                guard word.wholeMatch(of: /[+-]?(0|[1-9][0-9]*(_[0-9]+)*)/) != nil, let number = Int(word.replacingOccurrences(of: "_", with: "")) else {
                    throw error(word.isEmpty ? "expected a value" : "unsupported value \(word)")
                }
                return .integer(number)
            }
        }
        mutating func basicString() throws -> String {
            var text = ""
            while let scalar = next {
                index += 1
                switch scalar {
                case "\"": return text
                case "\n", "\r": throw error("unterminated string")
                case _ where scalar.isControl: throw error("control character in a string")
                case "\\":
                    guard let escape = next else { throw error("unterminated string") }
                    index += 1
                    switch escape {
                    case "b": text += "\u{8}"
                    case "t": text += "\t"
                    case "n": text += "\n"
                    case "f": text += "\u{c}"
                    case "r": text += "\r"
                    case "\"": text += "\""
                    case "\\": text += "\\"
                    case "u", "U":
                        let count = escape == "u" ? 4 : 8
                        guard index + count <= scalars.count,
                              let code = UInt32(String(String.UnicodeScalarView(scalars[index..<index + count])), radix: 16),
                              let decoded = Unicode.Scalar(code) else { throw error("bad \\\(escape) escape") }
                        text.unicodeScalars.append(decoded); index += count
                    default: throw error("bad escape \\\(escape)")
                    }
                default: text.unicodeScalars.append(scalar)
                }
            }
            throw error("unterminated string")
        }
    }
}

private extension Unicode.Scalar {
    /// Control characters TOML forbids inside a string, tab excepted.
    var isControl: Bool { (value < 0x20 && value != 0x09) || value == 0x7f }
}
