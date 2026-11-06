import Combine
import Foundation
import LCSignCore
import Security

/// 安装服务配置的持久化。
///
/// 令牌单独放钥匙串：UserDefaults 是明文 plist，而能往站点写文件的令牌
/// 等于一把上传权限，不该和「自动安装开没开」这种偏好混在同一份明文里。
final class InstallSettingsStore: ObservableObject {

    static let shared = InstallSettingsStore()

    @Published private(set) var settings: InstallSettings

    private static let settingsKey = "installServiceSettings"
    private static let keychainService = "com.example.lcsignclone.install"
    private static let tokenAccount = "upload-token"

    private init() {
        var loaded = InstallSettings()
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let decoded = try? JSONDecoder().decode(InstallSettings.self, from: data) {
            loaded = decoded
        }
        // 钥匙串是唯一可信来源：JSON 里那份只是为了兼容旧版本，永远被覆盖
        loaded.token = Self.readToken() ?? ""
        settings = loaded
    }

    func save(_ new: InstallSettings) {
        var persisted = new
        persisted.token = ""

        if new.token.isEmpty {
            Self.deleteToken()
        } else {
            Self.writeToken(new.token)
        }

        if let data = try? JSONEncoder().encode(persisted) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
        settings = new
    }

    // MARK: - 钥匙串

    private static func readToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: tokenAccount,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func writeToken(_ token: String) {
        deleteToken()

        let attributes: [String: Any] = [
            kSecClass as String:          kSecClassGenericPassword,
            kSecAttrService as String:    keychainService,
            kSecAttrAccount as String:    tokenAccount,
            kSecValueData as String:      Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private static func deleteToken() {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: tokenAccount
        ]
        SecItemDelete(query as CFDictionary)
    }
}
