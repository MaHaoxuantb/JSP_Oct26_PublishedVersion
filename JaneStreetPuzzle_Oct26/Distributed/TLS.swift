import Foundation
import Crypto
import X509
import SwiftASN1
import NIOSSL
import NIOCore

struct ServerIdentity {
    let context: NIOSSLContext
    let certificate: Data
    let fingerprint: String
    /// Explicit generation helper; runtime startup uses serverCredentials instead.
    init(generatingIn directory: URL, now: Date = Date(), lifetime: TimeInterval = 365 * 86_400) throws {
        let material = try Self.generate(now: now, lifetime: lifetime)
        try self.init(certificate: material.certificate, privateKey: material.key, now: now, checkDates: false)
        try persistCredentials([(directory.appendingPathComponent("server-private-key.pem"), material.key),
                                (directory.appendingPathComponent("server-certificate.pem"), material.certificate)])
    }
    static func generate(now: Date = Date(), lifetime: TimeInterval = 365 * 86_400) throws -> (certificate: Data, key: Data) {
        let key = P256.Signing.PrivateKey()
        let subject = try DistinguishedName { CommonName("Jane Street Puzzle Coordinator") }
        let certificate = try Certificate(
            version: .v3, serialNumber: Certificate.SerialNumber(),
            publicKey: Certificate.PublicKey(key.publicKey),
            notValidBefore: now.addingTimeInterval(-300),
            notValidAfter: now.addingTimeInterval(lifetime),
            issuer: subject, subject: subject, signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions { Critical(BasicConstraints.notCertificateAuthority)
                try ExtendedKeyUsage([.serverAuth]) },
            issuerPrivateKey: Certificate.PrivateKey(key))
        return (Data(try certificate.serializeAsPEM().pemString.utf8), Data(key.pemRepresentation.utf8))
    }
    init(certificate: Data, privateKey: Data, now: Date = Date(), checkDates: Bool = true) throws {
        let certificates = try NIOSSLCertificate.fromPEMBytes(Array(certificate))
        guard certificates.count == 1 else { throw DistributedError.message("Server identity must contain exactly one certificate.") }
        let der = try certificates[0].toDERBytes()
        let parsed = try Certificate(derEncoded: der)
        let key = try Certificate.PrivateKey(pemEncoded: String(decoding: privateKey, as: UTF8.self))
        guard parsed.publicKey == key.publicKey else { throw DistributedError.message("Server certificate and private key do not match. Credentials were not replaced.") }
        guard !checkDates || (now >= parsed.notValidBefore && now < parsed.notValidAfter) else {
            throw DistributedError.message("Server certificate is not currently valid. Explicitly rotate credentials and redistribute the public certificate.")
        }
        self.certificate = certificate
        self.fingerprint = digest(Data(der))
        var configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: certificates.map { .certificate($0) },
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(privateKey), format: .pem)))
        configuration.minimumTLSVersion = .tlsv13
        context = try NIOSSLContext(configuration: configuration)
    }
}

struct PinnedIdentity: Sendable {
    let der: [UInt8]
    let notBefore: Date
    let notAfter: Date
    init(path: String) throws {
        let certificates = try NIOSSLCertificate.fromPEMFile(path)
        guard certificates.count == 1 else { throw DistributedError.message("Pin file must contain exactly one certificate.") }
        der = try certificates[0].toDERBytes()
        let certificate = try Certificate(derEncoded: der)
        notBefore = certificate.notValidBefore; notAfter = certificate.notValidAfter
        try checkDate()
    }
    func checkDate() throws {
        guard Date() >= notBefore && Date() < notAfter else { throw DistributedError.message("Pinned certificate is not currently valid.") }
    }
    func handler() throws -> NIOSSLClientHandler {
        try checkDate()
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.minimumTLSVersion = .tlsv13
        configuration.certificateVerification = .noHostnameVerification
        let context = try NIOSSLContext(configuration: configuration)
        // This callback replaces CA/DNS verification with exact certificate identity.
        // A pin mismatch is never accepted, including for a fresh self-signed cert.
        return try NIOSSLClientHandler(context: context, serverHostname: nil, customVerificationCallback: { certificates, promise in
            let valid = certificates.count == 1 && (try? certificates[0].toDERBytes()) == der
                && Date() >= notBefore && Date() < notAfter
            promise.succeed(valid ? .certificateVerified : .failed)
        })
    }
}


