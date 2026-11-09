import AVFoundation
import CoreAudio
import ScreenCaptureKit
import CoreMedia
import LMLCore
import Synchronization
import os

struct AudioChunk: Sendable {
    let samples: [Float]
    let sampleRate: Double
    let at: Date
    var runID: UUID? = nil
    var duration: Double { Double(samples.count) / sampleRate }
}
enum CaptureEvent: Sendable { case chunk(AudioChunk), endRun, context([String]) }

struct CaptureClock: Sendable {
    let wall = Date()
    let host = AudioGetCurrentHostTime()
    func date(hostTime: UInt64, fallbackDuration: Double) -> Date {
        guard hostTime > 0 else { return Date().addingTimeInterval(-fallbackDuration) }
        let seconds = Double(AudioConvertHostTimeToNanos(hostTime)) / 1e9 - Double(AudioConvertHostTimeToNanos(host)) / 1e9
        return wall.addingTimeInterval(seconds)
    }
}
func checkAudio(_ status: OSStatus) throws {
    guard status == noErr else { throw NSError(domain: "lml.audio", code: Int(status)) }
}
func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var value = initial; var size = UInt32(MemoryLayout<T>.size)
    let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
    return status == noErr ? value : nil
}
func objectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else { return [] }
    guard size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    let status = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!) }
    return status == noErr ? ids : []
}
func processBundle(_ object: AudioObjectID) -> String {
    var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?; var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return "" }
    return value?.takeRetainedValue() as String? ?? ""
}

struct AudioState: Sendable {
    var snapshot: ProcessSnapshot
    var defaultInput: AudioDeviceID
    /// The Mac's own microphone, the fallback when the chosen mic will not start.
    var builtInInput: AudioDeviceID? = nil
}

/// Reads the audio processes and watches them for changes, all on its own queue so a slow coreaudiod never
/// blocks the main actor. A burst of change notifications becomes one read per `RefreshGate.interval`.
final class ProcessMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "lml.process-monitor")
    // Everything below is confined to `queue`.
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var watched: Set<AudioObjectID> = []
    private var handler: (@Sendable (AudioState, Bool) -> Void)?
    private var gate = RefreshGate(interval: 0.25)
    /// The last read, reused while no listener has reported a change, so the once-a-second detection loop
    /// doesn't query every audio process in coreaudiod when nothing happened. Re-read anyway every 30 s.
    private var cached: AudioState?
    private var stale = true
    private var cachedAt = 0.0
    private static let maxCacheAge = 30.0
    private static func uptime() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    func read() async -> AudioState {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: self.readOrReuse()) } }
    }
    /// Calls `handler` with fresh state, and whether the mic should restart, after the audio processes or devices change.
    func observe(_ handler: @escaping @Sendable (AudioState, Bool) -> Void) {
        queue.async { self.handler = handler; _ = self.readNow() }
    }
    func stop() {
        queue.async { self.handler = nil; self.removeListeners() }
    }
    private func readOrReuse() -> AudioState {
        guard handler != nil, !listeners.isEmpty, !stale, var state = cached, Self.uptime() - cachedAt < Self.maxCacheAge else { return readNow() }
        state.snapshot.ts = Date()
        return state
    }
    private func readNow() -> AudioState {
        stale = false   // a change reported while this read runs marks it stale again
        defer { gate.finishedRead(at: Self.uptime()) }
        let objects = objectList(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
        if handler != nil, Set(objects) != watched { installListeners(objects) }
        let rows = objects.map { object in
            ProcessRow(bundle: processBundle(object),
                input: (property(object, kAudioProcessPropertyIsRunningInput, initial: UInt32(0)) ?? 0) != 0,
                output: (property(object, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) ?? 0) != 0,
                pid: property(object, kAudioProcessPropertyPID, initial: pid_t(-1)) ?? -1,
                inputDevices: objectList(object, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput))
        }
        let defaultInput = property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, initial: AudioObjectID(0)) ?? 0
        let builtIn = objectList(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices).first { id in
            property(id, kAudioDevicePropertyTransportType, initial: UInt32(0)) == kAudioDeviceTransportTypeBuiltIn
                && !objectList(id, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput).isEmpty
        }
        let state = AudioState(snapshot: ProcessSnapshot(procs: rows, ts: Date()), defaultInput: defaultInput, builtInInput: builtIn)
        cached = state; cachedAt = Self.uptime()
        return state
    }
    private func installListeners(_ objects: [AudioObjectID]) {
        removeListeners(); watched = Set(objects)
        for object in objects {
            listen(object, kAudioProcessPropertyIsRunningInput)
            listen(object, kAudioProcessPropertyIsRunningOutput)
            listen(object, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput)
        }
        listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
        listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice)
        listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, restartMic: true)
    }
    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, restartMic: Bool = false) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        let callback: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.stale = true
            self?.changed(restart: restartMic)
        }
        if AudioObjectAddPropertyListenerBlock(object, &address, queue, callback) == noErr { listeners.append((object, address, callback)) }
    }
    private func changed(restart: Bool) {
        guard handler != nil, let delay = gate.request(restart: restart, now: Self.uptime()) else { return }
        queue.asyncAfter(deadline: .now() + delay) {
            let restart = self.gate.begin()
            guard let handler = self.handler else { return }
            handler(self.readNow(), restart)
        }
    }
    private func removeListeners() {
        for (object, var address, callback) in listeners { AudioObjectRemovePropertyListenerBlock(object, &address, queue, callback) }
        listeners.removeAll(); watched.removeAll(); stale = true
    }
}

