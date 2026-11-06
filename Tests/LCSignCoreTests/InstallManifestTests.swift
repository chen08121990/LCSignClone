import XCTest
import LCSignCore

/// OTA 安装清单与上传地址的纯逻辑。
///
/// 这两块一旦写错，症状都是「点安装什么都没发生」—— 没有报错、没有日志，
/// 所以字段名和格式必须在这里逐项钉死。
final class InstallManifestTests: XCTestCase {

    // MARK: - 清单结构

    func testManifestCarriesSignedBundleIdentity() throws {
        let ipaURL = try XCTUnwrap(URL(string:
            "https://cdn.example.com/lcsign/20261106/abc/app.ipa"))
        let bundleID = "B8BGPMF2XK.hk.com.hsbc.enterprise.hsbchkrewards.local2"

        let data = try InstallManifest.data(bundleID: bundleID,
                                            buildVersion: "42",
                                            title: "汇丰",
                                            ipaURL: ipaURL)

        let plist = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data,
                                                       options: [],
                                                       format: nil) as? [String: Any]
        )
        let items = try XCTUnwrap(plist["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)

        let assets = try XCTUnwrap(items[0]["assets"] as? [[String: Any]])
        XCTAssertEqual(assets.first?["kind"] as? String, "software-package")
        XCTAssertEqual(assets.first?["url"] as? String, ipaURL.absoluteString)

        let metadata = try XCTUnwrap(items[0]["metadata"] as? [String: Any])
        // 包名必须是签名后的真实值：描述文件固定 App ID 时它会和用户输入不同
        XCTAssertEqual(metadata["bundle-identifier"] as? String, bundleID)
        XCTAssertEqual(metadata["bundle-version"] as? String, "42")
        XCTAssertEqual(metadata["kind"] as? String, "software")
        XCTAssertEqual(metadata["title"] as? String, "汇丰")
    }

    // MARK: - itms-services 链接

    func testInstallationURLUsesITMSServicesScheme() throws {
        let manifest = try XCTUnwrap(URL(string:
            "https://cdn.example.com/lcsign/20261106/abc/manifest.plist"))

        let url = try XCTUnwrap(InstallManifest.installationURL(manifestURL: manifest))
        let text = url.absoluteString

        // 必须是 itms-services://? 而不是 itms-services:?，少两道斜杠 iOS 不认
        XCTAssertTrue(text.hasPrefix("itms-services://?action=download-manifest&url="),
                      text)

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = components?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "action" })?.value,
                       "download-manifest")
        XCTAssertEqual(query?.first(where: { $0.name == "url" })?.value,
                       manifest.absoluteString)
    }

    func testManifestURLWithQueryIsPercentEncoded() throws {
        let manifest = try XCTUnwrap(URL(string:
            "https://cdn.example.com/m.plist?token=a&x=1"))
        let url = try XCTUnwrap(InstallManifest.installationURL(manifestURL: manifest))

        // 清单地址自带的 & 不能泄漏到外层查询串里，否则会被截断
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.queryItems?.count, 2)
        XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "url" })?.value,
                       manifest.absoluteString)
    }

    // MARK: - 地址校验

    func testNormalizeURLRequiresHTTPS() throws {
        XCTAssertEqual(InstallService.normalizeURL("cdn.example.com/upload.php")?.absoluteString,
                       "https://cdn.example.com/upload.php")
        XCTAssertNil(InstallService.normalizeURL("http://cdn.example.com/upload.php"))
        XCTAssertNil(InstallService.normalizeURL("   "))
    }
}
