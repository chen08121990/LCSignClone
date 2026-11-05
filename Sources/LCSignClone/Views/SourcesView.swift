import LCSignCore
import SwiftUI

/// 软件源列表。
///
/// 结构与证书库保持一致：一个 sheet + 卡片列表，没有底部 Tab。
/// 源和应用都是两级：这里看源里有什么，点进应用详情再决定下载。
struct SourcesView: View {

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var showingAdd = false
    @State private var pendingDeletion: AppSource?

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: Metric.Space.l) {
                    if model.sources.isEmpty {
                        emptyState
                        buildStamp
                    } else {
                        ForEach(model.sources) { source in
                            SourceSection(
                                source: source,
                                error: model.sourceErrors[source.id],
                                isRefreshing: model.refreshingSourceIDs.contains(source.id),
                                onRefresh: { Task { await model.refresh(source) } },
                                onDelete: { pendingDeletion = source }
                            )
                        }
                        footer
                    }
                }
                .padding(.horizontal, Metric.pageMargin)
                .padding(.top, Metric.Space.s)
                .padding(.bottom, Metric.Space.xxl)
            }
            .background(Brand.canvas.ignoresSafeArea())
            .navigationTitle("软件源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .sheet(isPresented: $showingAdd) {
                AddSourceSheet()
                    .environmentObject(model)
            }
            .confirmationDialog(
                "删除这个软件源？",
                isPresented: isShowingDeletion,
                presenting: pendingDeletion
            ) { source in
                Button("删除", role: .destructive) {
                    Task { await model.removeSource(source) }
                }
                Button("取消", role: .cancel) {}
            } message: { source in
                Text("「\(source.name)」及其 \(source.apps.count) 个应用会从本地移除，"
                   + "已下载的 IPA 不受影响。")
            }
        }
        .navigationViewStyle(.stack)
        .task {
            // 首次订阅可能在上次启动时失败了；打开这个页面时再试一次
            if model.sources.isEmpty {
                await model.loadSources()
            }
        }
    }

    private var isShowingDeletion: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("完成") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await model.refreshAllSources() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(model.sources.isEmpty || !model.refreshingSourceIDs.isEmpty)
            .accessibilityLabel("刷新全部")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                showingAdd = true
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("添加软件源")
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private var emptyState: some View {
        if model.isSeedingBuiltInSources {
            Card {
                VStack(spacing: Metric.Space.s) {
                    ProgressView()
                    Text("正在订阅内置软件源…")
                        .font(Typo.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Metric.Space.xxl)
            }
        } else if let error = model.builtInSeedError {
            Card {
                EmptyState(
                    symbol: "exclamationmark.triangle.fill",
                    title: "内置软件源订阅失败",
                    message: error
                ) {
                    Button {
                        Task { await model.loadSources() }
                    } label: {
                        Label("重试", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(PrimaryActionStyle(compact: true))
                }
            }
        } else {
            Card {
                EmptyState(
                    symbol: "globe.asia.australia.fill",
                    title: "还没有软件源",
                    message: "添加轻松签/全能签格式的 HTTPS 源地址，"
                           + "就能在 App 内挑选 IPA 并直接重签名。"
                ) {
                    Button {
                        showingAdd = true
                    } label: {
                        Label("添加软件源", systemImage: "plus")
                    }
                    .buttonStyle(PrimaryActionStyle(compact: true))
                }
            }
        }
    }

    /// 空状态时显示版本号：装的是哪一个包，一眼就能对上
    private var buildStamp: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return Text("版本 \(version) (\(build))")
            .font(Typo.micro)
            .foregroundColor(.secondary)
    }

    private var footer: some View {
        Text("软件源只提供 IPA 下载地址，不提供签名。下载后会用本机证书重新签名。"
           + "请仅处理你拥有权利的应用。")
            .font(Typo.micro)
            .fontWeight(.regular)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Metric.Space.s)
    }
}

// MARK: - 单个源

private struct SourceSection: View {

