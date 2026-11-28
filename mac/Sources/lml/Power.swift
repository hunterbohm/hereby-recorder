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

/// Permission state read without prompting, and the requests that prompt. Both run in the app's own process, so macOS
/// files the grant under this app (a request from a terminal is filed under the terminal).
enum CapturePermissions {
    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
    private static let preflight: Preflight? = tcc("TCCAccessPreflight").map { unsafeBitCast($0, to: Preflight.self) }
    private static let request: Request? = tcc("TCCAccessRequest").map { unsafeBitCast($0, to: Request.self) }
    private static func tcc(_ name: String) -> UnsafeMutableRawPointer? {
        dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW).flatMap { dlsym($0, name) }
    }

    /// TCC's own answer, which changes the moment a switch flips in System Settings. Nil when the system can't say.
    private static func live(_ service: String) -> Grant? {
        switch preflight?(service as CFString, nil) {
        case 0: .granted
        case 1: .denied
        case 2: .notAsked
        default: nil
        }
    }

    static func state(_ backend: Config.Backend, screenContext: Bool) -> AccessState {
        let microphone: Grant = switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notAsked
        default: .denied
        }
        switch backend {
        case .tap: return AccessState(microphone: microphone, systemAudio: live("kTCCServiceAudioCapture") ?? .granted,
                                      screen: screenContext ? screen() : nil)
        case .sck: return AccessState(microphone: microphone, systemAudio: screen(), audioFromScreen: true)
        }
    }

    /// `CGPreflightScreenCaptureAccess` keeps its first answer for the life of the process, so a grant made while the
    /// app runs shows only in TCC's live answer, and capture works only after a restart.
    private static func screen() -> Grant {
        if CGPreflightScreenCaptureAccess() { return .granted }
        let state = live("kTCCServiceScreenCapture") ?? .notAsked
        return state == .granted ? .restart : state
    }

    /// Shows the system prompt when `permission` was never asked; otherwise does nothing.
    @MainActor static func ask(_ permission: Permission, backend: Config.Backend) async {
        switch (permission, backend) {
        case (.microphone, _): _ = await AVCaptureDevice.requestAccess(for: .audio)
        case (.systemAudio, .tap):
            if let request {
                await withCheckedContinuation { done in request("kTCCServiceAudioCapture" as CFString, nil) { _ in done.resume() } }
            } else {
                // Without TCC's request call, starting a tap is what prompts.
                let tap = TapSource(clock: CaptureClock(), sink: { _ in })
                try? await tap.start(); try? await Task.sleep(for: .seconds(2)); await tap.stop()
            }
        case (.systemAudio, .sck), (.screen, _): _ = CGRequestScreenCaptureAccess()
        }
    }
}
