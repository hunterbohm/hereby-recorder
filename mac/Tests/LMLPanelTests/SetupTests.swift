import Foundation
import Testing
import LMLCore
import LMLPanel
import LMLPanelFakes

func withAccess(_ access: AccessState, phase: RecorderPhase = .idle) -> RecorderSnapshot {
    var snapshot = RecorderSnapshot(phase: phase, feed: FeedBuilder.feed(at: at("09:00")))
    snapshot.access = access
    return snapshot
}

let fresh = AccessState(microphone: .notAsked, systemAudio: .notAsked, screen: .notAsked)
let allOn = AccessState(microphone: .granted, systemAudio: .granted, screen: .granted)

struct SetupContentTests {
    @Test func eachRowOffersOneActionForItsState() {
        let content = SetupContent(AccessState(microphone: .notAsked, systemAudio: .denied, screen: .restart))
        #expect(content.rows.map(\.name) == ["Microphone", "System audio", "Screen recording"])
        #expect(content.rows.map(\.action) == [.allow, .openSettings, .restart])
        #expect(content.rows.map { $0.action.map(PanelCopy.setupButton) } == ["Allow", "Open Settings", "Restart Hereby"])
        #expect(content.rows.map(\.detail) == ["To hear your side of the call", "Turn on Hereby under System Audio Recording Only",
                                               "Starts working after a restart"])
        #expect(content.rows.allSatisfy { $0.status == nil })
        #expect(content.next == .microphone)
        #expect(!content.ready)
    }

    @Test func eachRowSaysWhatItIsForUntilItIsTurnedDown() {
        let first = SetupContent(fresh)
        #expect(first.rows.map(\.detail) == ["To hear your side of the call", "To hear everyone else on the call",
                                             "Optional, so answers can see your screen"])
        #expect(SetupContent(allOn).rows.map(\.detail) == first.rows.map(\.detail), "the purpose stays once it is on")
        let denied = SetupContent(AccessState(microphone: .denied, systemAudio: .granted, screen: .denied))
        #expect(denied.rows.map(\.detail) == ["Off in System Settings", "To hear everyone else on the call", "Off in System Settings"])
    }

    @Test func theFilledButtonIsTheFirstThingToPress() {
        #expect(SetupContent(fresh).next == .microphone)
        #expect(SetupContent(fresh, asking: [.microphone]).next == .systemAudio, "not the row that is waiting on macOS")
        #expect(SetupContent(AccessState(microphone: .granted, systemAudio: .granted, screen: .notAsked)).next == .screen)
        #expect(SetupContent(AccessState(microphone: .granted, systemAudio: .granted, screen: .restart), canRestart: false).next == nil,
                "Done is filled while the restart waits for the call")
        #expect(SetupContent(allOn).next == nil)
    }

    @Test func screenAppearsOnlyWhenSomethingUsesIt() {
        let without = SetupContent(AccessState(microphone: .notAsked, systemAudio: .notAsked))
        #expect(without.rows.map(\.permission) == [.microphone, .systemAudio])
        var screenAudio = AccessState(microphone: .granted, systemAudio: .denied, audioFromScreen: true)
        #expect(SetupContent(screenAudio).rows[1].detail == "Off in System Settings", "the pane opens on the list Hereby is in")
        screenAudio.systemAudio = .granted
        #expect(SetupContent(screenAudio).complete)
    }

    @Test func readyWaitsOnlyForTheTwoACallNeeds() {
        let ready = SetupContent(AccessState(microphone: .granted, systemAudio: .granted, screen: .notAsked))
        #expect(ready.ready && !ready.complete)
        let done = SetupContent(allOn)
        #expect(done.complete)
        #expect(done.rows.allSatisfy { $0.done && $0.action == nil && $0.status == nil })
    }

    @Test func nothingToPressWhileWaiting() {
        let asking = SetupContent(fresh, asking: [.microphone])
        #expect(asking.rows[0].action == nil && asking.rows[0].status == "Waiting for macOS")
        #expect(asking.rows[1].action == .allow, "the other rows can still be pressed")
        let inCall = SetupContent(AccessState(screen: .restart), canRestart: false)
        #expect(inCall.rows[2].action == nil && inCall.rows[2].status == "Restart after the call")
        let restarting = SetupContent(AccessState(screen: .restart), restarting: true)
        #expect(restarting.rows[2].action == nil && restarting.rows[2].status == "Restarting…")
        let answered = SetupContent(AccessState(microphone: .granted, systemAudio: .notAsked), asking: [.microphone])
        #expect(answered.rows[0].status == nil, "a grant that lands before the prompt returns shows on")
    }

    @Test func settingsLinksOpenTheRightPane() {
        #expect(PanelCopy.settingsURL(.microphone).absoluteString.hasSuffix("Privacy_Microphone"))
        #expect(PanelCopy.settingsURL(.systemAudio).absoluteString.hasSuffix("Privacy_ScreenCapture"))
        #expect(PanelCopy.settingsURL(.screen).absoluteString.hasSuffix("Privacy_ScreenCapture"))
    }

    @Test func eachChannelDrawsItsOwnSteadyLine() {
        let me = PanelCopy.signal(.microphone, count: 40), them = PanelCopy.signal(.systemAudio, count: 40)
        let screen = PanelCopy.signal(.screen, count: 40)
        #expect([me, them, screen].allSatisfy { $0.count == 40 })
        #expect(me.allSatisfy { " .:|".contains($0) } && me.contains("|") && me.contains(" "))
        #expect(screen.allSatisfy { " =".contains($0) } && screen.contains("="))
        #expect(me != them)
        #expect(PanelCopy.signal(.microphone, count: 40) == me, "the same line on every render")
        #expect(PanelCopy.signal(.microphone, count: 12) == String(me.prefix(12)), "a narrower line is the same line, cut")
        #expect(PanelCopy.signal(.microphone, count: 0).isEmpty)
    }
}

