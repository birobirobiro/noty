import Foundation
import CryptoKit
import Security
import CommonCrypto

/// A second lock, inside the first.
///
/// A locked note's text is sealed twice: once with a key derived from the
/// password someone types, and again with the master key on its way to disk.
/// The Keychain key alone will not open it, and neither will the password —
/// which is the point. Someone who copies `notes.db` off this Mac and someone
/// who guesses the password each still hold only half of it.
///
/// The salt lives in the row and never leaves this process; the derived key
/// lives only in memory, only while the note is open.
enum NoteLock {
    /// PBKDF2-HMAC-SHA256. scrypt would be the better primitive — it is
    /// memory-hard and this is not — but the platform ships no scrypt, and
    /// vendoring one to gain that property is a bigger risk than it buys here.
    ///
    /// OWASP's floor for this construction is 600k, which measured 123 ms on
    /// this machine: fast enough to be worth raising. Measured here at
    /// 1M → 152 ms, 1.2M → 182 ms, 2M → 305 ms. A third of a second is spent
    /// once, when a note is opened, and nobody notices it; it multiplies the
    /// cost of every guess by more than three.
    static let rounds: UInt32 = 2_000_000
    private static let saltBytes = 16
    private static let keyBytes = 32

    static func newSalt() -> Data {
        var salt = Data(count: saltBytes)
        let ok = salt.withUnsafeMutableBytes { raw in
            SecRandomCopyBytes(kSecRandomDefault, saltBytes, raw.baseAddress!)
        }
        return ok == errSecSuccess ? salt : Data((0..<saltBytes).map { _ in UInt8.random(in: 0...255) })
    }

    /// Deliberately slow: this is the only thing standing between a stolen
    /// database and the text, so a wrong guess has to cost real time.
    static func derive(password: String, salt: Data, rounds: UInt32 = NoteLock.rounds) -> SymmetricKey? {
        guard !password.isEmpty else { return nil }
        var out = Data(count: keyBytes)
        let pw = Array(password.utf8)
        let status = out.withUnsafeMutableBytes { outRaw -> Int32 in
            salt.withUnsafeBytes { saltRaw -> Int32 in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pw, pw.count,
                    saltRaw.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    rounds,
                    outRaw.baseAddress!.assumingMemoryBound(to: UInt8.self), keyBytes)
            }
        }
        guard status == kCCSuccess else { return nil }
        return SymmetricKey(data: out)
    }

    static func seal(_ text: String, with key: SymmetricKey) -> Data? {
        try? AES.GCM.seal(Data(text.utf8), using: key).combined
    }

    /// nil means the password was wrong — GCM's tag is what says so, so there
    /// is nothing to compare in constant time here and nothing to leak.
    static func open(_ data: Data, with key: SymmetricKey) -> String? {
        guard !data.isEmpty,
              let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return String(decoding: plain, as: UTF8.self)
    }
}
