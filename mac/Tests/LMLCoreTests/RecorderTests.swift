import CoreGraphics
import Foundation
import Testing
import Synchronization
@testable import LMLCore

private func temporary() throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString.prefix(8).description)
    try PrivateFiles.directory(directory); return directory
}

struct RecorderStoreTests {
    @Test func observeDeliversTheCurrentSnapshotThenOnlyChanges() {
        let store = RecorderStore(RecorderSnapshot(phase: .idle))
        let seen = Mutex<[RecorderPhase]>([])
        store.observe { snapshot in seen.withLock { $0.append(snapshot.phase) } }
        store.update { $0.phase = .idle }
        store.update { $0.phase = .recording; $0.sid = "20261013-190012-a3f1" }
        store.update { $0.marks = 1 }
        #expect(seen.withLock { $0 } == [.idle, .recording, .recording])
        #expect(store.snapshot.marks == 1)
    }
}

struct MeetingMatchTests {
    @Test func aCaptureTakesTheMeetingsTitleStartAndOtherPersonOnlyWhileItIsUnderway() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let meeting = PanelMeeting(title: "Weekly Sync with Dana", start: start, end: start.addingTimeInterval(2700), with: "Dana")
        var live = RecorderSnapshot(phase: .recording, sid: "20261013-190012-a3f1")
        live.match(meeting, at: start.addingTimeInterval(600))
        #expect(live.title == "Weekly Sync with Dana"); #expect(live.eventStart == start); #expect(live.themName == "Dana")
        var early = RecorderSnapshot(phase: .recording)
        early.match(meeting, at: start.addingTimeInterval(-121))
        #expect(early.title == nil); #expect(early.themName == nil)
        var paused = RecorderSnapshot(phase: .paused)
        paused.match(meeting, at: start)
        #expect(paused.themName == nil)
        var group = RecorderSnapshot(phase: .armed)
        group.match(PanelMeeting(title: "Team standup", start: start), at: start.addingTimeInterval(3600))
        #expect(group.title == "Team standup"); #expect(group.themName == nil)
    }
}

