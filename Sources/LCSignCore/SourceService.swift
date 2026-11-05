import Foundation

/// 软件源的网络层：拉清单、下载 IPA。
///
/// 只接受 HTTPS。这不是「顺手加的校验」——源地址和下载地址都来自用户输入，
/// 明文 HTTP 会让人在链路上替换 IPA；而 IPA 接下来会被重签并安装，
/// 等于把执行任意代码的入口交给中间人。
public actor SourceService {

    /// 清单上限。正常源是几百 KB 到几 MB，20 MB 足够兜住大源，
    /// 又能拦住「把 IPA 当源地址填进来」这类误操作。
    private static let maximumSourceBytes: Int = 20 * 1024 * 1024

    /// 刚装好 App 时 Wi‑Fi 可能还没连上：让它等网络，而不是立刻失败。
    /// 总时长仍有限制，避免断网时任务一直挂着。
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }()

    public init() {}

    // MARK: - 地址

    /// 把用户输入整理成可用的源地址：缺协议时补 https，其余非法情况返回 nil。
    public static func normalizeSourceURL(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") {
            text = "https://" + text
        }
        guard let url = URL(string: text),
              url.scheme?.lowercased() == "https",
              let host = url.host,
              !host.isEmpty else {
            return nil
        }
        return url
    }

    private static func requireHTTPS(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https",
              let host = url.host,
              !host.isEmpty else {
            throw SourceError.insecureURL(url.absoluteString)
        }
    }

    // MARK: - 拉取清单

    public func load(url: URL) async throws -> AppSource {
        try Self.requireHTTPS(url)

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("LCSign/1.0 (iOS)", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw SourceError.network(error.localizedDescription)
        } catch {
            throw error
        }

        guard let http = response as? HTTPURLResponse else {
            throw SourceError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SourceError.httpStatus(http.statusCode)
        }
        guard data.count <= Self.maximumSourceBytes else {
            throw SourceError.responseTooLarge(Int64(data.count))
        }

        return try SourceParser.parse(data, sourceURL: url)
    }

    // MARK: - 下载 IPA

    /// 下载到临时目录，返回本地文件地址。
    /// 调用方负责把它交给重签名流程，或自行清理。
    public func download(_ url: URL,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try Self.requireHTTPS(url)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        // 源里的包常见 300–600 MB，慢网下 15 分钟不够用；
        // 只限总时长，进度回调仍然照常上报
        configuration.timeoutIntervalForResource = 1800
        configuration.waitsForConnectivity = true

        let delegate = DownloadProgressDelegate(onProgress: progress)
        let session = URLSession(configuration: configuration,
                                 delegate: delegate,
                                 delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.setValue("LCSign/1.0 (iOS)", forHTTPHeaderField: "User-Agent")

        let temporaryURL: URL
        let response: URLResponse
        do {
            (temporaryURL, response) = try await session.download(for: request, delegate: delegate)
        } catch let error as URLError {
            throw SourceError.network(error.localizedDescription)
        } catch {
            throw error
        }

        guard let http = response as? HTTPURLResponse else {
            throw SourceError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SourceError.httpStatus(http.statusCode)
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LCSignDownloads", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var filename = URL(fileURLWithPath: response.suggestedFilename ?? "").lastPathComponent
        if filename.isEmpty { filename = UUID().uuidString }
        if !filename.lowercased().hasSuffix(".ipa") { filename += ".ipa" }

        // 加前缀避免同名包互相覆盖；保留原文件名方便在签名记录里认出来
        let destination = directory.appendingPathComponent("\(UUID().uuidString)-\(filename)")
        try? FileManager.default.removeItem(at: destination)

        do {
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
        } catch {
            throw SourceError.downloadFailed(error.localizedDescription)
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else {
            try? FileManager.default.removeItem(at: destination)
            throw SourceError.downloadFailed("文件为空")
        }

        try Self.validateIPA(at: destination)
        return destination
    }

    /// 下载地址失效时，服务器常常回一个 200 的 HTML 错误页。
    /// 只看状态码会把它当成功，直到重签名阶段才报「打不开这个 IPA」——
    /// 在这里用 ZIP 魔数拦掉，错误就能指向真正的原因。
    private static func validateIPA(at url: URL) throws {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw SourceError.notIPA("文件读不出来")
        }
        defer { try? handle.close() }

        let magic = (try? handle.read(upToCount: 4)) ?? Data()
        let signatures: [[UInt8]] = [
            [0x50, 0x4B, 0x03, 0x04],   // 普通 zip
            [0x50, 0x4B, 0x05, 0x06],   // 空归档
            [0x50, 0x4B, 0x07, 0x08]    // 分卷归档
        ]
        guard signatures.contains(where: { magic.starts(with: $0) }) else {
            try? FileManager.default.removeItem(at: url)
            throw SourceError.notIPA("文件开头不是 ZIP 标记，链接可能返回了网页")
        }
    }
}

// MARK: - 进度回调

/// 只在下载过程中上报进度，不接管文件落盘 —— 文件由 async API 返回。
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {

    private let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // 使用 session.download(for:delegate:) 时文件由返回值交付，这里无需处理
    }
}
