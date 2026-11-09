import Foundation
import AVFoundation
import CryptoKit

public enum AudioFiles {
    public static let extensions: Set<String> = ["m4a", "mp3", "wav", "caf", "aif", "aiff", "mov", "mp4"]

    public static func trackCount(_ url: URL) async throws -> Int {
        try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).count
    }

    public static func recording(at url: URL, started: Date? = nil) async throws -> Recording {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw ImportError.unreadableAudio }
        var startedAt = started
        if startedAt == nil, let item = try await asset.load(.creationDate) { startedAt = try await item.load(.dateValue) }
        if startedAt == nil {
            let modified = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date ?? Date()
            startedAt = modified.addingTimeInterval(-duration)
        }
        return Recording(id: "file:sha256:" + (try sha256(url)), source: .file, title: url.lastPathComponent,
            startedAt: startedAt!, duration: duration, audio: .mixed(url), startEstimated: started == nil)
    }

    public static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func inboxFiles(_ directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            .filter { extensions.contains($0.pathExtension.lowercased()) && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public static func waitUntilSettled(_ url: URL, quiet: TimeInterval = 10, limit: TimeInterval = 900) async throws -> Bool {
        let deadline = Date().addingTimeInterval(limit)
        while true {
            let modified = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date ?? .distantPast
            if Date().timeIntervalSince(modified) >= quiet { return true }
            guard Date() < deadline else { return false }
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    @discardableResult public static func archive(_ file: URL, inbox: URL) throws -> URL {
        let imported = inbox.appendingPathComponent("Imported")
        try FileManager.default.createDirectory(at: imported, withIntermediateDirectories: true)
        let base = file.deletingPathExtension().lastPathComponent, ext = file.pathExtension
        var destination = imported.appendingPathComponent(file.lastPathComponent)
        var number = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = imported.appendingPathComponent("\(base) \(number)").appendingPathExtension(ext)
            number += 1
        }
        try FileManager.default.moveItem(at: file, to: destination)
        return destination
    }
}