struct AskTests {
    @Test func liveAskSendsTheRequestAsJSONAndReturnsTheJoinedAnswer() async throws {
        let stdout = Data(#"{"d": "Send the "}\#n{"d": "list."}\#n{"done": true}\#n"#.utf8)
        let runner = StubRunner([0], stdout: stdout)
        let actions = ControlActions(paths: SessionPaths(root: URL(fileURLWithPath: "/tmp/lml-ask")), mini: Mini(host: "mini"), runner: runner)
        let lines = (0..<60).map { TranscriptLine(speaker: "them", text: "line \($0)", at: Date(timeIntervalSince1970: 1_800_000_000 + Double($0))) }
        let seen = Seen()
        let answer = try await actions.askLive(LiveAskRequest(kind: .say, question: "What should I say next?", sid: "20261013-190012-a3f1", lines: lines)) { seen.add($0) }
        #expect(answer == "Send the list.")
        #expect(seen.all == ["Send the list."], "a stub delivers its output in one piece")
        let command = try #require(await runner.recorded().first)
        #expect(command.arguments.suffix(2) == ["mini", "live-meeting-quick"])
        #expect(command.timeout == ControlActions.liveAskTimeout)
        let input = try #require(command.input)
        let sent = try JSON.decoder().decode(LiveAskRequest.self, from: input)
        #expect(sent.sid == "20261013-190012-a3f1")
        #expect(sent.kind == .say && sent.lines.count == ControlActions.liveLines && sent.lines.last?.text == "line 59")
        let raw = String(decoding: input, as: UTF8.self)
        #expect(raw.contains(#""kind":"say""#) && raw.contains("Z\""), "the mini reads ISO dates with a zone")
    }

    @Test func liveAskFailsOnAnErrorLineANonzeroExitOrNoDone() async throws {
        for (status, stdout) in [(Int32(1), #"{"error": "api"}"#), (0, #"{"d": "half"}"#), (0, #"{"d": "x"}\#n{"error": "forgotten"}\#n{"done": true}"#)] {
            let actions = ControlActions(paths: SessionPaths(root: URL(fileURLWithPath: "/tmp/lml-ask")), mini: Mini(host: "mini"),
                                         runner: StubRunner([status], stdout: Data((stdout + "\n").utf8)))
            await #expect(throws: RecorderError.self) { _ = try await actions.askLive(LiveAskRequest(kind: .ask, question: "q")) { _ in } }
        }
    }

    @Test func readerJoinsPiecesSplitAnywhereEvenInsideACharacter() throws {
        let reader = LiveAnswerReader()
        let bytes = Data(#"{"d": "Café "}"#.utf8) + Data("\n".utf8) + Data(#"{"d": "ok"}"#.utf8) + Data("\n{\"done\": true}\n".utf8)
        var shown: [String] = []
        for index in bytes.indices { if let text = reader.feed(bytes[index...index]) { shown.append(text) } }
        #expect(shown == ["Café ", "Café ok"])
        #expect(try reader.finish(status: 0) == "Café ok")
    }

    @Test func liveAskSendsTheScreenWhenScreenContextIsOn() async throws {
        let stdout = Data(#"{"d": "ok"}\#n{"done": true}\#n"#.utf8)
        let asked = Seen()
        for (context, kind, expected) in [(true, QuickAsk.ask, "IMG"), (false, .ask, nil), (false, .screen, "IMG")] as [(Bool, QuickAsk, String?)] {
            let runner = StubRunner([0], stdout: stdout)
            let actions = ControlActions(paths: SessionPaths(root: URL(fileURLWithPath: "/tmp/lml-ask")), mini: Mini(host: "mini"), runner: runner,
                                         screenContext: context, grab: { ask in asked.add(String(ask)); return "IMG" })
            _ = try await actions.askLive(LiveAskRequest(kind: kind, question: "q")) { _ in }
            let input = try #require(await runner.recorded().first?.input)
            #expect(try JSON.decoder().decode(LiveAskRequest.self, from: input).screen == expected)
        }
        #expect(asked.all == ["false", "true"], "only Read screen may show the permission prompt")
    }

    @Test func readScreenWithoutAPictureFailsBeforeTheMini() async throws {
        let runner = StubRunner([0])
        let actions = ControlActions(paths: SessionPaths(root: URL(fileURLWithPath: "/tmp/lml-ask")), mini: Mini(host: "mini"), runner: runner,
                                     grab: { _ in nil })
        await #expect(throws: RecorderError(reply: "no_screen")) { _ = try await actions.askLive(LiveAskRequest(kind: .screen, question: "q")) { _ in } }
        #expect(await runner.recorded().isEmpty)
    }

    @Test func screenGrabCapsTheLongSideAndKeepsTheShape() {
        #expect(ScreenGrab.scaled(width: 2560, height: 1600) == (1280, 800))
        #expect(ScreenGrab.scaled(width: 1600, height: 2560) == (800, 1280))
        #expect(ScreenGrab.scaled(width: 1024, height: 768) == (1024, 768))
    }

    @Test func screenGrabEncodesJPEG() throws {
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try #require(context.makeImage())
        let data = try #require(ScreenGrab.jpeg(image))
        #expect(data.prefix(3) == Data([0xFF, 0xD8, 0xFF]))
    }

    @Test func liveAskWithoutAMiniIsAnError() async {
        let actions = ControlActions(paths: SessionPaths(root: URL(fileURLWithPath: "/tmp/lml-ask")), mini: nil, runner: StubRunner([0]))
        await #expect(throws: RecorderError(reply: "no_mini")) { _ = try await actions.askLive(LiveAskRequest(kind: .ask, question: "q")) { _ in } }
    }

    @Test func askSendsTheQuestionOnStdinAndReturnsTheAnswer() async throws {
        let runner = StubRunner([0], stdout: Data("She said Friday.\n".utf8))
        let actions = ControlActions(paths: SessionPaths(root: URL(fileURLWithPath: "/tmp/lml-ask")), mini: Mini(host: "mini"), runner: runner)
        #expect(try await actions.ask("When is the deadline?") == "She said Friday.")
        let command = try #require(await runner.recorded().first)
        #expect(command.arguments.suffix(2) == ["mini", "live-meeting-ask"])
        #expect(command.input == Data("When is the deadline?".utf8)); #expect(command.timeout == ControlActions.askTimeout)
        let failing = ControlActions(paths: SessionPaths(root: URL(fileURLWithPath: "/tmp/lml-ask")), mini: Mini(host: "mini"), runner: StubRunner([1]))
        await #expect(throws: RecorderError.self) { _ = try await failing.ask("anything") }
    }
    @Test func askAnyMeetingAddsTheAnyFlagAndAMissingCommandIsAnError() async throws {
        let runner = StubRunner([0], stdout: Data("You promised Dana the SOP list.\n".utf8))
        let actions = ControlActions(paths: SessionPaths(root: URL(fileURLWithPath: "/tmp/lml-ask")), mini: Mini(host: "mini"), runner: runner)
        #expect(try await actions.askAnyMeeting("What do I owe Dana?") == "You promised Dana the SOP list.")
        let command = try #require(await runner.recorded().first)
        #expect(command.arguments.suffix(3) == ["mini", "live-meeting-ask", "--any"])
        #expect(command.input == Data("What do I owe Dana?".utf8)); #expect(command.timeout == ControlActions.askTimeout)
        let missing = ControlActions(paths: SessionPaths(root: URL(fileURLWithPath: "/tmp/lml-ask")), mini: Mini(host: "mini"), runner: StubRunner([127]))
        await #expect(throws: RecorderError(reply: "ask_failed status=127")) { _ = try await missing.askAnyMeeting("anything") }
    }
}

struct HermesCommandTests {
    private func actions(_ runner: StubRunner, mini: Mini? = Mini(host: "mini")) -> ControlActions {
        ControlActions(paths: SessionPaths(root: URL(fileURLWithPath: "/tmp/lml-hermes")), mini: mini, runner: runner)
    }

    @Test func optinOptoutAndChatRunMeetingBotOnTheMiniWithTheEventKey() async throws {
        let runner = StubRunner([0, 0, 0, 0], stdout: Data(#"{"ok": true}"#.utf8))
        let bot = actions(runner)
        try await bot.hermesOptIn(key: "abc123_20261023T200000Z")
        try await bot.hermesOptOut(key: "abc123_20261023T200000Z")
        try await bot.hermesChat(key: "abc123_20261023T200000Z", on: true)
        try await bot.hermesChat(key: "abc123_20261023T200000Z", on: false)
        let sent = await runner.recorded().map { command in Array(command.arguments[command.arguments.lastIndex(of: "mini")!...]) }
        let key = "abc123_20261023T200000Z"
        #expect(sent == [["mini", "meeting-bot", "optin", key], ["mini", "meeting-bot", "optout", key],
                         ["mini", "meeting-bot", "chat", key, "on"], ["mini", "meeting-bot", "chat", key, "off"]])
        let timeouts = await runner.recorded().map(\.timeout)
        #expect(timeouts.allSatisfy { $0 == ControlActions.hermesTimeout })
    }

    @Test func anEventKeyWithShellCharactersIsQuotedForTheMinisShell() async throws {
        let runner = StubRunner([0])
        try await actions(runner).hermesOptIn(key: "it's a key; rm -rf ~ $(x)")
        let command = try #require(await runner.recorded().first)
        #expect(command.arguments.suffix(3) == ["meeting-bot", "optin", "'it'\\''s a key; rm -rf ~ $(x)'"])
        #expect(ControlActions.shellQuoted("") == "''")
        #expect(ControlActions.shellQuoted("plain_key-1@x.com") == "plain_key-1@x.com")
    }

    @Test func aNonzeroExitOrNoMiniIsAnError() async {
        await #expect(throws: RecorderError(reply: "hermes_optin_failed status=1")) { try await actions(StubRunner([1])).hermesOptIn(key: "k") }
        await #expect(throws: RecorderError(reply: "hermes_chat_failed status=127")) { try await actions(StubRunner([127])).hermesChat(key: "k", on: true) }
        await #expect(throws: RecorderError(reply: "no_mini")) { try await actions(StubRunner([0]), mini: nil).hermesOptOut(key: "k") }
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["LML_SOCKET_TESTS"] != "0", "Unix socket binding requires sandbox network access"))
struct ControlActionTests {
    private func serve(_ server: ControlServer, replies: [String]) -> Task<[ControlCommand], Error> {
        Task {
            var received: [ControlCommand] = []
            for reply in replies {
                var connection: ControlConnection?
                for _ in 0..<500 where connection == nil {
                    connection = try await server.acceptCommand()
                    if connection == nil { try await Task.sleep(for: .milliseconds(5)) }
                }
                let accepted = try #require(connection)
                received.append(accepted.command)
                try accepted.reply(reply)
            }
            return received
        }
    }
    @Test func panelActionsTravelOverTheControlSocket() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let server = try ControlServer(root: root)
        let actions = ControlActions(paths: SessionPaths(root: root), mini: Mini(host: "mini"))
        let served = serve(server, replies: ["pause", "start", "mark", "not_recording", "forgotten"])
        try await actions.pause()
        try await actions.startInPerson()
        try await actions.markMoment(note: "pricing")
        await #expect(throws: RecorderError(reply: "not_recording")) { try await actions.markMoment(note: nil) }
        try await actions.forget(sid: "20261013-190012-a3f1")
        let commands = try await served.value
        #expect(commands.map(\.action) == [.pause, .start, .mark, .mark, .forget])
        #expect(commands[1].kind == .inPerson); #expect(commands[2].note == "pricing"); #expect(commands[3].note == nil)
        #expect(commands[4].sid == "20261013-190012-a3f1")
    }
    @Test func pingAsksTheRunningRecorderForItsPidAndChangesNothing() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let server = try ControlServer(root: root)
        let served = serve(server, replies: [ControlCommand.pingReply(pid: 4242), "paused"])
        #expect(try await ControlClient.ping(root: root) == 4242)
        await #expect(throws: POSIXError.self) { _ = try await ControlClient.ping(root: root) }
        #expect(try await served.value.map(\.action) == [.ping, .ping])
    }
    private func send(_ line: String, root: URL, close: Bool = true) throws -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0); defer { Darwin.close(fd) }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let path = root.appendingPathComponent("control.sock").path
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        try #require(connected == 0)
        _ = (line + "\n").withCString { write(fd, $0, strlen($0)) }
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = read(fd, &buffer, buffer.count)
        return count > 0 ? String(decoding: buffer[0..<count], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }
    @Test func anUnknownActionBadJsonOrASilentClientNeverStopsTheServer() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let server = try ControlServer(root: root)
        let replies = Task.detached { () -> [String] in
            [try self.send(#"{"action":"frobnicate"}"#, root: root), try self.send("not json", root: root),
             try self.send(#"{"action":"ping"}"#, root: root)]
        }
        var accepted: ControlConnection?
        for _ in 0..<600 where accepted == nil {
            accepted = try await server.acceptCommand()
            if accepted == nil { try await Task.sleep(for: .milliseconds(5)) }
        }
        let connection = try #require(accepted)
        #expect(connection.command.action == .ping)
        try connection.reply(ControlCommand.pingReply(pid: 7))
        #expect(try await replies.value == ["bad_request", "bad_request", "pong 7"])
        let silent = socket(AF_UNIX, SOCK_STREAM, 0); defer { Darwin.close(silent) }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let path = root.appendingPathComponent("control.sock").path
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(silent, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        var next: ControlConnection?
        for _ in 0..<400 where next == nil {
            next = try await server.acceptCommand()
            if next == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(next == nil)
    }
    @Test func capabilitiesNamePingAndEveryOtherAction() {
        #expect(ControlCommand.Action.allCases.map(\.rawValue).sorted() == ["forget", "mark", "pause", "ping", "resume", "start", "stop"])
    }
    @Test func onlyAWellFormedPongNamesAProcess() {
        #expect(ControlCommand.pingPID("pong 4242") == 4242)
        for reply in ["", "pong", "pong 0", "pong 1", "pong -5", "pong x", "pong 12 13", "pause", "failed"] { #expect(ControlCommand.pingPID(reply) == nil) }
    }
    @Test func longNotesAreCappedToFitOneControlLine() throws {
        let command = ControlCommand(action: .mark, note: String(repeating: "é", count: 5000))
        #expect(command.note?.count == ControlCommand.noteLimit)
        #expect(try JSON.encoder().encode(command).count < 16384)
    }
}

final class Seen: Sendable {
    private let values = Mutex<[String]>([])
    func add(_ value: String) { values.withLock { $0.append(value) } }
    var all: [String] { values.withLock { $0 } }
}
