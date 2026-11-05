import Foundation
import Security

/// The hub session cookie (`ledger_sid`), in the Keychain.
///
/// This stores the SESSION, never the password. The password only ever exists
/// in memory for the length of one POST /api/login call, and nothing here
/// writes it anywhere. A session is a 30-day-idle, 90-day-absolute bearer
/// token the hub can revoke by deleting one row - a stolen keychain item costs
/// at most that. A stolen PASSWORD is forever until it's changed by hand, and
/// it also opens whatever else the same person reused it on. Re-login is rare
/// enough (a month of inactivity, or a signed-out device) that trading it away
/// for a much smaller blast radius is the right side of that deal.
enum SessionStore {
    private static var base: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.example.ledger",
            kSecAttrAccount as String: "ledger-session-cookie",
        ]
    }

    static func load() -> String? {
        #if DEBUG
            if DemoMode.isActive { return DemoMode.ledgerSession }  // see DemoMode
        #endif
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
            let data = out as? Data,
            let s = String(data: data, encoding: .utf8), !s.isEmpty
        else { return nil }
        return s
    }

    static func save(_ cookie: String) {
        SecItemDelete(base as CFDictionary)
        var q = base
        q[kSecValueData as String] = Data(cookie.utf8)
        // ThisDeviceOnly so the cookie never rides an iCloud Keychain backup
        // onto a second device. WhenUnlocked rather than Always because there
        // is no background reader here - the app only ever presents this
        // cookie while someone has it open and unlocked in front of them.
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    static func clear() { SecItemDelete(base as CFDictionary) }
}
