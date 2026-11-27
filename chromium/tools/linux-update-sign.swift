// The Linux test feed uses its own Ed25519 key, kept on the release Mac.
import CryptoKit
import Darwin
import Foundation

let usage = """
usage: linux-update-sign.swift init --key FILE --public FILE
       linux-update-sign.swift public --key FILE --public FILE
       linux-update-sign.swift sign --key FILE --input FILE --output FILE
       linux-update-sign.swift verify --public FILE --input FILE --signature FILE
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func writeNew(_ bytes: Data, to path: String) throws {
    try bytes.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
}

func createKey(_ bytes: Data, at path: String) throws {
    let parent = (path as NSString).deletingLastPathComponent
    let folder = URL(fileURLWithPath: parent.isEmpty ? "." : parent, isDirectory: true)
    var template = folder.appendingPathComponent(".linux-test-key.XXXXXX").path.utf8CString
    let fd = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
    guard fd >= 0 else { fail("Cannot create a private key in the destination directory.") }
    let temporaryPath = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    defer { _ = unlink(temporaryPath) }

    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    guard fchmod(fd, 0o600) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    try file.write(contentsOf: bytes)
    try file.synchronize()
    try file.close()
    guard link(temporaryPath, path) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

func loadKey(_ path: String) throws -> Curve25519.Signing.PrivateKey {
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else { fail("Cannot open the Linux test private key.") }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
          info.st_mode & 0o7777 == 0o600, info.st_uid == geteuid(), info.st_size == 32,
          let raw = try file.read(upToCount: 32), raw.count == 32 else {
        fail("The Linux test private key must be an owner-only mode 600 file with 32 raw bytes.")
    }
    return try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
}

// RFC 8410 SubjectPublicKeyInfo prefix for an Ed25519 key.
let publicPrefix = Data([0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00])
let publicHeader = "-----BEGIN PUBLIC KEY-----"
let publicFooter = "-----END PUBLIC KEY-----"

func publicPEM(_ key: Curve25519.Signing.PublicKey) -> Data {
    let bytes = (publicPrefix + key.rawRepresentation).base64EncodedString()
    return Data("\(publicHeader)\n\(bytes)\n\(publicFooter)\n".utf8)
}

func loadPublic(_ path: String) throws -> Curve25519.Signing.PublicKey {
    let lines = try String(contentsOfFile: path, encoding: .utf8).split(whereSeparator: \.isNewline)
    guard lines.count == 3, lines[0] == publicHeader, lines[2] == publicFooter,
          let der = Data(base64Encoded: String(lines[1])), der.starts(with: publicPrefix),
          der.count == publicPrefix.count + 32 else { fail("Invalid Ed25519 public key PEM.") }
    return try Curve25519.Signing.PublicKey(rawRepresentation: der.suffix(32))
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first, args.count % 2 == 1 else { fail(usage) }
var options: [String: String] = [:]
for index in stride(from: 1, to: args.count, by: 2) {
    let flag = args[index]
    guard options[flag] == nil else { fail(usage) }
    options[flag] = (args[index + 1] as NSString).expandingTildeInPath
}

if let keyPath = options["--key"], (keyPath as NSString).lastPathComponent == "update-signing-key" {
    fail("Use a separate Linux test key, not the macOS release key.")
}

do {
    switch (command, Set(options.keys)) {
    case ("init", ["--key", "--public"]):
        let keyPath = options["--key"]!
        let publicPath = options["--public"]!
        guard URL(fileURLWithPath: keyPath).standardizedFileURL != URL(fileURLWithPath: publicPath).standardizedFileURL,
              !FileManager.default.fileExists(atPath: keyPath),
              !FileManager.default.fileExists(atPath: publicPath) else { fail("Key output already exists.") }
        let key = Curve25519.Signing.PrivateKey()
        try createKey(key.rawRepresentation, at: keyPath)
        try writeNew(publicPEM(key.publicKey), to: publicPath)
    case ("public", ["--key", "--public"]):
        let key = try loadKey(options["--key"]!)
        try writeNew(publicPEM(key.publicKey), to: options["--public"]!)
    case ("sign", ["--key", "--input", "--output"]):
        let key = try loadKey(options["--key"]!)
        let payload = try Data(contentsOf: URL(fileURLWithPath: options["--input"]!))
        let envelope: [String: Any] = [
            "format": 1,
            "payload": payload.base64EncodedString(),
            "signature": try key.signature(for: payload).base64EncodedString(),
        ]
        let encoded = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        try writeNew(encoded + Data([0x0a]), to: options["--output"]!)
    case ("verify", ["--public", "--input", "--signature"]):
        let key = try loadPublic(options["--public"]!)
        let payload = try Data(contentsOf: URL(fileURLWithPath: options["--input"]!))
        let signature = try Data(contentsOf: URL(fileURLWithPath: options["--signature"]!))
        guard key.isValidSignature(signature, for: payload) else { fail("Invalid Linux test update signature.") }
    default:
        fail(usage)
    }
} catch {
    fail("Linux test signing operation failed: \(error.localizedDescription)")
}
