import CryptoKit
import Foundation
import Security

public enum PeerTrust {
    /// Trust a fixed bundle identifier signed by the same identity as this executable.
    ///
    /// Apple-issued certificates (Developer ID or Apple Development) are pinned by team identifier. A locally
    /// created, self-signed certificate carries no team, so it is pinned by its exact leaf certificate instead.
    /// Ad-hoc builds can preview the UI, but never install or talk to the privileged service.
    public static func requirement(for identifier: String) throws -> String {
        guard [ServiceIdentity.app, ServiceIdentity.helper].contains(identifier) else { throw ControlError.unsignedBuild }
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { throw ControlError.unsignedBuild }
        var information: CFDictionary?
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any]
        else { throw ControlError.unsignedBuild }
        if let team = values[kSecCodeInfoTeamIdentifier as String] as? String,
           team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil {
            return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
        }
        if let certificates = values[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certificates.first {
            let digest = Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data)
            let hash = digest.map { String(format: "%02x", $0) }.joined()
            return "identifier \"\(identifier)\" and certificate leaf = H\"\(hash)\""
        }
        throw ControlError.unsignedBuild
    }

    /// Checks a live XPC peer against a code-signing requirement.
    ///
    /// macOS 13 and later do this inside NSXPCConnection and NSXPCListener (`setCodeSigningRequirement`).
    /// macOS 12 has no such API, so this is the replacement there.
    public static func verify(_ connection: NSXPCConnection, against requirement: String) -> Bool {
        var attributes: [String: Any] = [:]
        if let token = auditToken(of: connection) {
            // Binds the check to this exact process instance, so a recycled process ID cannot pass.
            attributes[kSecGuestAttributeAudit as String] = token
        } else if connection.processIdentifier > 0 {
            // Fallback if the audit token cannot be read: still checks the signature, but by process ID.
            attributes[kSecGuestAttributePid as String] = connection.processIdentifier
        } else {
            return false
        }
        var guest: SecCode?
        var parsed: SecRequirement?
        guard SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &guest) == errSecSuccess, let guest,
              SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess, let parsed
        else { return false }
        return SecCodeCheckValidity(guest, [], parsed) == errSecSuccess
    }

    /// NSXPCConnection keeps the peer's audit token in an undocumented, long-standing property.
    private static func auditToken(of connection: NSXPCConnection) -> Data? {
        let key = "auditToken"
        guard connection.responds(to: NSSelectorFromString(key)),
              let value = connection.value(forKey: key) as? NSValue
        else { return nil }
        var size = 0
        _ = NSGetSizeAndAlignment(value.objCType, &size, nil)
        guard size == MemoryLayout<audit_token_t>.size else { return nil }
        var data = Data(count: size)
        data.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress { value.getValue(base, size: size) }
        }
        return data
    }
}
