//
//  KeyStore.swift
//  TeslaDash
//
//  把 P-256 私钥存进 Keychain（仅本机、首次解锁后可用）。
//  私钥就是车辆钥匙，绝不能写进 UserDefaults 或日志。
//

import Foundation
import CryptoKit

enum KeyStoreError: LocalizedError {
    case saveFailed(OSStatus)
    case loadFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .saveFailed(let s): return "钥匙保存失败（OSStatus \(s)）"
        case .loadFailed(let s): return "钥匙读取失败（OSStatus \(s)）"
        }
    }
}

enum KeyStore {
    private static let service = "com.tesladash.vehiclekey"
    private static let account = "p256-private-key"

    static func save(_ privateKey: P256.KeyAgreement.PrivateKey) throws {
        delete()
        let query: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        account,
            kSecValueData as String:          privateKey.rawRepresentation,
            kSecAttrAccessible as String:     kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyStoreError.saveFailed(status) }
    }

    static func load() -> P256.KeyAgreement.PrivateKey? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: data)
        else { return nil }
        return key
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    static var hasKey: Bool { load() != nil }
}
