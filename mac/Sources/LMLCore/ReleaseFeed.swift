import CryptoKit
import Foundation

/// The newest signed release, as `appcast.json` on the release page describes it. `mac/scripts/release.sh` writes it with
/// `lml-release feed`; `ReleaseUpdater` reads it. The signature is Ed25519 over the zip's bytes, the same scheme as
/// Sparkle's `sparkle:edSignature`, so the keys would carry over to Sparkle unchanged.
public struct ReleaseFeed: Codable, Sendable, Equatable {
    public var version: ReleaseVersion
    /// The notarized, stapled app, zipped with `ditto -c -k --keepParent`.
    public var url: URL
    public var length: Int
    public var ed_signature: String
    public var minimum_system_version: String

    public init(version: ReleaseVersion, url: URL, length: Int, ed_signature: String, minimum_system_version: String) {
        self.version = version; self.url = url; self.length = length
        self.ed_signature = ed_signature; self.minimum_system_version = minimum_system_version
    }

    /// Nil for a feed that does not parse, names a download that is not https, or has a non-positive length.
    public static func parse(_ data: Data) -> ReleaseFeed? {
        guard let feed = try? JSONDecoder().decode(ReleaseFeed.self, from: data), feed.url.scheme == "https",
              feed.url.host?.isEmpty == false, feed.length > 0, SystemVersion(feed.minimum_system_version) != nil else { return nil }
        return feed
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// The release to offer an app at `current` on `system`: newer, and runnable here.
    public func offer(current: ReleaseVersion, system: SystemVersion) -> ReleaseVersion? {
        guard version > current, let minimum = SystemVersion(minimum_system_version), system >= minimum else { return nil }
        return version
    }
}

/// A macOS version like `26.0` or `26.1.2`.
public struct SystemVersion: Comparable, Sendable, Equatable {
    public var parts: [Int]
    public init?(_ text: String) {
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(pieces.count) else { return nil }
        var numbers: [Int] = []
        for piece in pieces {
            guard !piece.isEmpty, piece.count <= 4, piece.allSatisfy({ ("0"..."9").contains($0) }), let number = Int(piece) else { return nil }
            numbers.append(number)
        }
        parts = numbers + Array(repeating: 0, count: 3 - numbers.count)
    }

    public static var running: SystemVersion {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return SystemVersion("\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)")!
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}

/// The update signing key: an Ed25519 key, kept as base64 of its 32 raw bytes. The private half lives only in the
/// secret store (`HEREBY_UPDATE_KEY`); the public half is stamped into each signed app's Info.plist.
public enum UpdateSigning {
    public struct BadKey: Error {}

    public static func newPrivateKey() -> String { Curve25519.Signing.PrivateKey().rawRepresentation.base64EncodedString() }

    public static func publicKey(ofPrivate key: String) throws -> String {
        try privateKey(key).publicKey.rawRepresentation.base64EncodedString()
    }

    public static func sign(_ data: Data, privateKey key: String) throws -> String {
        try privateKey(key).signature(for: data).base64EncodedString()
    }

    public static func verify(_ data: Data, signature: String, publicKey: String) -> Bool {
        guard let raw = Data(base64Encoded: publicKey), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
              let signature = Data(base64Encoded: signature), signature.count == 64 else { return false }
        return key.isValidSignature(signature, for: data)
    }

    /// Whether `text` is a well-formed public key, so a bad Info.plist offers no updates instead of failing each one.
    public static func isPublicKey(_ text: String) -> Bool {
        Data(base64Encoded: text).flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) } != nil
    }

    private static func privateKey(_ text: String) throws -> Curve25519.Signing.PrivateKey {
        guard let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)), raw.count == 32 else { throw BadKey() }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    }
}
