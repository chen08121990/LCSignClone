import Foundation

// MARK: - 配置

/// 「装到桌面」所用服务器的配置。
///
/// 上传协议刻意选**裸 PUT**：请求体就是文件本身，不做 multipart 拼装，
/// 于是可以直接用 URLSession 的文件上传任务（流式、有原生进度），
/// 一百多 MB 的 IPA 也不会先被读进内存再拼一遍。服务端只需要把
/// `php://input` 落盘即可，无需解析表单，天然避开 multipart 解析漏洞。
public struct InstallSettings: Codable, Equatable, Sendable {

    /// 上传接口地址（HTTPS，PUT）。
    public var uploadURL: URL?
    /// 服务器公开访问前缀。接口没在响应里给出文件地址时，用它拼出地址。
    public var publicBaseURL: URL?
    /// 上传令牌，按 `Authorization: Bearer <token>` 发送。空表示不带。
    public var token: String
    /// 签名成功后自动弹出安装页。
    public var autoInstallAfterSigning: Bool

    public init(uploadURL: URL? = nil,
                publicBaseURL: URL? = nil,
                token: String = "",
                autoInstallAfterSigning: Bool = true) {
        self.uploadURL = uploadURL
        self.publicBaseURL = publicBaseURL
        self.token = token
        self.autoInstallAfterSigning = autoInstallAfterSigning
    }

    public var isConfigured: Bool { uploadURL != nil }
}

// MARK: - 错误

public enum InstallError: LocalizedError {

    case notConfigured
    case insecureURL(String)
    case missingBundleID
    case manifestFailed(String)
    case network(String)
    case httpStatus(code: Int, detail: String)
    case invalidResponse(String)
    case publicURLUnavailable
    case publicURLUnreachable(URL)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "还没有配置安装服务器。"
        case .insecureURL(let url):
            return "安装地址必须使用 HTTPS：\(url)"
        case .missingBundleID:
            return "签名产物里读不到 Bundle ID，无法生成安装清单。"
        case .manifestFailed(let message):
            return "生成安装清单失败：\(message)"
        case .network(let message):
            return "上传失败：\(message)"
        case .httpStatus(let code, let detail):
            return detail.isEmpty
                ? "服务器返回 HTTP \(code)。"
                : "服务器返回 HTTP \(code)：\(detail)"
        case .invalidResponse(let message):
            return "服务器响应无法识别：\(message)"
        case .publicURLUnavailable:
            return "上传成功，但服务器没有返回文件地址。"
        case .publicURLUnreachable(let url):
            return "文件传上去了，但公开地址打不开：\(url)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .notConfigured:
            return "填写上传地址，并把 Server/lcsign-upload.php 部署到你的网站根目录。"
        case .insecureURL:
            return "iOS 只接受 HTTPS 的安装清单；http 地址会被系统直接拒绝。"
        case .missingBundleID:
            return "换一个 IPA 重新签名；这个包的 Info.plist 里没有 CFBundleIdentifier。"
        case .manifestFailed, .invalidResponse:
            return nil
        case .network:
            return "检查手机网络，以及上传地址在浏览器里能否访问。"
        case .httpStatus(let code, _) where code == 401 || code == 403:
            return "令牌与脚本里的 TOKEN 不一致。"
        case .httpStatus(let code, _) where code == 413:
            return "服务器限制了请求体大小。nginx 需要把 client_max_body_size 调到 512m。"
        case .httpStatus(let code, _) where code == 404:
            return "脚本没有部署到填写的路径，或路径拼写不对。"
        case .httpStatus:
            return "查看服务器日志；脚本里的错误信息会随响应一起返回。"
        case .publicURLUnavailable:
            return "在安装设置里填写「公开访问前缀」，或让接口在响应里返回 url 字段。"
        case .publicURLUnreachable:
            return "检查公开访问前缀是否正确，以及上传目录是否允许直接访问。"
        }
    }
}

// MARK: - 结果

public struct InstallResult: Sendable {
    public let bundleID: String
    public let buildVersion: String
    public let title: String
    public let ipaURL: URL
    public let manifestURL: URL
    /// 交给系统安装器的 itms-services 链接
    public let installationURL: URL
}

// MARK: - 服务

