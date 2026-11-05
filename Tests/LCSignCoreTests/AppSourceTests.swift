import XCTest
import LCSignCore

/// 软件源解析。
///
/// 这类源没有统一规范，同一层含义的字段在不同源里叫法不同。
/// 测试按「真实会遇到的几种写法」各来一份，确保加一个源就等于多支持一种布局，
/// 而不是多一个加载失败的地址。
final class AppSourceTests: XCTestCase {

    private let baseURL = URL(string: "https://example.com/source/appstore")!

    // MARK: - 常见布局

    func testParsesFlatSourceWithChineseFieldNames() throws {
        let json = """
        {
            "name": "测试源",
            "icon": "icon.png",
            "description": "一个测试源",
            "apps": [
                {
                    "name": "演示应用",
                    "bundleid": "com.example.demo",
                    "version": "1.2.3",
                    "icon": "/icons/demo.png",
                    "url": "files/demo.ipa",
                    "size": 12345678,
                    "desc": "演示说明",
                    "developer": "示例开发者",
                    "updateTime": "2026-01-02"
                }
            ]
        }
        """

        let source = try SourceParser.parse(Data(json.utf8), sourceURL: baseURL)

        XCTAssertEqual(source.name, "测试源")
        XCTAssertEqual(source.iconURL?.absoluteString, "https://example.com/source/icon.png")
        XCTAssertEqual(source.summary, "一个测试源")
        XCTAssertEqual(source.apps.count, 1)

        let app = try XCTUnwrap(source.apps.first)
        XCTAssertEqual(app.name, "演示应用")
        XCTAssertEqual(app.bundleID, "com.example.demo")
        XCTAssertEqual(app.version, "1.2.3")
        XCTAssertEqual(app.developer, "示例开发者")
        XCTAssertEqual(app.size, 12_345_678)
        XCTAssertEqual(app.downloadURL.absoluteString,
                       "https://example.com/source/files/demo.ipa")
        XCTAssertEqual(app.iconURL?.absoluteString,
                       "https://example.com/icons/demo.png")
    }

    func testParsesRepositoryStyleSource() throws {
        let json = """
        {
            "sourceName": "仓库风格",
            "sourceImage": "https://cdn.example.com/source.png",
            "sourceUpdateTime": "2026-09-30T10:00:00+0800",
            "appRepositories": [
                {
                    "appName": "示例工具",
                    "appVersion": "6.1.3",
                    "appImage": "https://cdn.example.com/icon.png",
                    "appPackage": "https://cdn.example.com/app.ipa",
                    "appDescription": "一段说明",
                    "appUpdateTime": "2026-09-30T10:00:00+0800"
                }
            ]
        }
        """

        let source = try SourceParser.parse(Data(json.utf8), sourceURL: baseURL)

        XCTAssertEqual(source.name, "仓库风格")
        XCTAssertEqual(source.apps.count, 1)

        let app = try XCTUnwrap(source.apps.first)
        XCTAssertEqual(app.name, "示例工具")
        XCTAssertEqual(app.version, "6.1.3")
        XCTAssertEqual(app.downloadURL.absoluteString, "https://cdn.example.com/app.ipa")
        XCTAssertEqual(app.iconURL?.absoluteString, "https://cdn.example.com/icon.png")
        XCTAssertEqual(app.summary, "一段说明")
    }

