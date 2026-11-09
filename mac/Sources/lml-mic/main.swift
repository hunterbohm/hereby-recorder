import CoreAudio
import Foundation
import LMLCore

// Keeps the system default input on the first connected mic in the `mic_order` setting and undoes any other choice, a pick
// by hand included. macOS also switches the default on its own, most often to AirPods, at moments unrelated to any device
// change, and those switches look exactly like a pick by hand. When macOS keeps taking it back, MicSwitchGuard pauses.
// Usage: lml-mic, lml-mic --list, or lml-mic --pick [device name...] to print the pick without switching.

struct InputDevice { let id: AudioDeviceID; let name: String }

func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T) -> T? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
}

// Aggregates come and go whenever an app starts or stops audio, so they are left out of the mics that count.
func inputDevices() -> [InputDevice] {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                             mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.compactMap { id in
        var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var bytes: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr, bytes > 0,
              property(id, kAudioDevicePropertyTransportType, initial: UInt32(0)) != kAudioDeviceTransportTypeAggregate,
              let name = property(id, kAudioObjectPropertyName, initial: "" as CFString) else { return nil }
        return InputDevice(id: id, name: name as String)
    }
}

func defaultInput() -> AudioDeviceID {
    property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, initial: AudioDeviceID(0)) ?? 0
}

func preferred(_ devices: [InputDevice], _ order: [String]) -> InputDevice? {
    MicOrder.pick(devices.map(\.name), order: order).map { devices[$0] }
}

func log(_ message: String) { print("\(ISO8601DateFormatter().string(from: Date())) \(message)") }

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--list"] {
    let current = defaultInput()
    for device in inputDevices() { print((device.id == current ? "* " : "  ") + device.name) }
    exit(0)
}
guard arguments.isEmpty || arguments.first == "--pick" else {
    FileHandle.standardError.write(Data("usage: lml-mic | --list | --pick [device name...]\n".utf8))
    exit(2)
}
let settingsURL = Settings.url()
let order: [String]
do { order = try Settings.load(settingsURL)?.micOrder ?? [] }
catch { FileHandle.standardError.write(Data("lml-mic: \(error)\n".utf8)); exit(1) }
if arguments.first == "--pick" {
    let names = arguments.count > 1 ? Array(arguments.dropFirst()) : inputDevices().map(\.name)
    guard let index = MicOrder.pick(names, order: order) else { print("none"); exit(1) }
    print(names[index])
    exit(0)
}
guard !order.isEmpty else {
    print("No mic_order in \(settingsURL.path), so the default input is left alone.")
    exit(0)
}
setvbuf(stdout, nil, _IOLBF, 0)
var switches = MicSwitchGuard()

@MainActor func enforce() {
    let devices = inputDevices()
    let current = defaultInput()
    guard let target = preferred(devices, order), target.id != current else { return }
    switch switches.verdict(at: ProcessInfo.processInfo.systemUptime) {
    case .paused: return
    case .pauseStarted:
        let name = devices.first { $0.id == current }?.name ?? "another mic"
        log("switched the default input back \(switches.limit) times in \(Int(switches.window)) s and macOS took it again, so it stays on \(name) for \(Int(switches.pause)) s")
        DispatchQueue.main.asyncAfter(deadline: .now() + switches.pause) { enforce() }
        return
    case .switchBack: break
    }
    var id = target.id
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                             mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                            UInt32(MemoryLayout<AudioDeviceID>.size), &id)
    log(status == noErr ? "default input -> \(target.name)" : "could not select \(target.name): \(status)")
}

enforce()
let system = AudioObjectID(kAudioObjectSystemObject)
var devicesAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
AudioObjectAddPropertyListenerBlock(system, &devicesAddress, DispatchQueue.main) { _, _ in MainActor.assumeIsolated {
    // macOS can switch the default to a newly connected headset a moment after announcing it, so check again later.
    enforce()
    for delay in [1.5, 4.0] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { enforce() } }
} }
var defaultAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
AudioObjectAddPropertyListenerBlock(system, &defaultAddress, DispatchQueue.main) { _, _ in MainActor.assumeIsolated { enforce() } }
dispatchMain()
