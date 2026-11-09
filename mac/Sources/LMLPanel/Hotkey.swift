import Carbon.HIToolbox

@MainActor
final class Hotkey {
    nonisolated static let signature: OSType = 0x4C4D_4C6D
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: @MainActor () -> Void
    nonisolated let id: UInt32
    private static var nextID: UInt32 = 1

    init?(keyCode: Int = kVK_ANSI_M, modifiers: Int = optionKey, action: @escaping @MainActor () -> Void) {
        self.action = action
        id = Self.nextID
        Self.nextID += 1
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            var id = EventHotKeyID()
            guard let context,
                  GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == Hotkey.signature else { return OSStatus(eventNotHandledErr) }
            let hotkey = Unmanaged<Hotkey>.fromOpaque(context).takeUnretainedValue()
            guard id.id == hotkey.id else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { hotkey.action() }
            return noErr
        }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { return nil }
        let key = EventHotKeyID(signature: Hotkey.signature, id: id)
        guard RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), key, GetApplicationEventTarget(), 0, &hotKey) == noErr else {
            return nil
        }
    }

    isolated deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
