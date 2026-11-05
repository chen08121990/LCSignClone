import Foundation

// MARK: - 模型

/// 一个软件源。
///
/// 字段刻意只保留界面要用到的部分：源名称、图标、说明和应用列表。
/// 源里的公告、分类、卡密等信息一律不落地 —— 用不上，还会让缓存难以维护。
public struct AppSource: Codable, Identifiable, Equatable {

    /// 用户添加时输入的地址，同时用作刷新与去重的键
    public let url: URL

    public var name: String
    public var identifier: String?
    public var iconURL: URL?
    public var summary: String?
    public var apps: [SourceApp]

    /// 上次成功解析的时间（源自己给了更新时间就用源的）
    public var updatedAt: Date

    /// 用地址做 id：两个源可能抄了同一个 identifier，
    /// 而地址在 `add` 时就是去重键，天然唯一
    public var id: String { url.absoluteString }

    public init(url: URL,
                name: String,
                identifier: String? = nil,
                iconURL: URL? = nil,
                summary: String? = nil,
                apps: [SourceApp],
                updatedAt: Date = Date()) {
        self.url = url
        self.name = name
        self.identifier = identifier
        self.iconURL = iconURL
        self.summary = summary
        self.apps = apps
        self.updatedAt = updatedAt
    }
}

/// 源里的一个应用。
///
/// `id` 在解析时生成：优先用 Bundle ID，缺失时退回下载地址；
/// 同一个源里出现重复标识（多开、马甲包很常见）时追加序号，
/// 否则 SwiftUI 的 ForEach 会因重复 id 丢行。
public struct SourceApp: Codable, Identifiable, Equatable {

    public let id: String
    public var name: String
    public var bundleID: String?
    public var version: String?
    public var iconURL: URL?
    public var downloadURL: URL
    public var size: Int64?
    public var summary: String?
    public var developer: String?
    public var updatedAt: Date?

    public init(id: String,
                name: String,
                bundleID: String? = nil,
                version: String? = nil,
                iconURL: URL? = nil,
                downloadURL: URL,
                size: Int64? = nil,
                summary: String? = nil,
                developer: String? = nil,
                updatedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.bundleID = bundleID
        self.version = version
        self.iconURL = iconURL
        self.downloadURL = downloadURL
        self.size = size
        self.summary = summary
        self.developer = developer
        self.updatedAt = updatedAt
    }
}

// MARK: - 错误

public enum SourceError: LocalizedError, Equatable {

    case invalidAddress(String)
    case insecureURL(String)
    case invalidResponse
    case httpStatus(Int)
    case responseTooLarge(Int64)
    case network(String)
    case invalidJSON(String)
    case missingApps(String)
    case noApps(String)
    case downloadFailed(String)
    case notIPA(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAddress(let detail):
            return "源地址无效：\(detail)"
        case .insecureURL(let detail):
            return "只支持 HTTPS 地址：\(detail)"
        case .invalidResponse:
            return "服务器没有返回有效的 HTTP 响应。"
        case .httpStatus(let code):
            return "服务器返回 HTTP \(code)。"
        case .responseTooLarge(let bytes):
            return "源清单太大（\(formattedBytes(bytes))），已拒绝加载。"
        case .network(let detail):
            return "网络请求失败：\(detail)"
        case .invalidJSON(let detail):
            return "源不是合法的 JSON：\(detail)"
        case .missingApps(let detail):
            return "这个 JSON 不像软件源：\(detail)"
        case .noApps(let detail):
            return "源里没有可下载的应用：\(detail)"
        case .downloadFailed(let detail):
            return "下载失败：\(detail)"
        case .notIPA(let detail):
            return "下载到的不是 IPA：\(detail)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .invalidAddress:
            return "粘贴完整的源地址，例如 https://example.com/appstore。"
        case .insecureURL:
            return "换一个 HTTPS 源地址，或联系源作者启用 HTTPS。"
        case .invalidResponse, .httpStatus:
            return "确认地址在 Safari 里能打开，且服务器返回的是 JSON 而不是网页。"
        case .responseTooLarge:
            return "确认地址指向的是源清单，而不是 IPA 或其他大文件。"
        case .network:
            return "检查网络连接与代理，然后重试。"
        case .invalidJSON:
            return "有些源会加密或压缩内容，这种源目前不支持。"
        case .missingApps, .noApps:
            return "确认这是轻松签/全能签格式的源，应用条目里至少有 name 和 url 字段。"
        case .downloadFailed:
            return "稍后重试，或换一个下载地址。"
        case .notIPA:
            return "链接可能已失效或返回了错误页，去浏览器里确认这个地址直接下载的是 .ipa。"
        }
    }

    private func formattedBytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

// MARK: - 解析

/// 轻松签 / 全能签风格软件源的解析器。
///
/// 这类源的字段没有统一规范，同一个含义在不同源里叫法不同
/// （`url` / `downloadURL` / `appPackage`、`icon` / `appImage` …）。
/// 所以这里按「同义字段表」取值，而不是写一个严格的 Codable 结构：
/// 严格结构遇到一个新变体就整源加载失败，UI 只能报「源无效」。
public enum SourceParser {