public actor InstallService {

    public init() {}

    /// 把用户输入的地址整理成 HTTPS URL；缺协议时补 https。
    public static func normalizeURL(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }

        guard let url = URL(string: text),
              url.scheme?.lowercased() == "https",
              let host = url.host,
              !host.isEmpty else {
            return nil
        }
        return url
    }

    // MARK: 上传并生成安装链接

    public func install(ipa: URL,
                        settings: InstallSettings,
                        onProgress: @Sendable @escaping (Double, String) -> Void) async throws -> InstallResult {

        _ = try requireEndpoint(settings)

        // 包名与构建号一律以产物为准：签名时可能改写过包名，
        // 用界面上的值会让清单与真实安装包对不上，系统就装不进去。
        let info = try IPAArchive.readBundleInfo(ipa: ipa)
        guard !info.bundleID.isEmpty else { throw InstallError.missingBundleID }

        let build = info.bundleBuild.isEmpty ? info.bundleVersion : info.bundleBuild
        let title = info.displayName.isEmpty ? "App" : info.displayName
        let folder = Self.remoteFolder()

        onProgress(0, "上传安装包")
        let ipaURL = try await upload(file: ipa,
                                      path: "\(folder)/app.ipa",
                                      settings: settings) { fraction in
            onProgress(fraction * 0.97, "上传安装包 \(Int(fraction * 100))%")
        }

        let manifest = try InstallManifest.data(bundleID: info.bundleID,
                                                buildVersion: build,
                                                title: title,
                                                ipaURL: ipaURL)
        let manifestFile = try Self.writeTemporary(manifest, name: "manifest.plist")
        defer { try? FileManager.default.removeItem(at: manifestFile) }

        onProgress(0.98, "写入安装清单")
        let manifestURL = try await upload(file: manifestFile,
                                           path: "\(folder)/manifest.plist",
                                           settings: settings) { _ in
            onProgress(0.99, "写入安装清单")
        }

        guard let installationURL = InstallManifest.installationURL(manifestURL: manifestURL) else {
            throw InstallError.invalidResponse("无法拼装 itms-services 链接")
        }

        onProgress(1, "已就绪")
        return InstallResult(bundleID: info.bundleID,
                             buildVersion: build,
                             title: title,
                             ipaURL: ipaURL,
                             manifestURL: manifestURL,
                             installationURL: installationURL)
    }

    // MARK: 连通性测试

    /// 传一个几字节的探针文件，再按公开地址读回来。
    ///
    /// 一次性验证两件独立的事：写权限（令牌、目录、PHP）和读能力
    /// （静态访问、HTTPS 证书）。这两件事坏任何一个，安装都会失败，
    /// 但报错时机完全不同 —— 先测一遍能省掉一轮猜测。
    public func test(settings: InstallSettings) async throws -> URL {
        _ = try requireEndpoint(settings)

        let probe = Data("lcsign-ok".utf8)
        let file = try Self.writeTemporary(probe, name: "probe.txt")
        defer { try? FileManager.default.removeItem(at: file) }

        let folder = Self.remoteFolder()
        let url = try await upload(file: file,
                                   path: "\(folder)/probe.txt",
                                   settings: settings,
                                   onProgress: { _ in })

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("LCSign/1.0 (iOS)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  String(data: data, encoding: .utf8)?.contains("lcsign-ok") == true else {
                throw InstallError.publicURLUnreachable(url)
            }
        } catch let error as InstallError {
            throw error
        } catch {
            throw InstallError.publicURLUnreachable(url)
        }

        return url
    }

    // MARK: - 上传

    private func upload(file: URL,
                        path: String,
                        settings: InstallSettings,
                        onProgress: @Sendable @escaping (Double) -> Void) async throws -> URL {

        let endpoint = try requireEndpoint(settings)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(path, forHTTPHeaderField: "X-LCSign-Path")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("LCSign/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        if !settings.token.isEmpty {
            request.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")
        }

        let (data, http) = try await FileUploader(onProgress: onProgress).send(request,
                                                                              file: file)
        return try Self.resolvePublicURL(data: data,
                                         response: http,
                                         path: path,
                                         settings: settings)
    }

    private func requireEndpoint(_ settings: InstallSettings) throws -> URL {
        guard let endpoint = settings.uploadURL else { throw InstallError.notConfigured }
        try Self.requireHTTPS(endpoint)
        return endpoint
    }

    private static func requireHTTPS(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else {
            throw InstallError.insecureURL(url.absoluteString)
        }
    }

    // MARK: - 响应解析

    private static func resolvePublicURL(data: Data,
                                         response: HTTPURLResponse,
                                         path: String,
                                         settings: InstallSettings) throws -> URL {

        guard (200..<300).contains(response.statusCode) else {
            let detail = String(data: data.prefix(300), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw InstallError.httpStatus(code: response.statusCode, detail: detail)
        }

        if let raw = urlString(in: data) {
            guard let url = URL(string: raw), url.scheme != nil else {
                throw InstallError.invalidResponse("返回的地址不是合法 URL：\(raw)")
            }
            guard url.scheme?.lowercased() == "https" else {
                throw InstallError.insecureURL(raw)
            }
            return url
        }

        guard let base = settings.publicBaseURL else {
            throw InstallError.publicURLUnavailable
        }
        try requireHTTPS(base)

        var text = base.absoluteString
        if !text.hasSuffix("/") { text += "/" }
        guard let url = URL(string: text + path) else {
            throw InstallError.invalidResponse("公开访问前缀拼不出文件地址")
        }
        return url
    }

    /// 兼容三种返回：纯文本 URL、`{"url": ...}`、`{"data": {"url": ...}}`。
    private static func urlString(in data: Data) -> String? {
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.lowercased().hasPrefix("https://") { return text }

        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return urlString(inJSON: object)
    }

    private static func urlString(inJSON object: Any) -> String? {
        if let dictionary = object as? [String: Any] {
            for key in ["url", "downloadURL", "download_url", "link"] {
                if let value = dictionary[key] as? String, !value.isEmpty { return value }
            }
            if let value = dictionary["data"] as? String, !value.isEmpty { return value }
            for value in dictionary.values {
                if let found = urlString(inJSON: value) { return found }
            }
        }
        if let array = object as? [Any] {
            for value in array {
                if let found = urlString(inJSON: value) { return found }
            }
        }
        return nil
    }

    // MARK: - 小工具

    /// 每次安装用独立目录，避免同名覆盖 —— iOS 会缓存 manifest，
    /// 一直用同一个地址的话，第二次安装可能拿到上一次的清单。
    private static func remoteFolder() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"
        let day = formatter.string(from: Date())
        return "lcsign/\(day)/\(UUID().uuidString.lowercased())"
    }

    private static func writeTemporary(_ data: Data, name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(name)")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw InstallError.manifestFailed(error.localizedDescription)
        }
        return url
    }
}

