import Foundation
import Security

struct KeychainReadResult: Equatable {
    let value: String?
    let status: OSStatus

    init(value: String? = nil, status: OSStatus) {
        let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.value = status == errSecSuccess && clean?.isEmpty == false ? clean : nil
        self.status = status == errSecSuccess && self.value == nil ? errSecDecode : status
    }
}



enum Keychain {
    private static let service = "com.voiceflow.mac"
    private static let interactionLock = NSLock()



    private static func withInteraction(_ allowed: Bool, _ operation: () -> OSStatus) -> OSStatus {
        interactionLock.lock()
        defer { interactionLock.unlock() }
        var previous = DarwinBoolean(false)
        let status = SecKeychainGetUserInteractionAllowed(&previous)
        guard status == errSecSuccess else { return status }
        let changed = SecKeychainSetUserInteractionAllowed(allowed)
        guard changed == errSecSuccess else { return changed }
        defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        return operation()
    }


    @discardableResult
    static func set(
        _ value: String, for account: String,
        update: (CFDictionary, CFDictionary) -> OSStatus = { query, attributes in
            withInteraction(true) { SecItemUpdate(query, attributes) }
        },
        add: (CFDictionary) -> OSStatus = { query in withInteraction(true) { SecItemAdd(query, nil) } },
        delete: (CFDictionary) -> OSStatus = { query in withInteraction(true) { SecItemDelete(query) } }
    ) -> OSStatus {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        guard !value.isEmpty else {
            return delete(base as CFDictionary)
        }



        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
        ]
        let status = update(base as CFDictionary, attributes as CFDictionary)
        guard status == errSecItemNotFound else { return status }

        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        return add(item as CFDictionary)
    }



    static func read(
        _ account: String,
        allowInteraction: Bool = false,
        copy: ((CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus)? = nil
    ) -> KeychainReadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: allowInteraction
                ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail,
        ]
        var out: CFTypeRef?
        let status: OSStatus
        if let copy {
            status = copy(query as CFDictionary, &out)
        } else {
            status = withInteraction(allowInteraction) { SecItemCopyMatching(query as CFDictionary, &out) }
        }
        guard status == errSecSuccess else { return KeychainReadResult(status: status) }
        guard let data = out as? Data else { return KeychainReadResult(status: errSecDecode) }
        return KeychainReadResult(value: String(data: data, encoding: .utf8), status: status)
    }

    static func get(_ account: String) -> String? {
        read(account).value
    }



    static func defaultKeychainHealth() -> OSStatus {
        withInteraction(false) {
            var keychain: SecKeychain?
            let status = SecKeychainCopyDefault(&keychain)
            guard status == errSecSuccess else { return status }
            var settings = SecKeychainSettings(version: UInt32(SEC_KEYCHAIN_SETTINGS_VERS1),
                                                lockOnSleep: false, useLockInterval: false, lockInterval: 0)
            return SecKeychainCopySettings(keychain, &settings)
        }
    }
}
