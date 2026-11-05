import LCSignCore
import SwiftUI

/// 源内应用详情。
///
/// 这里只做一件事：确认这是要的包，然后下载。
/// 下载完成后直接把本地 IPA 带进重签名页，不再让用户去「文件」里翻。
struct SourceAppDetailView: View {

    @EnvironmentObject private var model: AppModel

    let app: SourceApp
    let source: AppSource

    @State private var downloaded: DownloadedIPA?
    @State private var errorText: String?

    private struct DownloadedIPA: Identifiable {
        let id = UUID()
        let url: URL
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Metric.Space.l) {
                header
                infoCard

                if let summary = app.summary, !summary.isEmpty {
                    descriptionSection(summary)
                }

                NoticeBar(
                    level: .info,
                    text: "源里提供的是原始 IPA。下载后会用你本机的证书重新签名，"
                        + "签名完成后从「签名记录」导出安装。"
                )

                if let errorText {
                    NoticeBar(level: .danger, text: errorText)
                }
            }
            .padding(.horizontal, Metric.pageMargin)
            .padding(.top, Metric.Space.s)
            .padding(.bottom, Metric.Space.xxl)
        }
        .background(Brand.canvas.ignoresSafeArea())
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { actionBar }
        .sheet(item: $downloaded) { item in
            SignSheet(initialIPA: item.url)
                .environmentObject(model)
        }
    }

    // MARK: - 头部

    private var header: some View {
        Card {
            VStack(spacing: Metric.Space.m) {
                RemoteIcon(url: app.iconURL, size: 84)

                VStack(spacing: 4) {
                    Text(app.name)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.center)

                    Text(app.developer ?? source.name)
                        .font(Typo.caption)
                        .foregroundColor(.secondary)
                }

                HStack(spacing: Metric.Space.s) {
                    if let version = app.version {
                        StatusPill(text: "版本 \(version)", tint: Brand.accent)
                    }
                    if let size = app.size {
                        StatusPill(text: formattedBytes(size), tint: Color.secondary)
                    }
                    if !isSecureDownload {
                        StatusPill(text: "HTTP", tint: Brand.warning)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - 信息

    private var infoCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Metric.Space.m) {
                InfoRow(title: "Bundle ID",
                        value: app.bundleID ?? "未知（源里没有提供）",
                        monospaced: true,
                        selectable: true)

                Divider().background(Brand.hairline)

                InfoRow(title: "来源", value: source.name)

                if let updatedAt = app.updatedAt {
                    Divider().background(Brand.hairline)
                    InfoRow(title: "更新时间", value: formattedDate(updatedAt))
                }

                Divider().background(Brand.hairline)

                InfoRow(title: "下载地址",
                        value: app.downloadURL.absoluteString,
                        monospaced: true,
                        selectable: true)
            }
        }
    }

    private func descriptionSection(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: Metric.Space.s) {
            SectionHeader(title: "应用说明")

            Card {
                Text(summary)
                    .font(Typo.body)
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 操作条

    private var isDownloading: Bool {
        model.downloadingAppID == app.downloadURL.absoluteString
    }

    private var isSecureDownload: Bool {
        app.downloadURL.scheme?.lowercased() == "https"
    }

    private var actionBar: some View {
        VStack(spacing: Metric.Space.s) {
            if isDownloading {
                VStack(alignment: .leading, spacing: Metric.Space.xs) {
                    Meter(value: model.downloadFraction)
                    HStack {
                        Text("正在下载…")
                            .font(Typo.micro)
                            .fontWeight(.regular)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(Int(model.downloadFraction * 100))%")
                            .font(Typo.micro)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }
            }

            Button(action: startDownload) {
                HStack(spacing: Metric.Space.s) {
                    if isDownloading {
                        ProgressView().progressViewStyle(.circular).tint(.white)
                    } else {
                        Image(systemName: "arrow.down.circle.fill")
                    }
                    Text(isDownloading ? "下载中…" : "下载并重签名")
                }
            }
            .buttonStyle(PrimaryActionStyle())
            .disabled(isDownloading || model.downloadingAppID != nil || !isSecureDownload)

            if !isSecureDownload {
                Text("这个下载地址不是 HTTPS，已被拒绝。")
                    .font(Typo.micro)
                    .fontWeight(.regular)
                    .foregroundColor(Brand.warning)
            }
        }
        .padding(.horizontal, Metric.pageMargin)
        .padding(.top, Metric.Space.m)
        .padding(.bottom, Metric.Space.s)
        .background(.bar)
    }

    private func startDownload() {
        errorText = nil

        Task { @MainActor in
            do {
                let url = try await model.download(app)
                downloaded = DownloadedIPA(url: url)
            } catch {
                errorText = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    // MARK: - 工具

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