@MainActor protocol SystemAudioSource: AnyObject {
    func start() async throws
    func stop() async
}

@MainActor final class TapSource: SystemAudioSource {
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var io: AudioDeviceIOProcID?
    private let sink: @Sendable (AudioChunk) -> Void
    private let clock: CaptureClock
    init(clock: CaptureClock, sink: @escaping @Sendable (AudioChunk) -> Void) { self.clock = clock; self.sink = sink }
    func start() async throws {
        var own = AudioObjectID(kAudioObjectUnknown); var pid = getpid()
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &own)
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: own == kAudioObjectUnknown ? [] : [own])
        description.uuid = UUID(); description.isPrivate = true; description.muteBehavior = .unmuted
        do {
            try checkAudio(AudioHardwareCreateProcessTap(description, &tap))
            guard let format = property(tap, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription()), format.mFormatID == kAudioFormatLinearPCM,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 else {
                throw NSError(domain: "lml.tap.format", code: 1)
            }
            let config: [String: Any] = [kAudioAggregateDeviceNameKey: "LiveMeetingListener", kAudioAggregateDeviceUIDKey: "lml-\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]]
            try checkAudio(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate))
            let sink = sink, clock = clock, sampleRate = format.mSampleRate, runID = UUID()
            try checkAudio(AudioDeviceCreateIOProcIDWithBlock(&io, aggregate, nil) { @Sendable _, data, timestamp, _, _ in
                let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: data))
                guard let first = buffers.first, first.mNumberChannels > 0 else { return }
                let count = Int(first.mDataByteSize) / (4 * Int(first.mNumberChannels))
                guard count > 0 else { return }
                var mono = [Float](repeating: 0, count: count); var channels = 0
                for buffer in buffers {
                    guard let bytes = buffer.mData else { continue }
                    let channelCount = Int(buffer.mNumberChannels)
                    guard channelCount > 0, Int(buffer.mDataByteSize) >= count * channelCount * 4 else { continue }
                    let samples = bytes.assumingMemoryBound(to: Float.self)
                    for frame in 0..<count { for channel in 0..<channelCount { mono[frame] += samples[frame * channelCount + channel] } }
                    channels += channelCount
                }
                guard channels > 0 else { return }
                for index in mono.indices { mono[index] /= Float(channels) }
                let start = clock.date(hostTime: timestamp.pointee.mHostTime, fallbackDuration: Double(count) / sampleRate)
                sink(AudioChunk(samples: mono, sampleRate: sampleRate, at: start, runID: runID))
            })
            try checkAudio(AudioDeviceStart(aggregate, io))
        } catch { await stop(); throw error }
    }
    func stop() async {
        if let io { AudioDeviceStop(aggregate, io); AudioDeviceDestroyIOProcID(aggregate, io) }
        io = nil
        if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = AudioObjectID(kAudioObjectUnknown) }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap); tap = AudioObjectID(kAudioObjectUnknown) }
    }
}