extension DistributedConfig {
    var serverCertificateURL: URL {
        certificatePath.isEmpty ? URL(fileURLWithPath: stateDirectory).appendingPathComponent("server-certificate.pem") : URL(fileURLWithPath: certificatePath)
    }
    var serverPrivateKeyURL: URL {
        privateKeyPath.isEmpty ? URL(fileURLWithPath: stateDirectory).appendingPathComponent("server-private-key.pem") : URL(fileURLWithPath: privateKeyPath)
    }
    var joinTokenURL: URL {
        tokenPath.isEmpty ? URL(fileURLWithPath: stateDirectory).appendingPathComponent("join-token") : URL(fileURLWithPath: tokenPath)
    }
}

/// Validate the complete set before changing any file or opening the run database.
/// A missing old in-memory key cannot be reconstructed from the public certificate.
func serverCredentials(settings: DistributedConfig) throws -> (ServerIdentity, String) {
    let certURL = settings.serverCertificateURL, keyURL = settings.serverPrivateKeyURL, tokenURL = settings.joinTokenURL
    let paths = [certURL, keyURL, tokenURL].map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
    guard Set(paths).count == 3 else { throw DistributedError.message("Certificate, private key, and join token paths must be different.") }
    let reserved = Set(["process.lock", "web-admin-token", "recovery.key", "latest-backup.encrypted"])
    guard paths.allSatisfy({ path in
        let name = URL(fileURLWithPath: path).lastPathComponent
        return !reserved.contains(name) && !name.contains(".sqlite") && !name.hasSuffix(".encrypted")
    }) else { throw DistributedError.message("Credential paths must not replace databases, process locks, backups, recovery keys, or the separate web admin token.") }

    let exists = [certURL, keyURL, tokenURL].map { FileManager.default.fileExists(atPath: $0.path) }
    var writes: [(URL, Data)] = []
    let certificate: Data, key: Data
    if settings.credentialMode == .rotate || (settings.credentialMode == .initialize && !exists[0] && !exists[1]) {
        let material = try ServerIdentity.generate()
        certificate = material.certificate; key = material.key
        writes += [(keyURL, key), (certURL, certificate)]
    } else {
        guard exists[0] && exists[1] else {
            throw DistributedError.message("Reusable TLS identity is missing. First setup: --init-credentials. If an old certificate exists without its private key, use --rotate-credentials once and redistribute the certificate and join token. Existing files were not changed.")
        }
        certificate = try Data(contentsOf: certURL); key = try Data(contentsOf: keyURL)
    }
    let identity = try ServerIdentity(certificate: certificate, privateKey: key)
    let token: String
    if settings.credentialMode == .rotate || (settings.credentialMode == .initialize && !exists[2]) {
        token = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
        writes.append((tokenURL, Data(token.utf8)))
    } else {
        guard exists[2] else { throw DistributedError.message("Join token missing. Use --init-credentials for first setup; default startup reuses credentials without generating them.") }
        token = try readToken(settings: settings)
    }
    try persistCredentials(writes)
    return (identity, token)
}

/// Atomic per-file replacement with rollback on an ordinary write failure.
/// Abrupt power loss between files fails closed on the next key/certificate check.
private func persistCredentials(_ files: [(URL, Data)]) throws {
    let originals = try files.map { url, _ -> Data? in
        FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
    }
    var attempted = 0
    do {
        for (url, data) in files { attempted += 1; try writePrivate(data, to: url) }
    } catch {
        let failure = error
        do {
            for i in (0..<attempted).reversed() {
                if let original = originals[i] { try writePrivate(original, to: files[i].0) }
                else if FileManager.default.fileExists(atPath: files[i].0.path) { try FileManager.default.removeItem(at: files[i].0) }
            }
        } catch { throw DistributedError.message("Credential write and rollback failed; check the configured credential files before restarting: \(failure); \(error)") }
        throw failure
    }
}
