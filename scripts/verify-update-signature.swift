import CryptoKit
import Foundation

// Verify against the public key embedded in the distributed app, not just the signing key.
guard CommandLine.arguments.count == 4,
      let publicKey = Data(base64Encoded: CommandLine.arguments[1]),
      let signature = Data(base64Encoded: CommandLine.arguments[3]) else {
    fatalError("Expected public key, archive path and signature")
}
let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]), options: .mappedIfSafe)
guard key.isValidSignature(signature, for: archive) else {
    fputs("Update signature does not match the app's public key.\n", stderr)
    exit(1)
}
