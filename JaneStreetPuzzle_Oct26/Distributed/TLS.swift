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
    init(directory: URL, now: Date = Date(), lifetime: TimeInterval = 365 * 86_400) throws {
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
        let pem = try certificate.serializeAsPEM()
        self.certificate = Data(pem.pemString.utf8)
        self.fingerprint = digest(Data(pem.derBytes))
        try writePrivate(self.certificate, to: directory.appendingPathComponent("server-certificate.pem"))
        var configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: try NIOSSLCertificate.fromPEMBytes(Array(self.certificate)).map { .certificate($0) },
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(key.pemRepresentation.utf8), format: .pem)))
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