@MainActor
struct SetupStoreTests {
    @Test func opensItselfAtLaunchOnlyWhenACallCantBeRecorded() {
        #expect(Harness(withAccess(fresh), now: at("09:00")).store.setupShown)
        #expect(!Harness(withAccess(allOn), now: at("09:00")).store.setupShown)
        let screenOnly = Harness(withAccess(AccessState(screen: .notAsked)), now: at("09:00"))
        #expect(!screenOnly.store.setupShown)
    }

    @Test func comesBackOnlyWhenAPermissionIsLost() {
        let h = Harness(withAccess(allOn), now: at("09:00"))
        h.store.update(withAccess(AccessState(microphone: .granted, systemAudio: .granted, screen: .denied)))
        #expect(!h.store.setupShown)
        h.store.update(withAccess(AccessState(microphone: .denied, systemAudio: .granted, screen: .denied)))
        #expect(h.store.setupShown)
        h.store.dismissSetup()
        h.store.update(withAccess(AccessState(microphone: .denied, systemAudio: .denied, screen: .denied)))
        #expect(!h.store.setupShown, "still missing is no new loss")
        h.store.update(withAccess(allOn))
        h.store.update(withAccess(AccessState(microphone: .granted, systemAudio: .denied)))
        #expect(h.store.setupShown)
    }

    @Test func aLossDuringACallWaitsForTheCallToEnd() {
        let h = Harness(withAccess(allOn, phase: .recording), now: at("09:00"))
        h.store.update(withAccess(AccessState(microphone: .denied), phase: .recording))
        #expect(!h.store.setupShown)
        h.store.update(withAccess(AccessState(microphone: .denied), phase: .ended))
        #expect(h.store.setupShown)
        let fixedFirst = Harness(withAccess(allOn, phase: .recording), now: at("09:00"))
        fixedFirst.store.update(withAccess(AccessState(microphone: .denied), phase: .recording))
        fixedFirst.store.update(withAccess(allOn, phase: .recording))
        fixedFirst.store.update(withAccess(allOn))
        #expect(!fixedFirst.store.setupShown)
    }

    @Test func allowAsksTheRecorderAndShowsWaitingUntilThePromptIsAnswered() async {
        let h = Harness(withAccess(fresh), now: at("09:00"))
        h.recorder.hold()
        let task = Task { await h.store.fixAccess(.microphone) }
        await h.waitForCall()
        #expect(h.store.asking == [.microphone])
        await h.store.fixAccess(.microphone)
        #expect(h.recorder.calls == [.requestAccess(.microphone)], "a second press while asking does nothing")
        h.recorder.release()
        await task.value
        #expect(h.store.asking.isEmpty)
        #expect(h.opened.isEmpty)
    }

    @Test func aGrantLandingClearsWaitingAtOnce() async {
        let h = Harness(withAccess(fresh), now: at("09:00"))
        h.recorder.hold()
        let task = Task { await h.store.fixAccess(.systemAudio) }
        await h.waitForCall()
        h.store.update(withAccess(AccessState(microphone: .notAsked, systemAudio: .granted, screen: .notAsked)))
        #expect(h.store.asking.isEmpty)
        h.recorder.release()
        await task.value
    }

    @Test func turnedDownOpensSettingsAndWatches() async {
        let h = Harness(withAccess(AccessState(microphone: .denied)), now: at("09:00"))
        await h.store.fixAccess(.microphone)
        #expect(h.opened.map(\.absoluteString) == [PanelCopy.settingsURL(.microphone).absoluteString])
        #expect(h.recorder.calls == [.requestAccess(.microphone)])
    }

    @Test func restartWaitsForTheCall() async {
        let inCall = Harness(withAccess(AccessState(screen: .restart), phase: .recording), now: at("09:00"))
        #expect(!inCall.store.canRestart)
        await inCall.store.fixAccess(.screen)
        #expect(inCall.recorder.calls.isEmpty)
        let idle = Harness(withAccess(AccessState(screen: .restart)), now: at("09:00"))
        await idle.store.fixAccess(.screen)
        #expect(idle.recorder.calls == [.restart])
        #expect(idle.store.restarting)
    }

    @Test func theNeedsAccessScreenOpensTheSetup() {
        let h = Harness(withAccess(allOn), now: at("09:00"))
        h.store.showSetup()
        #expect(h.store.setupShown)
        h.store.dismissSetup()
        #expect(!h.store.setupShown)
    }
}
