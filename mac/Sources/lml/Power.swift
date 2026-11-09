import AVFoundation
import CoreGraphics
import Foundation
import IOKit
import IOKit.pwr_mgt
import LMLCore

/// Delays system sleep (lid close included) until `onWillSleep` returns, so a call ended by sleep is
/// closed and delivered before the network goes away.
@MainActor final class SleepWatcher {
    private static let canSleep: UInt32 = 0xE000_0270
    private static let willSleep: UInt32 = 0xE000_0280
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var root: io_connect_t = 0
    private let onWillSleep: @MainActor () async -> Void
    init(onWillSleep: @escaping @MainActor () async -> Void) {
        self.onWillSleep = onWillSleep
        root = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &port, { refcon, _, type, argument in
            guard let refcon else { return }
            let token = Int(bitPattern: argument)
            MainActor.assumeIsolated {
                Unmanaged<SleepWatcher>.fromOpaque(refcon).takeUnretainedValue().handle(type, token)
            }
        }, &notifier)
        if root != 0, let port { IONotificationPortSetDispatchQueue(port, .main) }
    }
    private func handle(_ type: UInt32, _ token: Int) {
        switch type {
        case Self.canSleep: IOAllowPowerChange(root, token)
        case Self.willSleep:
            Task { @MainActor in
                await self.onWillSleep()
                IOAllowPowerChange(self.root, token)
            }
        default: break
        }
    }
    func invalidate() {
        if root != 0 { IODeregisterForSystemPower(&notifier); IOServiceClose(root); root = 0 }
        if let port { IONotificationPortDestroy(port); self.port = nil }
    }
}

/// Holds an idle-sleep assertion while a capture runs; meeting apps hold their own, in-person capture has none.
@MainActor final class IdleSleepGuard {
    private var assertion: IOPMAssertionID?
    func hold(_ on: Bool) {
        if on, assertion == nil {
            var id = IOPMAssertionID(0)
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           "Recording a meeting" as CFString, &id) == kIOReturnSuccess { assertion = id }
        } else if !on, let id = assertion {
            IOPMAssertionRelease(id); assertion = nil
        }
    }
}

/// Permission state read without prompting.
enum CapturePermissions {
    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private static let preflight: Preflight? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW),
              let symbol = dlsym(handle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(symbol, to: Preflight.self)
    }()
    static var microphone: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    /// nil when the system cannot say.
    static func systemAudio(_ backend: Config.Backend) -> Bool? {
        switch backend {
        case .sck: return CGPreflightScreenCaptureAccess()
        case .tap:
            guard let preflight else { return nil }
            switch preflight("kTCCServiceAudioCapture" as CFString, nil) {
            case 0: return true
            case 1: return false
            default: return nil
            }
        }
    }
}
