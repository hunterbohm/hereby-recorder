import Foundation
import LMLCore

// The release side of signed updates, run by mac/scripts/release.sh. The private key comes only from the
// HEREBY_UPDATE_KEY environment variable (inject it with `infisical run --`), never from an argument.
// Usage:
//   lml-release keygen FILE                 writes a new private key to FILE (mode 600), prints the public key
//   lml-release public-key                  prints the public key of HEREBY_UPDATE_KEY
//   lml-release feed --version vX.Y.Z --url URL --archive ZIP --minimum-system 26.0
//                                           signs ZIP and prints appcast.json
//   lml-release verify --feed FILE --archive ZIP --public-key KEY
//                                           checks a feed and zip the way the app will

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("lml-release: \(message)\n".utf8))
    exit(code)
}

func options(_ arguments: ArraySlice<String>, _ names: Set<String>) -> [String: String] {
    var values: [String: String] = [:]
    var rest = arguments
    while let name = rest.popFirst() {
        guard names.contains(name), let value = rest.popFirst() else { fail("unexpected argument \(name)", code: 2) }
        values[name] = value
    }
    guard values.count == names.count else { fail("needs \(names.sorted().joined(separator: " "))", code: 2) }
    return values
}

func privateKey() -> String {
    guard let key = ProcessInfo.processInfo.environment["HEREBY_UPDATE_KEY"], !key.isEmpty else {
        fail("HEREBY_UPDATE_KEY is not set; run under `infisical run --`")
    }
    return key
}

func read(_ path: String) -> Data {
    guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }
    return data
}

let arguments = CommandLine.arguments.dropFirst()
switch arguments.first {
case "keygen":
    guard arguments.count == 2, let path = arguments.last else { fail("usage: lml-release keygen FILE", code: 2) }
    guard !FileManager.default.fileExists(atPath: path) else { fail("\(path) exists; not overwriting a key") }
    let key = UpdateSigning.newPrivateKey()
    guard FileManager.default.createFile(atPath: path, contents: Data(key.utf8), attributes: [.posixPermissions: 0o600]) else {
        fail("cannot write \(path)")
    }
    print(try UpdateSigning.publicKey(ofPrivate: key))
case "public-key":
    guard let key = try? UpdateSigning.publicKey(ofPrivate: privateKey()) else { fail("HEREBY_UPDATE_KEY is not a valid key") }
    print(key)
case "feed":
    let values = options(arguments.dropFirst(), ["--version", "--url", "--archive", "--minimum-system"])
    guard let version = ReleaseVersion(tag: values["--version"]!) else { fail("not a release version: \(values["--version"]!)") }
    guard let url = URL(string: values["--url"]!), url.scheme == "https" else { fail("the download url must be https") }
    guard SystemVersion(values["--minimum-system"]!) != nil else { fail("not a macOS version: \(values["--minimum-system"]!)") }
    let archive = read(values["--archive"]!)
    guard let signature = try? UpdateSigning.sign(archive, privateKey: privateKey()) else { fail("HEREBY_UPDATE_KEY is not a valid key") }
    let feed = ReleaseFeed(version: version, url: url, length: archive.count, ed_signature: signature,
                           minimum_system_version: values["--minimum-system"]!)
    FileHandle.standardOutput.write(try feed.encoded() + Data("\n".utf8))
case "verify":
    let values = options(arguments.dropFirst(), ["--feed", "--archive", "--public-key"])
    guard let feed = ReleaseFeed.parse(read(values["--feed"]!)) else { fail("the feed does not parse") }
    let archive = read(values["--archive"]!)
    guard archive.count == feed.length else { fail("the zip is \(archive.count) bytes, the feed says \(feed.length)") }
    guard UpdateSigning.verify(archive, signature: feed.ed_signature, publicKey: values["--public-key"]!) else {
        fail("the signature does not match the public key")
    }
    print("ok \(feed.version.tag)")
default:
    fail("usage: lml-release keygen FILE | public-key | feed ... | verify ...", code: 2)
}