    let source: AppSource
    let error: String?
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metric.Space.s) {
            header

            if let error {
                NoticeBar(level: .warning,
                          text: "刷新失败，当前显示上次缓存的内容。\(error)")
            }

            ForEach(source.apps) { app in
                NavigationLink(destination: SourceAppDetailView(app: app, source: source)) {
                    SourceAppRow(app: app)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var header: some View {
        Card(padding: Metric.Space.m) {
            HStack(spacing: Metric.Space.m) {
                RemoteIcon(url: source.iconURL, size: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(source.name)
                        .font(Typo.cardTitle)
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Text("\(source.apps.count) 个应用 · 更新于 \(formattedRelative(source.updatedAt))")
                        .font(Typo.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: Metric.Space.s)

                if isRefreshing {
                    ProgressView()
                } else {
                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Brand.accent)
                            .frame(width: 32, height: 32)
                            .background(Brand.accent.opacity(0.10))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("刷新这个源")
                }

                Menu {
                    Button(action: onRefresh) {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    Button(role: .destructive, action: onDelete) {
                        Label("删除源", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 32, height: 32)
                        .background(Brand.sunken)
                        .clipShape(Circle())
                }
            }
        }
    }
}

// MARK: - 应用行

private struct SourceAppRow: View {

    let app: SourceApp

    var body: some View {
        Card(padding: Metric.Space.m) {
            HStack(spacing: Metric.Space.m) {
                RemoteIcon(url: app.iconURL, size: 46)

                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name)
                        .font(Typo.cardTitle)
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Text(app.developer ?? app.bundleID ?? "未知开发者")
                        .font(Typo.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    HStack(spacing: Metric.Space.s) {
                        if let version = app.version {
                            StatusPill(text: "v\(version)", tint: Brand.accent)
                        }
                        if let size = app.size {
                            Text(formattedBytes(size))
                                .font(Typo.micro)
                                .fontWeight(.regular)
                                .foregroundColor(.secondary)
                        }
                        if app.downloadURL.scheme?.lowercased() != "https" {
                            StatusPill(text: "HTTP", tint: Brand.warning)
                        }
                    }
                }

                Spacer(minLength: Metric.Space.s)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - 添加源

struct AddSourceSheet: View {

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var address = ""
    @State private var isAdding = false
    @State private var errorText: String?

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: Metric.Space.l) {
                    addressCard

                    if let errorText {
                        NoticeBar(level: .danger, text: errorText)
                    }

                    NoticeBar(
                        level: .info,
                        text: "只接受 HTTPS 源。源里的应用必须包含 name 与下载地址（url / downloadURL / appPackage）。"
                    )
                }
                .padding(.horizontal, Metric.pageMargin)
                .padding(.top, Metric.Space.s)
                .padding(.bottom, Metric.Space.xxl)
            }
            .background(Brand.canvas.ignoresSafeArea())
            .navigationTitle("添加软件源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isAdding)
                }
            }
            .safeAreaInset(edge: .bottom) { actionBar }
        }
        .navigationViewStyle(.stack)
    }

    private var addressCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Metric.Space.m) {
                Text("源地址")
                    .font(Typo.micro)
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)

                TextField("https://example.com/appstore", text: $address)
                    .keyboardType(.URL)
                    .disableAutocorrection(true)
                    .textInputAutocapitalization(.never)
                    .font(Typo.identifier(14))
                    .padding(Metric.Space.m)
                    .background(Brand.sunken)
                    .clipShape(RoundedRectangle(cornerRadius: Metric.Radius.small,
                                                style: .continuous))

                Text("可以只填域名和路径，会自动补上 https://。")
                    .font(Typo.micro)
                    .fontWeight(.regular)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actionBar: some View {
        VStack(spacing: Metric.Space.s) {
            Button(action: add) {
                HStack(spacing: Metric.Space.s) {
                    if isAdding {
                        ProgressView().progressViewStyle(.circular).tint(.white)
                    } else {
                        Image(systemName: "link")
                    }
                    Text(isAdding ? "加载中…" : "添加并加载")
                }
            }
            .buttonStyle(PrimaryActionStyle())
            .disabled(!canAdd || isAdding)

            if !canAdd && !isAdding {
                Text("先粘贴源地址")
                    .font(Typo.micro)
                    .fontWeight(.regular)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, Metric.pageMargin)
        .padding(.top, Metric.Space.m)
        .padding(.bottom, Metric.Space.s)
        .background(.bar)
    }

    private var canAdd: Bool {
        !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func add() {
        errorText = nil
        isAdding = true

        Task { @MainActor in
            do {
                try await model.addSource(address)
                isAdding = false
                dismiss()
            } catch {
                isAdding = false
                errorText = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }
}

// MARK: - 远程图标

/// 源里的图标几乎都是远程图片。加载失败时退回占位图标，
/// 不要让一行空白把应用名挤走。
struct RemoteIcon: View {

    let url: URL?
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(Brand.sunken)

            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .strokeBorder(Brand.hairline, lineWidth: 0.5)
        )
    }

    private var placeholder: some View {
        Image(systemName: "app.fill")
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundColor(.secondary)
    }
}
