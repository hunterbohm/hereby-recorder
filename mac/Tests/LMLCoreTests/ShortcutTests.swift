import Testing
@testable import LMLCore

struct ShortcutTests {
    @Test(arguments: [
        ("option+\\", 42, Shortcut.option, "⌥\\"),
        ("Option+Return", 36, Shortcut.option, "⌥↩"),
        ("control+option+return", 36, Shortcut.control | Shortcut.option, "⌃⌥↩"),
        ("cmd + shift + k", 40, Shortcut.command | Shortcut.shift, "⇧⌘K"),
        ("⌃+⌥+enter", 36, Shortcut.control | Shortcut.option, "⌃⌥↩"),
        ("alt+backslash", 42, Shortcut.option, "⌥\\"),
        ("ctrl+f5", 96, Shortcut.control, "⌃F5"),
    ] as [(String, UInt32, UInt32, String)])
    func readsAShortcutTheWayPeopleWriteIt(text: String, code: UInt32, modifiers: UInt32, symbol: String) throws {
        let shortcut = try #require(Shortcut.parse(text) ?? nil)
        #expect(shortcut == Shortcut(keyCode: code, modifiers: modifiers))
        #expect(shortcut.symbol == symbol)
    }
    @Test func offTurnsAShortcutOff() {
        #expect(Shortcut.parse("off") == .some(nil))
        #expect(Shortcut.parse(" OFF ") == .some(nil))
    }
    @Test(arguments: ["return", "option", "option+", "option+option+m", "hyper+m", "option+m+k", "option+é", ""])
    func rejectsWhatIsNotAShortcut(text: String) {
        #expect(Shortcut.parse(text) == nil)
    }
}

struct OverlaySettingsTests {
    @Test func theDefaultsAreOptionBackslashAndOptionReturnWithNoCommand() {
        let settings = Settings()
        #expect(settings.overlayToggleKey?.symbol == "⌥\\" && settings.overlaySayKey?.symbol == "⌥↩")
        #expect(settings.overlayCommand == nil)
    }
    @Test func readsTheOverlaySettings() throws {
        let settings = try Settings(toml: """
            overlay_toggle_key = "off"
            overlay_say_key = "control+option+return"
            overlay_command = "wm reserve right $HEREBY_OVERLAY_WIDTH"
            """)
        #expect(settings.overlayToggleKey == nil)
        #expect(settings.overlaySayKey == Shortcut(keyCode: 36, modifiers: Shortcut.control | Shortcut.option))
        #expect(settings.overlayCommand == "wm reserve right $HEREBY_OVERLAY_WIDTH")
    }
    @Test(arguments: ["overlay_say_key = \"return\"", "overlay_say_key = \"option+nope\"", "overlay_say_key = 3"])
    func aBadShortcutNamesItsField(toml: String) throws {
        do { _ = try Settings(toml: toml); Issue.record("accepted \(toml)") }
        catch let error as SettingsError {
            #expect(error == SettingsError(field: "overlay_say_key", problem: "must be a shortcut like \"option+return\", or \"off\""))
        }
    }
}
