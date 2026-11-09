import Carbon.HIToolbox
import Testing
@testable import LMLPanel

@MainActor
struct HotkeyTests {
    func send(signature: OSType, id: UInt32) -> OSStatus {
        var event: EventRef?
        guard CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0,
                          EventAttributes(kEventAttributeNone), &event) == noErr else { return -1 }
        defer { ReleaseEvent(event) }
        var id = EventHotKeyID(signature: signature, id: id)
        SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                          MemoryLayout<EventHotKeyID>.size, &id)
        return SendEventToEventTarget(event, GetApplicationEventTarget())
    }

    let unusual = controlKey | optionKey | shiftKey | cmdKey

    @Test func hotkeyRegistersAndOnlyItsOwnPressRunsTheAction() throws {
        var presses = 0
        let hotkey = try #require(Hotkey(keyCode: kVK_F19, modifiers: unusual) { presses += 1 })
        #expect(send(signature: Hotkey.signature, id: hotkey.id) == noErr)
        #expect(send(signature: 0x4F54_4852, id: hotkey.id) == OSStatus(eventNotHandledErr))
        #expect(presses == 1)
        #expect(Hotkey(keyCode: kVK_F19, modifiers: unusual) {} == nil, "a second claim is refused, so the panel hides the shortcut hint")
        #expect(send(signature: Hotkey.signature, id: hotkey.id) == noErr)
        #expect(presses == 2, "the refused claim leaves the first handler working")
        withExtendedLifetime(hotkey) {}
    }

    @Test func eachHotkeyRunsOnlyForItsOwnKey() throws {
        var first = 0, second = 0
        let a = try #require(Hotkey(keyCode: kVK_F18, modifiers: unusual) { first += 1 })
        let b = try #require(Hotkey(keyCode: kVK_F17, modifiers: unusual) { second += 1 })
        #expect(send(signature: Hotkey.signature, id: b.id) == noErr)
        #expect(first == 0 && second == 1)
        #expect(send(signature: Hotkey.signature, id: a.id) == noErr)
        #expect(first == 1 && second == 1)
        withExtendedLifetime((a, b)) {}
    }
}
