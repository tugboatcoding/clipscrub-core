import CryptoKit
import Foundation
import Security

/// Per-document output mode. Redact = generic typed tokens; Pseudonymise = stable
/// keyed tokens for cross-document linkage.
public enum OutputMode: String, Codable, Sendable {
    case redact
    case pseudonymise
}

/// Holds device-local secret keys. Keys are generated on-device and never leave it.
/// `KeychainKeyStore` persists them; `InMemoryKeyStore` is for tests.
public protocol SecretKeyStore: Sendable {
    /// Fetch the key for `label`, creating + persisting a fresh 256-bit key if absent.
    func key(for label: String) throws -> SymmetricKey
}

public enum KeyStoreError: Error, Sendable {
    case unexpectedStatus(OSStatus)
}

/// In-memory key store for tests. Pass `fixed` to make tokens deterministic across
/// instances (simulates the same device key across sessions).
public final class InMemoryKeyStore: SecretKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: SymmetricKey] = [:]
    private let fixed: SymmetricKey?

    public init(fixed: SymmetricKey? = nil) {
        self.fixed = fixed
    }

    public func key(for label: String) throws -> SymmetricKey {
        if let fixed { return fixed }
        lock.lock()
        defer { lock.unlock() }
        if let existing = keys[label] { return existing }
        let created = SymmetricKey(size: .bits256)
        keys[label] = created
        return created
    }
}

/// Login-keychain-backed key store. Items are device-only and never synced/exported.
public struct KeychainKeyStore: SecretKeyStore {
    private let service: String

    public init(service: String = "com.tugboat.clipscrub.keys") {
        self.service = service
    }

    public func key(for label: String) throws -> SymmetricKey {
        if let existing = try read(label) { return existing }
        let created = SymmetricKey(size: .bits256)
        try store(created, label: label)
        return created
    }

    private func baseQuery(_ label: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: label,
        ]
    }

    private func read(_ label: String) throws -> SymmetricKey? {
        var query = baseQuery(label)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            return nil
        default:
            throw KeyStoreError.unexpectedStatus(status)
        }
    }

    private func store(_ key: SymmetricKey, label: String) throws {
        var query = baseQuery(label)
        query[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyStoreError.unexpectedStatus(status) }
    }
}

/// Derives stable, non-reversible tokens from identifier values via keyed HMAC.
///
/// The same (value, key) always yields the same token — enabling cross-document linkage
/// without revealing who the subject is. A plain unsalted hash of a low-entropy identifier
/// (SSN/MRN) is trivially reversible, so this is HMAC-SHA256 with a device-local key.
///
/// Compliance caveat: a code derived from the individual's own information
/// may not by itself satisfy HIPAA Safe Harbor — present as pseudonymisation, not certified
/// de-identification.
public struct Pseudonymiser: Sendable {
    private let key: SymmetricKey
    private let width: Int

    /// - Parameter width: token suffix length in hex chars (default 8 = 32 bits). Lower widths
    ///   collide sooner (birthday bound): 4 hex ≈ 50% collision at ~300 distinct values of one type.
    public init(key: SymmetricKey, width: Int = 8) {
        self.key = key
        self.width = max(2, width)
    }

    public func token(for value: String, type: EntityType) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: key)
        let hex = mac.map { String(format: "%02X", $0) }.joined()
        return "\(type.tokenPrefix)_\(hex.prefix(width))"
    }
}