    /// 取自线上真实源（ipa.ipaioscc.cn/appstore）的字段写法，
    /// 包括全小写的 sourceicon、versionDescription 和字符串形式的 size。
    func testParsesQuanNengQianStyleSource() throws {
        let json = """
        {
            "name": "全能签源",
            "identifier": "https://ipa.example.com/appstore",
            "sourceicon": "https://cdn.example.com/source.png",
            "apps": [
                {
                    "name": "示例自签版",
                    "version": "1.3.7",
                    "versionDate": "2026-10-05T10:29:04+08:00",
                    "versionDescription": "这个版本的更新说明",
                    "lock": "0",
                    "downloadURL": "http://cdn.example.com/http-only.ipa",
                    "isLanZouCloud": "0",
                    "iconURL": "https://cdn.example.com/icon.png",
                    "size": "20971520"
                }
            ]
        }
        """

        let source = try SourceParser.parse(Data(json.utf8), sourceURL: baseURL)

        XCTAssertEqual(source.iconURL?.absoluteString, "https://cdn.example.com/source.png")
        XCTAssertEqual(source.apps.count, 1)

        let app = try XCTUnwrap(source.apps.first)
        XCTAssertEqual(app.name, "示例自签版")
        XCTAssertEqual(app.version, "1.3.7")
        XCTAssertEqual(app.summary, "这个版本的更新说明")
        XCTAssertEqual(app.size, 20_971_520)
        XCTAssertEqual(app.iconURL?.absoluteString, "https://cdn.example.com/icon.png")

        // http 地址要原样解析出来，由下载环节拒绝 ——
        // 如果在解析阶段整条丢掉，用户会以为源里没有这个应用
        XCTAssertEqual(app.downloadURL.scheme, "http")
        XCTAssertNotNil(app.updatedAt)
    }

    func testUnwrapsNestedDataObject() throws {
        let json = """
        {
            "code": 0,
            "data": {
                "name": "嵌套源",
                "apps": [
                    { "name": "应用", "url": "https://cdn.example.com/a.ipa" }
                ]
            }
        }
        """

        let source = try SourceParser.parse(Data(json.utf8), sourceURL: baseURL)

        XCTAssertEqual(source.name, "嵌套源")
        XCTAssertEqual(source.apps.count, 1)
    }

    // MARK: - 容错

    func testSkipsAppsWithoutDownloadURL() throws {
        let json = """
        {
            "name": "部分条目无效",
            "apps": [
                { "name": "没有地址" },
                { "name": "正常", "url": "https://cdn.example.com/ok.ipa" }
            ]
        }
        """

        let source = try SourceParser.parse(Data(json.utf8), sourceURL: baseURL)

        XCTAssertEqual(source.apps.count, 1)
        XCTAssertEqual(source.apps.first?.name, "正常")
    }

    func testDuplicateBundleIdentifiersGetDistinctIDs() throws {
        let json = """
        {
            "name": "多开源",
            "apps": [
                { "name": "多开一", "bundleid": "com.example.demo", "url": "https://cdn.example.com/1.ipa" },
                { "name": "多开二", "bundleid": "com.example.demo", "url": "https://cdn.example.com/2.ipa" }
            ]
        }
        """

        let source = try SourceParser.parse(Data(json.utf8), sourceURL: baseURL)

        XCTAssertEqual(source.apps.count, 2)
        XCTAssertNotEqual(source.apps[0].id, source.apps[1].id)
    }

    // MARK: - 错误

    func testRejectsNonJSON() {
        assertSourceError(SourceParser.parse(Data("<html></html>".utf8), sourceURL: baseURL)) {
            if case .invalidJSON = $0 { return true }
            return false
        }
    }

    func testRejectsSourceWithoutApps() {
        let json = #"{ "name": "空源" }"#
        assertSourceError(SourceParser.parse(Data(json.utf8), sourceURL: baseURL)) {
            if case .missingApps = $0 { return true }
            return false
        }
    }

    func testRejectsSourceWhereEveryAppIsInvalid() {
        let json = #"{ "name": "无效源", "apps": [ { "name": "只有名字" } ] }"#
        assertSourceError(SourceParser.parse(Data(json.utf8), sourceURL: baseURL)) {
            if case .noApps = $0 { return true }
            return false
        }
    }

    // MARK: - 工具

    private func assertSourceError<T>(_ expression: @autoclosure () throws -> T,
                                      file: StaticString = #filePath,
                                      line: UInt = #line,
                                      _ matches: (SourceError) -> Bool) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard let sourceError = error as? SourceError else {
                return XCTFail("抛出的不是 SourceError：\(error)", file: file, line: line)
            }
            XCTAssertTrue(matches(sourceError),
                          "错误类型不符：\(sourceError)",
                          file: file, line: line)
        }
    }
}
