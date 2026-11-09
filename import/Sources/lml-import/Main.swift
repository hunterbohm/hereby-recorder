import Foundation
import Darwin
import ImportCore

let usage = """
    usage: lml-import phone [--root DIR] [--notes DIR] [--since YYYY-MM-DD] [--transcript-wait MIN] [--only RECORDING_ID] [--push] [--quiet]
           lml-import file PATH... [--root DIR] [--started ISO8601] [--push] [--quiet]
           lml-import inbox DIR [--root DIR] [--push] [--quiet]
    """

struct UsageError: Error { var message: String }

struct Options {
    var positional: [String] = []
    var values: [String: String] = [:]
    var push = false

    init(_ arguments: ArraySlice<String>, valued: Set<String>) throws {
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            if argument == "--push" { push = true }
            else if argument == "--quiet" { continue }
            else if argument.hasPrefix("--") {
                let name = String(argument.dropFirst(2))
                guard valued.contains(name), let value = iterator.next(), !value.hasPrefix("--") else {
                    throw UsageError(message: "unknown or incomplete option \(argument)")
                }
                values[name] = value
            } else { positional.append(argument) }
        }
    }

    func url(_ name: String, default fallback: URL) -> URL {
        values[name].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? fallback
    }
}

@main
struct LMLImport {
    static func main() async {
        signal(SIGPIPE, SIG_IGN)
        do {
            exit(try await run(CommandLine.arguments.dropFirst()))
        } catch let error as UsageError {
            FileHandle.standardError.write(Data("lml-import: \(error.message)\n\(usage)\n".utf8)); exit(64)
        } catch {
            FileHandle.standardError.write(Data("lml-import: \(error)\n".utf8)); exit(1)
        }
    }

    nonisolated(unsafe) static var quiet = false

    static func run(_ arguments: ArraySlice<String>) async throws -> Int32 {
        quiet = arguments.contains("--quiet")
        guard let command = arguments.first else { throw UsageError(message: "missing command") }
        let rest = arguments.dropFirst()
        switch command {
        case "phone":
            let options = try Options(rest, valued: ["root", "notes", "since", "transcript-wait", "only"])
            guard options.positional.isEmpty else { throw UsageError(message: "phone takes no paths") }
            var since: Date?
            if let value = options.values["since"] {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
                guard let date = formatter.date(from: value) else { throw UsageError(message: "--since wants YYYY-MM-DD") }
                since = date
            }
            var wait = Importer.defaultTranscriptWait
            if let value = options.values["transcript-wait"] {
                guard let minutes = Double(value), minutes >= 0 else { throw UsageError(message: "--transcript-wait wants minutes") }
                wait = minutes * 60
            }
            let only = options.values["only"]
            let importer = try makeImporter(options, transcriptWait: wait)
            let scan = try await NotesReader(container: options.url("notes", default: NotesReader.defaultContainer), trackCount: AudioFiles.trackCount).scan()
            let selected = scan.recordings.filter { recording in
                (since.map { recording.startedAt >= $0 } ?? true) && (only.map { recording.id == $0 } ?? true)
            }
            let unreadable = scan.unreadable.filter { item in
                (since.map { (item.createdAt ?? .distantFuture) >= $0 } ?? true) && (only.map { item.id == $0 } ?? true)
            }
            if let only, selected.isEmpty, unreadable.isEmpty { throw UsageError(message: "no call recording \(only)") }
            var outcomes: [Outcome] = []
            for item in unreadable { outcomes.append(emit(Outcome(id: item.id, outcome: .failed, reason: item.reason))) }
            for recording in selected { outcomes.append(emit(await importer.run(recording))) }
            if only == nil {
                for outcome in await importer.pushBacklog(excluding: Set(selected.map(\.id))) { outcomes.append(emit(outcome)) }
            }
            return status(outcomes)
        case "file":
            let options = try Options(rest, valued: ["root", "started"])
            guard !options.positional.isEmpty else { throw UsageError(message: "file wants at least one path") }
            guard options.values["started"] == nil || options.positional.count == 1 else { throw UsageError(message: "--started applies to one file") }
            var started: Date?
            if let value = options.values["started"] {
                guard let date = JSON.parseDate(value) else { throw UsageError(message: "--started wants ISO8601") }
                started = date
            }
            let importer = try makeImporter(options)
            var outcomes: [Outcome] = []
            for path in options.positional {
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                outcomes.append(emit(await importFile(url, started: started, importer: importer)))
            }
            return status(outcomes)
        case "inbox":
            let options = try Options(rest, valued: ["root"])
            guard options.positional.count == 1 else { throw UsageError(message: "inbox wants one directory") }
            let inbox = URL(fileURLWithPath: (options.positional[0] as NSString).expandingTildeInPath)
            let importer = try makeImporter(options)
            var outcomes: [Outcome] = []
            var seen: Set<String> = []
            for file in try AudioFiles.inboxFiles(inbox) {
                guard try await AudioFiles.waitUntilSettled(file) else {
                    outcomes.append(emit(Outcome(id: "file:" + file.lastPathComponent, outcome: .pending, reason: "file still changing")))
                    continue
                }
                let outcome = await importFile(file, started: nil, importer: importer)
                seen.insert(outcome.id)
                if outcome.isImported { try AudioFiles.archive(file, inbox: inbox) }
                outcomes.append(emit(outcome))
            }
            for outcome in await importer.pushBacklog(excluding: seen) { outcomes.append(emit(outcome)) }
            return status(outcomes)
        default:
            throw UsageError(message: "unknown command \(command)")
        }
    }

    static func makeImporter(_ options: Options, transcriptWait: TimeInterval = Importer.defaultTranscriptWait) throws -> Importer {
        let root = ImportRoot(options.url("root", default: ImportRoot.defaultURL))
        try lock(root)
        var pusher: Pusher?
        if options.push {
            let url = Settings.url()
            guard let host = try Settings.load(url)?.sshHost else { throw SettingsError(file: url.path, field: "ssh_host", problem: "must be set to push") }
            pusher = Pusher(runner: SSHRunner(controlPath: root.url.appendingPathComponent(Mini(host: host).controlName), host: host))
        }
        return try Importer(root: root, transcriber: SpeechFileTranscriber(), pusher: pusher, transcriptWait: transcriptWait)
    }

    static func lock(_ root: ImportRoot) throws {
        try FileManager.default.createDirectory(at: root.url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(root.url.appendingPathComponent("lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    static func importFile(_ url: URL, started: Date?, importer: Importer) async -> Outcome {
        do {
            return await importer.run(try await AudioFiles.recording(at: url, started: started))
        } catch {
            let id = (try? AudioFiles.sha256(url)).map { "file:sha256:" + $0 } ?? "file:unreadable"
            return Outcome(id: id, outcome: .failed, reason: "unreadable audio file")
        }
    }

    @discardableResult static func emit(_ outcome: Outcome) -> Outcome {
        if quiet && outcome.outcome == .skipped { return outcome }
        if let line = try? JSON.encoder().encode(outcome) { FileHandle.standardOutput.write(line + Data("\n".utf8)) }
        return outcome
    }

    static func status(_ outcomes: [Outcome]) -> Int32 {
        outcomes.contains { $0.outcome == .failed } ? 1 : 0
    }
}