@MainActor protocol MicrophoneSource: AnyObject {
    var isOpen: Bool { get }
    /// A count that grows while the device delivers audio. Capture restarts a mic whose count stops growing.
    var delivered: Int { get }
    func start(on device: AudioDeviceID, restart: Bool) throws
    func stop()
    func dispose()
}

/// Reads the chosen input device through its own IOProc, in the format the device reports. AVAudioEngine's input
/// node kept a sample rate from another device after a switch (AirPods), so its tap could never be installed.
@MainActor final class MicSource: MicrophoneSource {
    private let clock: CaptureClock
    private let sink: @Sendable (AudioChunk) -> Void
    private var device = AudioDeviceID(kAudioObjectUnknown)
    private var io: AudioDeviceIOProcID?
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var runState = MicCaptureState()
    private let frames = OSAllocatedUnfairLock(initialState: 0)
    var onConfigurationChange: (() -> Void)?
    var onRunEnd: (() -> Void)?
    init(clock: CaptureClock, sink: @escaping @Sendable (AudioChunk) -> Void) {
        self.clock = clock; self.sink = sink
    }
    var isOpen: Bool { io != nil }
    var delivered: Int { frames.withLock { $0 } }
    func start(on device: AudioDeviceID, restart: Bool = false) throws {
        var next = runState
        guard next.update(device: device, restart: restart) else { return }
        stop()
        do { try open(device, run: next) } catch { stop(); throw error }
    }
    private func open(_ device: AudioDeviceID, run next: MicCaptureState) throws {
        let streams = objectList(device, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput)
        guard !streams.isEmpty else { throw NSError(domain: "lml.mic.format", code: 1) }
        self.device = device
        watch(device, kAudioDevicePropertyNominalSampleRate)
        watch(device, kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeInput)
        watch(device, kAudioDevicePropertyDeviceIsAlive)
        watch(device, kAudioDevicePropertyIOStoppedAbnormally)
        for stream in streams { watch(stream, kAudioStreamPropertyVirtualFormat) }
        // Every input buffer is read as Float32 at one rate, so every input stream must deliver that.
        let formats = streams.map { property($0, kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription()) }
        guard let format = formats.first ?? nil else { throw NSError(domain: "lml.mic.format", code: 1) }
        for candidate in formats {
            guard let candidate, candidate.mFormatID == kAudioFormatLinearPCM, candidate.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  candidate.mBitsPerChannel == 32, candidate.mSampleRate > 0, candidate.mSampleRate == format.mSampleRate else {
                throw NSError(domain: "lml.mic.format", code: 3, userInfo: [NSLocalizedDescriptionKey: "\(formats)"])
            }
        }
        let sink = sink, clock = clock, frames = frames, sampleRate = format.mSampleRate, runID = next.runID
        try checkAudio(AudioDeviceCreateIOProcIDWithBlock(&io, device, nil) { @Sendable _, input, inputTime, output, _ in
            for buffer in UnsafeMutableAudioBufferListPointer(output) { if let bytes = buffer.mData { memset(bytes, 0, Int(buffer.mDataByteSize)) } }
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = buffers.first, first.mNumberChannels > 0 else { return }
            let count = Int(first.mDataByteSize) / (4 * Int(first.mNumberChannels))
            guard count > 0 else { return }
            frames.withLock { $0 &+= count }
            var mono = [Float](repeating: 0, count: count); var channels = 0
            for buffer in buffers {
                guard let bytes = buffer.mData else { continue }
                let channelCount = Int(buffer.mNumberChannels)
                guard channelCount > 0, Int(buffer.mDataByteSize) >= count * channelCount * 4 else { continue }
                let samples = bytes.assumingMemoryBound(to: Float.self)
                for frame in 0..<count { for channel in 0..<channelCount { mono[frame] += samples[frame * channelCount + channel] } }
                channels += channelCount
            }
            guard channels > 0 else { return }
            for index in mono.indices { mono[index] /= Float(channels) }
            let host = inputTime.pointee.mFlags.contains(.hostTimeValid) ? inputTime.pointee.mHostTime : 0
            sink(AudioChunk(samples: mono, sampleRate: sampleRate, at: clock.date(hostTime: host, fallbackDuration: Double(count) / sampleRate), runID: runID))
        })
        runState = next
        try checkAudio(AudioDeviceStart(device, io))
    }
    /// A rate or format change (AirPods moving to their call profile), or IO the device stopped, restarts the mic.
    private func watch(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in Task { @MainActor in self?.onConfigurationChange?() } }
        if AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block) == noErr { listeners.append((object, address, block)) }
    }
    func stop() {
        for (object, address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, DispatchQueue.main, block)
        }
        listeners = []
        if let io {
            AudioDeviceStop(device, io); AudioDeviceDestroyIOProcID(device, io)
            self.io = nil; onRunEnd?()
        }
        device = AudioDeviceID(kAudioObjectUnknown)
        runState.update(device: nil)
    }
    func dispose() { stop() }
}

