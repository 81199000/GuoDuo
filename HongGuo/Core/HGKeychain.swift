import Foundation
import Security

/// JS 核心的小型持久存储（账号登录态、弹幕匿名标识）。存在钥匙串，仅本机、解锁后可读。
enum HGKeychain {
    private static let service = "me.rrmm.hongguo.core"

    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }

    /// 命令行自测（无 bundle id、未签名）时钥匙串写入会阻塞等授权：改用内存。
    private nonisolated(unsafe) static var memory: [String: String] = [:]
    private static var useMemory: Bool { Bundle.main.bundleIdentifier == nil }

    static func get(_ key: String) -> String? {
        if useMemory { return memory[key] }
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ key: String, _ value: String) {
        if useMemory { memory[key] = value; return }
        let data = Data(value.utf8)
        let update = [kSecValueData as String: data]
        if SecItemUpdate(query(key) as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var q = query(key)
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(q as CFDictionary, nil)
        }
    }

    static func delete(_ key: String) {
        if useMemory { memory[key] = nil; return }
        SecItemDelete(query(key) as CFDictionary)
    }
}