// MARK: - 带进度的文件上传

/// `URLSession.uploadTask(with:fromFile:)` 本身支持流式上传，
/// 但 async/await 版本拿不到进度。这里用 delegate 包一层：
/// 文件直接从磁盘读，进度按已发送字节数回调。
private final class FileUploader: NSObject, URLSessionDataDelegate {

    private let onProgress: @Sendable (Double) -> Void
    private var buffer = Data()
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var session: URLSession?

    init(onProgress: @Sendable @escaping (Double) -> Void) {
        self.onProgress = onProgress
        super.init()
    }

    deinit {
        session?.invalidateAndCancel()
    }

    func send(_ request: URLRequest, file: URL) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) in
            self.continuation = continuation

            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 60 * 30
            let session = URLSession(configuration: configuration,
                                     delegate: self,
                                     delegateQueue: nil)
            self.session = session

            let task = session.uploadTask(with: request, fromFile: file)
            task.resume()
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        // 只留响应开头：正常响应是几十字节的 JSON，
        // 出问题时前几百字节足够定位，不跟着服务器返回多少存多少。
        guard buffer.count < 64 * 1024 else { return }
        buffer.append(data)
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        defer {
            session.finishTasksAndInvalidate()
            self.session = nil
        }

        if let error {
            finish(.failure(InstallError.network(error.localizedDescription)))
            return
        }
        guard let http = task.response as? HTTPURLResponse else {
            finish(.failure(InstallError.invalidResponse("服务器没有返回 HTTP 响应")))
            return
        }
        finish(.success((buffer, http)))
    }

    private func finish(_ result: Result<(Data, HTTPURLResponse), Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}