    public static func parse(_ data: Data, sourceURL: URL) throws -> AppSource {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw SourceError.invalidJSON("内容无法解析")
        }

        guard var root = object as? [String: Any] else {
            throw SourceError.invalidJSON("根节点不是对象")
        }

        // 有的源把清单包在 data 里；先展开，外层字段作为兜底
        if root["apps"] == nil, root["appRepositories"] == nil,
           let nested = root["data"] as? [String: Any] {
            let outer = root.filter { $0.key != "data" }
            root = nested.merging(outer) { nestedValue, _ in nestedValue }
        }

        let rawApps: [Any]
        if let apps = root["apps"] as? [Any] {
            rawApps = apps
        } else if let apps = root["appRepositories"] as? [Any] {
            rawApps = apps
        } else if let apps = root["data"] as? [Any] {
            rawApps = apps
        } else {
            throw SourceError.missingApps("顶层没有 apps 或 appRepositories 数组")
        }

        let name = string(root, ["name", "sourceName", "title", "sourceTitle"])
            ?? sourceURL.host
            ?? "未命名源"

        let identifier = string(root, ["identifier", "sourceIdentifier", "sourceID"])
        // 全能签的源图标字段是全小写的 sourceicon，不是驼峰
        let iconURL = url(root, ["icon", "iconURL", "iconUrl", "sourceicon", "sourceIcon",
                                 "sourceImage", "logo", "image"],
                          base: sourceURL)
        let summary = string(root, ["description", "desc", "sourceDescription", "subtitle", "summary"])
        let updatedAt = date(root, ["updateTime", "updatedAt", "sourceUpdateTime", "date"]) ?? Date()

        var apps: [SourceApp] = []
        var seen = Set<String>()

        for (index, element) in rawApps.enumerated() {
            guard let dict = element as? [String: Any] else { continue }
            guard let appName = string(dict, ["name", "appName", "appname", "title"]) else { continue }
            guard let downloadURL = url(dict,
                                        ["url", "downloadURL", "downloadUrl", "appPackage",
                                         "ipa", "ipaURL", "download"],
                                        base: sourceURL) else { continue }

            let bundleID = string(dict, ["bundleIdentifier", "bundleID", "bundleId",
                                         "bundleid", "appBundleId", "bundle"])

            // 同源里重复的 Bundle ID 加序号，避免 ForEach 丢行
            let identity = bundleID ?? downloadURL.absoluteString
            let id = seen.insert(identity).inserted ? identity : "\(identity)#\(index)"

            apps.append(SourceApp(
                id: id,
                name: appName,
                bundleID: bundleID,
                version: string(dict, ["version", "appVersion", "versionName", "latestVersion"]),
                iconURL: url(dict,
                             ["icon", "iconURL", "iconUrl", "appImage", "image", "appIcon"],
                             base: sourceURL),
                downloadURL: downloadURL,
                size: int64(dict, ["size", "appSize", "fileSize", "installSize"]),
                summary: string(dict, ["description", "desc", "appDescription",
                                       "versionDescription", "versionDesc",
                                       "localizedDescription", "subtitle"]),
                developer: string(dict, ["developer", "developerName", "author", "appAuthor"]),
                updatedAt: date(dict, ["date", "updateTime", "appUpdateTime",
                                       "updatedAt", "versionDate", "releaseDate"])
            ))
        }

        guard !apps.isEmpty else {
            throw SourceError.noApps("共 \(rawApps.count) 条，但没有同时具备 name 和 url 的条目")
        }

        return AppSource(url: sourceURL,
                         name: name,
                         identifier: identifier,
                         iconURL: iconURL,
                         summary: summary,
                         apps: apps,
                         updatedAt: updatedAt)
    }

    // MARK: 字段取值

    private static func string(_ dict: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let text = dict[key] as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            if let number = dict[key] as? NSNumber {
                return number.stringValue
            }
        }
        return nil
    }

    private static func int64(_ dict: [String: Any], _ keys: [String]) -> Int64? {
        for key in keys {
            if let number = dict[key] as? NSNumber {
                return number.int64Value
            }
            if let text = dict[key] as? String,
               let value = Int64(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return value
            }
        }
        return nil
    }

    /// 相对地址按源地址解析，源里写 `icon.png` / `/icons/a.png` 都能用
    private static func url(_ dict: [String: Any], _ keys: [String], base: URL) -> URL? {
        guard let raw = string(dict, keys) else { return nil }
        if let absolute = URL(string: raw), absolute.scheme != nil {
            return absolute
        }
        return URL(string: raw, relativeTo: base)?.absoluteURL
    }

    private static func date(_ dict: [String: Any], _ keys: [String]) -> Date? {
        guard let raw = string(dict, keys) else { return nil }

        let iso = ISO8601DateFormatter()
        if let value = iso.date(from: raw) { return value }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = iso.date(from: raw) { return value }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        for format in ["yyyy-MM-dd'T'HH:mm:ssZ",
                       "yyyy-MM-dd HH:mm:ss",
                       "yyyy-MM-dd",
                       "yyyy/MM/dd HH:mm:ss",
                       "yyyy/MM/dd"] {
            formatter.dateFormat = format
            if let value = formatter.date(from: raw) { return value }
        }
        return nil
    }
}
