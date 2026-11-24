import Foundation
import Testing
import LMLCore
import LMLPanel
import LMLPanelFakes

private let newer = ReleaseVersion(2, 14, 0)

@MainActor
private func store(_ snapshot: RecorderSnapshot = RecorderSnapshot(), updates: FakeUpdates? = FakeUpdates()) -> PanelStore {
    PanelStore(snapshot: snapshot, actions: FakeRecorder(snapshot), clock: { at("13:00") }, updates: updates,
               updatePoll: .zero, openURL: { _ in })
}

@MainActor
struct UpdatePanelTests {
    @Test func aNewerReleaseShowsTheQuietRow() async {
        let store = store()
        #expect(store.update == nil)
        await store.checkForUpdate()
        #expect(store.update == .available(newer))
    }

    @Test func noNewerReleaseOrNoCloneShowsNothing() async {
        let none = store(updates: FakeUpdates(newer: nil))
        await none.checkForUpdate()
        #expect(none.update == nil)
        let unstamped = store(updates: nil)
        await unstamped.checkForUpdate()
        await unstamped.startUpdate()
        #expect(unstamped.update == nil)
    }

    @Test func aCallRefusesWithTheReasonAndClosingThePanelClearsIt() async {
        for snapshot in [RecorderSnapshot(phase: .recording, sid: "20261026-150000-440d"), RecorderSnapshot(phase: .paused),
                         RecorderSnapshot(phase: .armed)] {
            let updates = FakeUpdates()
            let store = store(snapshot, updates: updates)
            await store.checkForUpdate()
            await store.startUpdate()
            #expect(store.update == .refused(newer, .inCall))
            #expect(updates.starts.map(\.inCall) == [true])
            store.panelClosed()
            #expect(store.update == .available(newer))
        }
    }

    @Test func aHeldCallCountsAsACall() async {
        var held = RecorderSnapshot(phase: .ended, sid: "20261026-150000-440d")
        held.heldUntil = at("13:05")
        let updates = FakeUpdates()
        let store = store(held, updates: updates)
        await store.checkForUpdate()
        await store.startUpdate()
        #expect(store.update == .refused(newer, .inCall))
    }

    @Test func theCloneRefusalsShowTheirOwnLine() async {
        for refusal in [UpdateRefusal.uncommitted, .notOnTag, .noCheckout, .running] {
            let updates = FakeUpdates()
            updates.refuse(refusal)
            let store = store(updates: updates)
            await store.checkForUpdate()
            await store.startUpdate()
            #expect(store.update == .refused(newer, refusal))
            #expect(updates.starts.map(\.inCall) == [false])
            #expect(!PanelCopy.updateRefusal(refusal).isEmpty)
        }
    }

    @Test func aFailedJobShowsTheLogPath() async {
        let updates = FakeUpdates()
        updates.progress(.running, .running, .failed)
        let store = store(updates: updates)
        await store.checkForUpdate()
        await store.startUpdate()
        #expect(store.update == .failed(newer, log: updates.logPath))
        // A later check for the same release keeps the failure on screen.
        await store.checkForUpdate()
        #expect(store.update == .failed(newer, log: updates.logPath))
    }

    @Test func aJobThatCouldNotStartShowsTheLogPath() async {
        let updates = FakeUpdates()
        updates.failStart()
        let store = store(updates: updates)
        await store.checkForUpdate()
        await store.startUpdate()
        #expect(store.update == .failed(newer, log: updates.logPath))
    }

    @Test func whileUpdatingTheRowShowsProgressAndChecksWait() async {
        let updates = FakeUpdates()
        let store = store(updates: updates)
        await store.checkForUpdate()
        let running = Task { await store.startUpdate() }
        while store.update != .updating(newer) { await Task.yield() }
        updates.set(newer: nil)
        await store.checkForUpdate()
        #expect(store.update == .updating(newer))
        updates.progress(.succeeded)
        await running.value
        #expect(store.update == nil)
    }
}
