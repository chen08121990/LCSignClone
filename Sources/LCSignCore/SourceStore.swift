import Foundation

/// 已添加软件源的本地缓存。
///
/// 存的是解析后的清单而不是原始 JSON：断网时列表还能打开，
/// 用户至少知道自己加过哪些源、里面有哪些应用。
public actor SourceStore {

    public static let shared = SourceStore()

    private static let indexFileName = "sources.json"

    private let root: URL
    private var cache: [AppSource] = []
    private var loaded = false

    public init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let base = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.root = base.appendingPathComponent("Sources", isDirectory: true)
        }
    }

    private var indexURL: URL { root.appendingPathComponent(Self.indexFileName) }

    // MARK: - 读写

    public func all() throws -> [AppSource] {
        if !loaded { try reload() }
        return cache.sorted { $0.name < $1.name }
    }

    public func add(_ source: AppSource) throws {
        if !loaded { try reload() }

        if let index = cache.firstIndex(where: { $0.url == source.url }) {
            cache[index] = source
        } else {
            cache.append(source)
        }
        try persist()
    }

    public func remove(url: URL) throws {
        if !loaded { try reload() }
        cache.removeAll { $0.url == url }
        try persist()
    }

    private func reload() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: indexURL.path) else {
            cache = []
            loaded = true
            return
        }
        let data = try Data(contentsOf: indexURL)
        // 缓存坏了就当没有，宁可让用户重新添加，也别让整个界面卡在错误上
        cache = (try? JSONDecoder().decode([AppSource].self, from: data)) ?? []
        loaded = true
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(cache)
        try data.write(to: indexURL, options: [.atomic, .completeFileProtection])
    }
}
