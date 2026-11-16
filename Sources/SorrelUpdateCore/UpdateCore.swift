// Shared between Sorrel (sandboxed) and SorrelUpdater (the unsandboxed XPC service that replaces the app).
// See CLAUDE.md, Updates.
import CryptoKit
import Foundation

public enum UpdateConfig {
    /// The GitHub repository that holds releases, as "owner/name". tools/release.sh publishes there and
    /// warns if the git remote points somewhere else. Changing it only affects copies built afterwards.
    public static let repository = "elijohn248-ship-it/sorrel"
    /// "latest" always redirects to the newest published (non-draft, non-prerelease) release.
    public static let feedURL = URL(string: "https://github.com/\(repository)/releases/latest/download/updates.json")!
    /// Ed25519 public key (base64). The private key lives only on the owner's Mac (tools/update-sign.swift).
    public static let publicKey = "N5SD750ssLxS6NOAd5+LyyxJohV+FSrmAtrtlVoeG8c="
}

/// updates.json, written by tools/release.sh and read by installed copies.
public struct UpdateManifest: Codable, Sendable {
    /// Marketing version, shown to people ("0.2.0").
    public var version: String
    /// CFBundleVersion, a whole number that goes up by one per release. The only thing compared.
    public var build: Int
    public var minimumSystemVersion: String?
    /// The zip of the app bundle (ditto --keepParent).
    public var url: URL
    public var size: Int?
    public var sha256: String?
    /// Ed25519 signature of the zip, base64.
    public var signature: String
    public var date: String?
    public var notes: String?

    public init(version: String, build: Int, minimumSystemVersion: String? = nil, url: URL, size: Int? = nil,
                sha256: String? = nil, signature: String, date: String? = nil, notes: String? = nil) {
        self.version = version; self.build = build; self.minimumSystemVersion = minimumSystemVersion; self.url = url
        self.size = size; self.sha256 = sha256; self.signature = signature; self.date = date; self.notes = notes
    }

    public func runsOnThisMac() -> Bool {
        guard let min = minimumSystemVersion else { return true }
        let parts = min.split(separator: ".").compactMap { Int($0) }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let have = [v.majorVersion, v.minorVersion, v.patchVersion]
        for (i, p) in parts.enumerated() {
            let h = i < have.count ? have[i] : 0
            if h != p { return h > p }
        }
        return true
    }
}

public enum UpdateSigning {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
        public init(_ d: String) { description = d }
    }

    /// Checks the archive against the embedded public key (and the sha256 / size when the manifest has them).
    /// Reads the whole file: update archives are a few tens of megabytes at most.
    public static func verify(file: URL, signature: String, sha256: String? = nil, size: Int? = nil,
                              publicKey: String = UpdateConfig.publicKey) throws {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        try verify(data: data, signature: signature, sha256: sha256, size: size, publicKey: publicKey)
    }

    /// The same check on bytes already in memory. The updater service uses this so that the bytes it checked
    /// are the bytes it installs: re-reading a file the app can write would let the app swap it in between.
    public static func verify(data: Data, signature: String, sha256: String? = nil, size: Int? = nil,
                              publicKey: String = UpdateConfig.publicKey) throws {
        if let size, data.count != size { throw Failure("The download is \(data.count) bytes, expected \(size)") }
        if let sha256 {
            let got = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if got != sha256.lowercased() { throw Failure("The download's checksum doesn't match") }
        }
        guard let pub = Data(base64Encoded: publicKey), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pub) else {
            throw Failure("The built-in update key is unusable")
        }
        guard let sig = Data(base64Encoded: signature), key.isValidSignature(sig, for: data) else {
            throw Failure("The update's signature doesn't match Sorrel's key")
        }
    }
}

/// What an app bundle on disk says about itself.
public struct BundleInfo {
    public var identifier: String
    public var version: String
    public var build: Int

    public init?(appURL: URL) {
        let plist = appURL.appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: plist), let id = dict["CFBundleIdentifier"] as? String,
              let build = Int((dict["CFBundleVersion"] as? String) ?? "") else { return nil }
        identifier = id
        version = (dict["CFBundleShortVersionString"] as? String) ?? "?"
        self.build = build
    }

    public static var current: BundleInfo? { BundleInfo(appURL: Bundle.main.bundleURL) }
}

/// The XPC service's interface. The sandboxed app may only ask it to install an archive the service itself
/// verifies against the built-in key, over the app bundle that contains the service. The service works out
/// that bundle's location itself; it never takes a path from the app (see SorrelUpdater/main.swift).
///
/// The archive and the log arrive as files the app has already opened, not paths: macOS's app-data protection
/// (TCC `SystemPolicyAppDataDetailed`) refuses the service any path inside the app's container, where both
/// live (found 2026-11-16; every real install was refused). An open file also means the service can only ever
/// write where the sandboxed app itself could.
@objc(SorrelUpdaterXPC) public protocol SorrelUpdaterXPC {
    /// Reads and checks the archive, keeps a private copy, then starts a detached installer that waits for
    /// `pid` to exit, swaps the app for the archive's bundle, and opens it again if `relaunch`. `log` is the
    /// app's Updates/update.log, opened for appending. Replies with nil, or a sentence saying what refused.
    func install(zip: FileHandle, signature: String, pid: Int32, relaunch: Bool, log: FileHandle,
                 reply: @escaping (String?) -> Void)
}

public enum UpdaterService {
    /// The service's bundle id is the app's plus this suffix (build.sh derives its Info.plist that way).
    public static let suffix = ".updater"
}
