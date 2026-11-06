import Foundation

/// 「装到桌面」用的 OTA 安装清单。
///
/// iOS 的 itms-services 协议本身不传输文件：系统先取一个 manifest.plist，
/// 再按里面 `software-package` 的地址下载 IPA。清单只是纯数据，但有两个字段
/// 写错就会「点安装毫无反应」：
///
///   - `bundle-identifier` 必须与 IPA 里**签名后**的包名完全一致。固定 App ID
///     的描述文件会把包名改写掉，所以只能取产物 Info.plist 里的值，
///     不能用界面上用户填的那个。
///   - `bundle-version` 要填 CFBundleVersion（构建号），不是 1.0.x 那种
///     展示版本号 —— 系统拿它来判断「装的是不是同一个版本」。
public enum InstallManifest {

    public static func data(bundleID: String,
                            buildVersion: String,
                            title: String,
                            ipaURL: URL) throws -> Data {
        let plist: [String: Any] = [
            "items": [
                [
                    "assets": [
                        [
                            "kind": "software-package",
                            "url": ipaURL.absoluteString
                        ]
                    ],
                    "metadata": [
                        "bundle-identifier": bundleID,
                        "bundle-version": buildVersion,
                        "kind": "software",
                        "title": title
                    ]
                ]
            ]
        ]

        do {
            return try PropertyListSerialization.data(fromPropertyList: plist,
                                                      format: .xml,
                                                      options: 0)
        } catch {
            throw InstallError.manifestFailed(error.localizedDescription)
        }
    }

    /// `itms-services://?action=download-manifest&url=<manifest>`
    public static func installationURL(manifestURL: URL) -> URL? {
        // 不用 URLComponents.queryItems：它按 RFC 3986 只编码「查询串里不允许」
        // 的字符，而 `&`、`=`、`+` 都属于子分隔符，会被原样留下 ——
        // 清单地址自己带查询串时，外层查询会被从 `&` 处截断。
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&?=#+")
        guard let encoded = manifestURL.absoluteString
            .addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }

        // 没有 host 时 URLComponents 会省略 `//`，而 iOS 只认
        // `itms-services://?` 这个完整形式，少两道斜杠就静默失败。
        return URL(string: "itms-services://?action=download-manifest&url=\(encoded)")
    }
}
