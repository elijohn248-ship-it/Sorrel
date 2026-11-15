// Signs Sorrel update archives so installed copies can check that an update really came from the owner.
//
//   swift tools/update-sign.swift keygen <key file>             make a new key pair; prints the public key
//   swift tools/update-sign.swift public <key file>             print the public key of an existing key
//   swift tools/update-sign.swift sign <key file> <file>        print the file's signature (base64)
//   swift tools/update-sign.swift verify <public key> <file> <signature>
//
// Ed25519 (CryptoKit). The private key is 32 bytes, stored base64 in <key file> (mode 600) and never in git.
// The public key is embedded in Sources/SorrelUpdateCore/UpdateCore.swift; the app and the updater service
// both refuse any archive whose signature doesn't check out against it. Losing the private key means no
// installed copy can ever accept another update, so back it up (see CLAUDE.md, Updates).
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func readKey(_ path: String) -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { fail("Can't read a signing key from \(path)") }
    return key
}

func readFile(_ path: String) -> Data {
    guard let data = FileManager.default.contents(atPath: path) else { fail("Can't read \(path)") }
    return data
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "keygen" where args.count == 2:
    let path = (args[1] as NSString).expandingTildeInPath
    if FileManager.default.fileExists(atPath: path) { fail("\(path) already exists; not overwriting a signing key") }
    let key = Curve25519.Signing.PrivateKey()
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    guard FileManager.default.createFile(atPath: path, contents: key.rawRepresentation.base64EncodedString().data(using: .utf8),
                                         attributes: [.posixPermissions: 0o600]) else { fail("Couldn't write \(path)") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "public" where args.count == 2:
    print(readKey((args[1] as NSString).expandingTildeInPath).publicKey.rawRepresentation.base64EncodedString())
case "sign" where args.count == 3:
    let key = readKey((args[1] as NSString).expandingTildeInPath)
    guard let sig = try? key.signature(for: readFile(args[2])) else { fail("Signing failed") }
    print(sig.base64EncodedString())
case "verify" where args.count == 4:
    guard let pub = Data(base64Encoded: args[1]), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pub) else { fail("Bad public key") }
    guard let sig = Data(base64Encoded: args[3]) else { fail("Bad signature") }
    if key.isValidSignature(sig, for: readFile(args[2])) { print("ok") } else { fail("signature does not match") }
default:
    fail("usage: update-sign.swift keygen <key file> | public <key file> | sign <key file> <file> | verify <public key> <file> <signature>")
}