@MainActor final class SCKSource: NSObject, SystemAudioSource, SCStreamOutput {
    private var stream: SCStream?
    nonisolated private let clock: CaptureClock
    nonisolated private let sink: @Sendable (AudioChunk) -> Void
    nonisolated private let runState = Mutex(UUID())
    init(clock: CaptureClock, sink: @escaping @Sendable (AudioChunk) -> Void) { self.clock = clock; self.sink = sink }
    func start() async throws {
        runState.withLock { $0 = UUID() }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else { throw NSError(domain: "lml.sck.display", code: 1) }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = 2; config.height = 2; config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.capturesAudio = true; config.excludesCurrentProcessAudio = true; config.sampleRate = 48000; config.channelCount = 2
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        self.stream = stream
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .utility))
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
            try await stream.startCapture()
        } catch { await stop(); throw error }
    }
    func stop() async { try? await stream?.stopCapture(); stream = nil }
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, buffer.isValid, let description = CMSampleBufferGetFormatDescription(buffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              asbd.mBitsPerChannel == 32, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { return }
        let capacity = MemoryLayout<AudioBufferList>.size + max(0, Int(asbd.mChannelsPerFrame) - 1) * MemoryLayout<AudioBuffer>.size
        let list = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: capacity / MemoryLayout<AudioBufferList>.size + 1)
        defer { list.deallocate() }
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(buffer, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: capacity, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment), blockBufferOut: &block) == noErr else { return }
        let count = CMSampleBufferGetNumSamples(buffer); var mono = [Float](repeating: 0, count: count); var channels = 0
        for audio in UnsafeMutableAudioBufferListPointer(list) {
            guard let bytes = audio.mData else { continue }
            let n = Int(audio.mNumberChannels), samples = bytes.assumingMemoryBound(to: Float.self)
            guard Int(audio.mDataByteSize) >= count * n * 4 else { continue }
            for frame in 0..<count { for channel in 0..<n { mono[frame] += samples[frame * n + channel] } }; channels += n
        }
        guard channels > 0 else { return }
        for index in mono.indices { mono[index] /= Float(channels) }
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
        let host = pts.isFinite && pts > 0 ? AudioConvertNanosToHostTime(UInt64(pts * 1e9)) : 0
        sink(AudioChunk(samples: mono, sampleRate: asbd.mSampleRate, at: clock.date(hostTime: host, fallbackDuration: Double(count) / asbd.mSampleRate), runID: runState.withLock { $0 }))
    }
}
