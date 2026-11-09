import Foundation

/// A global shortcut written the way people say it, like `option+\` or `control+option+return`, as the Mac's
/// virtual key code and Carbon modifier mask. `off` turns the shortcut off. Foundation only, like `Settings`.
public struct Shortcut: Sendable, Equatable {
    public var keyCode: UInt32
    /// Carbon's `cmdKey`, `shiftKey`, `optionKey` and `controlKey` bits.
    public var modifiers: UInt32

    public static let command: UInt32 = 0x100, shift: UInt32 = 0x200, option: UInt32 = 0x800, control: UInt32 = 0x1000

    public init(keyCode: UInt32, modifiers: UInt32) { self.keyCode = keyCode; self.modifiers = modifiers }

    /// `.some(nil)` for `off`, nil when the text is not a shortcut. A shortcut needs at least one modifier.
    public static func parse(_ text: String) -> Shortcut?? {
        let words = text.lowercased().split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if words == ["off"] { return .some(nil) }
        guard let last = words.last, words.count >= 2 else { return nil }
        var mask: UInt32 = 0
        for word in words.dropLast() {
            guard let bit = modifierNames[word], mask & bit == 0 else { return nil }
            mask |= bit
        }
        guard let code = keyCodes[last] else { return nil }
        return .some(Shortcut(keyCode: code, modifiers: mask))
    }

    /// How the Mac prints it, like ⌃⌥↩.
    public var symbol: String {
        let marks = [(Self.control, "⌃"), (Self.option, "⌥"), (Self.shift, "⇧"), (Self.command, "⌘")]
        let key = Self.names.first { $0.value == keyCode }.map { Self.keySymbols[$0.key] ?? $0.key.uppercased() } ?? "?"
        return marks.filter { modifiers & $0.0 != 0 }.map(\.1).joined() + key
    }

    static let modifierNames: [String: UInt32] = [
        "cmd": command, "command": command, "⌘": command, "shift": shift, "⇧": shift,
        "opt": option, "option": option, "alt": option, "⌥": option, "ctrl": control, "control": control, "⌃": control,
    ]
    static let keySymbols = ["return": "↩", "space": "Space", "tab": "⇥", "escape": "⎋", "delete": "⌫"]
    /// ANSI-layout virtual key codes (`kVK_ANSI_*` and friends in Carbon's Events.h).
    static let names: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
        "tab": 48, "space": 49, "`": 50, "delete": 51, "escape": 53,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109,
        "f11": 103, "f12": 111,
    ]
    static let keyCodes: [String: UInt32] = {
        var codes = names
        for (alias, key) in [("enter", "return"), ("esc", "escape"), ("backslash", "\\"), ("slash", "/"), ("comma", ","),
                             ("period", "."), ("semicolon", ";"), ("quote", "'"), ("minus", "-"), ("equal", "="), ("grave", "`")] {
            codes[alias] = codes[key]
        }
        return codes
    }()
}
