import Foundation

/// Where Ask and the live buttons run the `mini/` helper scripts: on the mini over ssh, or on this Mac against its
/// own session folder when there is no mini.
public enum MeetingHelpers: Sendable, Equatable {
    case remote(Mini)
    case local(scripts: URL, root: URL)

    /// The recorder's LaunchAgent has no PATH, and Python 3.11 and the agent's tools are not in /usr/bin.
    public static func path(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        home.appendingPathComponent(".local/bin").path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    }

    /// The `mini` folder beside the checkout this binary was built in, or the copy in the app's Resources.
    public static func locate(executable: URL, fileManager: FileManager = .default) -> URL? {
        locateBeside(executable: executable, ["mini/live-meeting-ask", "Resources/mini/live-meeting-ask"], fileManager: fileManager)?
            .deletingLastPathComponent()
    }

    /// The mini when there is one, else the scripts on this Mac. Nil when neither is available.
    public static func resolve(_ settings: Settings, paths: SessionPaths, executable: URL) -> MeetingHelpers? {
        if let mini = settings.mini { return .remote(mini) }
        return locate(executable: executable).map { .local(scripts: $0, root: paths.root) }
    }

    public func command(paths: SessionPaths, _ name: String, _ arguments: [String], input: Data? = nil, timeout: TimeInterval) -> ProcessCommand {
        switch self {
        case .remote(let mini):
            return Outbox.remoteCommand(paths: paths, mini: mini, name, arguments, input: input, timeout: timeout)
        case .local(let scripts, let root):
            // Nothing writes bytecode into the signed app's Resources.
            let environment = ["PATH=\(Self.path())", "PYTHONDONTWRITEBYTECODE=1", "LML_ROOT=\(root.path)"]
            return ProcessCommand("/usr/bin/env", environment + ["python3", scripts.appendingPathComponent(name).path] + arguments,
                                  input: input, timeout: timeout)
        }
    }
}
