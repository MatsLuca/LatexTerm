import Foundation
import Security

/// Menschen-Token der Myzel-Kachel im macOS-Schlüsselbund (erste Schlüsselbund-Nutzung der App). Konto = Server-Host,
/// damit ein zweiter Server später ein eigenes Token haben kann. Das Token verlässt die App nur als
/// `Authorization`-Kopf an genau diesen Host.
enum MyzelKeychain {
    private static let service = "LatexTerm Myzel"

    static func token(host: String) -> String? {
        var query = base(host)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func store(_ token: String, host: String) -> Bool {
        let data = Data(token.utf8)
        let update = SecItemUpdate(base(host) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var add = base(host)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecAttrLabel as String] = "LatexTerm Myzel (\(host))"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func remove(host: String) {
        SecItemDelete(base(host) as CFDictionary)
    }

    /// Menschen-Token haben die Form `mzm_` + 64 Hex-Zeichen (PROTOKOLL §6.1).
    static func looksValid(_ token: String) -> Bool {
        token.count == 68 && token.hasPrefix("mzm_") && token.dropFirst(4).allSatisfy(\.isHexDigit)
    }

    private static func base(_ host: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: host]
    }
}
