import AVFoundation
import CoreAudio
import Foundation

// Usage: tap-probe <seconds>
// Opens a global system-audio process tap (excluding self) and the default mic,
// and prints one JSON line per second with peak/RMS for each, then a summary.

final class Meter: @unchecked Sendable {
    private let lock = NSLock()
    private var sumSq: Double = 0
    private var count: Int = 0
    private var peak: Float = 0
    func add(_ p: UnsafePointer<Float>, _ n: Int) {
        var s: Double = 0
        var pk: Float = 0
        for i in 0..<n { let v = p[i]; s += Double(v * v); pk = max(pk, abs(v)) }
        lock.lock(); sumSq += s; count += n; peak = max(peak, pk); lock.unlock()
    }
    func take() -> (Double, Float, Int) {
        lock.lock(); defer { lock.unlock() }
        let r = count > 0 ? (sumSq / Double(count)).squareRoot() : 0
        let out = (r, peak, count)
        sumSq = 0; count = 0; peak = 0
        return out
    }
}

func check(_ s: OSStatus, _ what: String) throws {
    if s != noErr { throw NSError(domain: what, code: Int(s)) }
}

let seconds = Int(CommandLine.arguments.dropFirst().first ?? "10") ?? 10
let tapMeter = Meter()
let micMeter = Meter()

var selfObj = AudioObjectID(kAudioObjectUnknown)
var pid = getpid()
var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var size = UInt32(MemoryLayout<AudioObjectID>.size)
_ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &selfObj)

let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: selfObj == kAudioObjectUnknown ? [] : [selfObj])
desc.uuid = UUID()
desc.isPrivate = true
desc.muteBehavior = .unmuted
var tapID = AudioObjectID(kAudioObjectUnknown)
var tapStatus = AudioHardwareCreateProcessTap(desc, &tapID)
var result: [String: Any] = ["tap_create_status": tapStatus]

var aggID = AudioObjectID(kAudioObjectUnknown)
var procID: AudioDeviceIOProcID?
if tapStatus == noErr {
    let aggDesc: [String: Any] = [
        kAudioAggregateDeviceNameKey: "lml-tap-probe",
        kAudioAggregateDeviceUIDKey: "lml-tap-probe-\(UUID().uuidString)",
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceTapAutoStartKey: true,
        kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
    ]
    let aggStatus = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID)
    result["agg_create_status"] = aggStatus
    if aggStatus == noErr {
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { _, inData, _, _, _ in
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            for b in abl {
                guard let d = b.mData else { continue }
                tapMeter.add(d.assumingMemoryBound(to: Float.self), Int(b.mDataByteSize) / 4)
            }
        }
        result["ioproc_status"] = ioStatus
        if ioStatus == noErr { result["start_status"] = AudioDeviceStart(aggID, procID) }
    }
}

let engine = AVAudioEngine()
let input = engine.inputNode
let fmt = input.outputFormat(forBus: 0)
result["mic_format"] = "\(fmt.sampleRate)Hz/\(fmt.channelCount)ch"
input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { buf, _ in
    if let c = buf.floatChannelData { micMeter.add(c[0], Int(buf.frameLength)) }
}
do { try engine.start(); result["mic_start"] = "ok" } catch { result["mic_start"] = "\(error)" }
result["mic_auth"] = AVCaptureDevice.authorizationStatus(for: .audio).rawValue

func emit(_ d: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: d, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
    fflush(stdout)
}
emit(result)

var tapMaxRMS = 0.0, micMaxRMS = 0.0, tapFrames = 0, micFrames = 0
for i in 1...seconds {
    Thread.sleep(forTimeInterval: 1)
    let (tr, tp, tn) = tapMeter.take()
    let (mr, mp, mn) = micMeter.take()
    tapMaxRMS = max(tapMaxRMS, tr); micMaxRMS = max(micMaxRMS, mr); tapFrames += tn; micFrames += mn
    emit(["s": i, "tap_rms": tr, "tap_peak": tp, "tap_frames": tn, "mic_rms": mr, "mic_peak": mp, "mic_frames": mn])
}
emit(["summary": true, "tap_max_rms": tapMaxRMS, "tap_frames": tapFrames, "mic_max_rms": micMaxRMS, "mic_frames": micFrames])

engine.stop()
if let p = procID { AudioDeviceStop(aggID, p); AudioDeviceDestroyIOProcID(aggID, p) }
if aggID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggID) }
if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
