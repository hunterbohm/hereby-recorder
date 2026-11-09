import Foundation

/// What runs when a meeting has ended and the Mac keeps it: the `done_command` setting, or the handoff script.
/// A `{session}` word becomes the session's folder.
public struct DoneCommand: Sendable, Equatable {
    public static let handoffName = "hereby-handoff.sh"
    public var words: [String]
    public init(words: [String]) { self.words = words }

    public init(_ text: String) throws {
        let words = try ShellWords.split(text)
        guard !words.isEmpty else { throw SettingsError(field: "done_command", problem: "must name a command") }
        self.init(words: words)
    }

    public static func handoff(script: URL) -> DoneCommand { DoneCommand(words: [script.path, "{session}"]) }

    /// The handoff script beside the checkout this binary was built in, or in the app's Resources.
    public static func locateHandoff(executable: URL, fileManager: FileManager = .default) -> URL? {
        var directory = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<8 {
            for candidate in ["handoff/\(handoffName)", "Resources/\(handoffName)"] {
                let script = directory.appendingPathComponent(candidate)
                if fileManager.isExecutableFile(atPath: script.path) { return script }
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    /// The setting if there is one, else the handoff script. Nil when there is no setting and no script to be found.
    public static func resolve(_ settings: Settings, executable: URL) throws -> DoneCommand? {
        if let text = settings.doneCommand { return try DoneCommand(text) }
        return locateHandoff(executable: executable).map(handoff(script:))
    }

    public func process(session: URL, timeout: TimeInterval) -> ProcessCommand {
        ProcessCommand("/usr/bin/env", words.map { $0.replacingOccurrences(of: "{session}", with: session.path) }, timeout: timeout)
    }
}

/// Splits a command line the way a shell does for quotes and backslashes, with no expansion.
enum ShellWords {
    static func split(_ text: String) throws -> [String] {
        var words: [String] = [], word = "", inWord = false
        var characters = text.makeIterator()
        func fail() -> SettingsError { SettingsError(field: "done_command", problem: "has an unclosed quote or a trailing backslash") }
        while let character = characters.next() {
            switch character {
            case "'":
                inWord = true
                while true {
                    guard let next = characters.next() else { throw fail() }
                    if next == "'" { break }
                    word.append(next)
                }
            case "\"":
                inWord = true
                while true {
                    guard let next = characters.next() else { throw fail() }
                    if next == "\"" { break }
                    if next == "\\" {
                        guard let escaped = characters.next() else { throw fail() }
                        if !"\"\\$`".contains(escaped) { word.append("\\") }
                        word.append(escaped)
                    } else { word.append(next) }
                }
            case "\\":
                guard let escaped = characters.next() else { throw fail() }
                inWord = true; word.append(escaped)
            case _ where character.isWhitespace:
                if inWord { words.append(word); word = ""; inWord = false }
            default:
                inWord = true; word.append(character)
            }
        }
        if inWord { words.append(word) }
        return words
    }
}
