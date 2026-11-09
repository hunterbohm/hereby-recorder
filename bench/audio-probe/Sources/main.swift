import CoreAudio
import Foundation

// Read-only: prints one JSON line listing processes that currently use audio input/output.
// No TCC permission is needed to read the process object list.

func prop<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ initial: T) -> T? {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    let st = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, $0) }
    return st == noErr ? value : nil
}

func processObjects() -> [AudioObjectID] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func bundleID(_ obj: AudioObjectID) -> String {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var cf: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &cf) == noErr, let s = cf?.takeRetainedValue() else { return "" }
    return s as String
}

var rows: [[String: Any]] = []
for p in processObjects() {
    let inp = prop(p, kAudioProcessPropertyIsRunningInput, UInt32(0)) ?? 0
    let out = prop(p, kAudioProcessPropertyIsRunningOutput, UInt32(0)) ?? 0
    if inp == 0 && out == 0 { continue }
    let pid = prop(p, kAudioProcessPropertyPID, pid_t(0)) ?? 0
    rows.append(["bundle": bundleID(p), "pid": pid, "input": inp != 0, "output": out != 0])
}
let line: [String: Any] = ["ts": ISO8601DateFormatter().string(from: Date()), "procs": rows]
print(String(data: try! JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]), encoding: .utf8)!)
