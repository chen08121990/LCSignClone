import LCSignCore
import SwiftUI
import UIKit

/// 安装到桌面。
///
/// 系统不允许 App 直接把自己的产物「装上去」：唯一被 iOS 认可的路径是
/// itms-services 协议 —— 先把 IPA 与一份 manifest.plist 放到 HTTPS 服务器上，
/// 再把 manifest 地址交给系统安装器。所以这个页面分两段：
/// 第一次进来先把服务器配好，之后每次只剩一个「安装到桌面」按钮。
struct InstallSheet: View {

    let task: SigningTask

    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = InstallSettingsStore.shared

    // 服务器配置草稿
    @State private var uploadAddress = ""
    @State private var baseAddress = ""
    @State private var token = ""
    @State private var autoInstall = true
    @State private var didLoadDraft = false
    @State private var isEditing = false

    // 产物信息
    @State private var bundleInfo: IPAArchive.BundleInfo?
    @State private var bundleError: String?

    // 上传状态
    @State private var isUploading = false
    @State private var progress: Double = 0
    @State private var statusText = ""
    @State private var errorText: String?
    @State private var result: InstallResult?

    // 连通性测试 / 脚本复制
    @State private var isTesting = false
    @State private var noticeText: String?
    @State private var noticeIsSuccess = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: Metric.Space.l) {
                    summaryCard

                    if isEditing || !store.settings.isConfigured {
                        settingsSection
                    } else {
                        installSection
                    }
                }
                .padding(.horizontal, Metric.pageMargin)
                .padding(.bottom, Metric.Space.xxl)
            }
            .background(Brand.canvas.ignoresSafeArea())
            .navigationTitle("安装到桌面")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .disabled(isUploading)
                }
            }
            .onAppear(perform: loadDraft)
            .onAppear(perform: readBundleInfo)
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - 产物摘要

    private var summaryCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Metric.Space.m) {
                HStack(spacing: Metric.Space.m) {
                    IconBadge(symbol: "arrow.down.app.fill",
                              tint: Brand.accent,
                              size: 44)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(bundleInfo?.displayName ?? task.name)
                            .font(Typo.cardTitle)
                            .foregroundColor(.primary)
                            .lineLimit(1)

                        Text(subtitle)
                            .font(Typo.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: Metric.Space.s)

                    StatusPill(text: "已签名", tint: Brand.success)
                }

                if let bundleInfo {
                    VStack(alignment: .leading, spacing: Metric.Space.xs) {
                        InfoRow(title: "Bundle ID",
                                value: bundleInfo.bundleID,
                                monospaced: true,
                                selectable: true)
                        Text("版本 \(bundleInfo.bundleVersion)（\(buildText(bundleInfo))）")
                            .font(Typo.micro)
                            .fontWeight(.regular)
                            .foregroundColor(.secondary)
                    }
                }

                if let bundleError {
                    NoticeBar(level: .danger, text: bundleError)
                }
            }
        }
    }

    private var subtitle: String {
        if let info = bundleInfo, !info.bundleID.isEmpty {
            return info.bundleID
        }
        if task.outputSize > 0 {
            return "IPA · \(formattedBytes(task.outputSize))"
        }
        return "签名产物"
    }

    private func buildText(_ info: IPAArchive.BundleInfo) -> String {
        info.bundleBuild.isEmpty ? "无构建号" : "构建 \(info.bundleBuild)"
    }

    // MARK: - 安装

    private var installSection: some View {
        VStack(spacing: Metric.Space.m) {
            if let result {
                NoticeBar(level: .success, text: "上传完成，系统安装器应已弹出。")
                installationActions(result)
            } else {
                Card {
                    VStack(alignment: .leading, spacing: Metric.Space.m) {
                        HStack(spacing: Metric.Space.s) {
                            Image(systemName: "server.rack")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(Brand.accent)
                            Text("通过 \(hostText) 安装")
                                .font(Typo.micro)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            Spacer()
                        }

                        Text("签名后的 IPA 会上传到服务器，再交给系统安装器。"
                           + "首次安装需要在「设置 → 通用 → VPN 与设备管理」里信任证书。")
                            .font(Typo.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if isUploading {
                            VStack(alignment: .leading, spacing: Metric.Space.s) {
                                Meter(value: progress)
                                HStack {
                                    Text(statusText.isEmpty ? "上传中…" : statusText)
                                        .font(Typo.micro)
                                        .fontWeight(.regular)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text("\(Int(progress * 100))%")
                                        .font(Typo.micro)
                                        .foregroundColor(.secondary)
                                        .monospacedDigit()
                                }
                            }
                        }

                        if let errorText {
                            NoticeBar(level: .danger, text: errorText)
                        }

                        Button {
                            startUpload()
                        } label: {
                            HStack(spacing: Metric.Space.s) {
                                if isUploading {
                                    ProgressView()
                                        .progressViewStyle(.circular)
                                        .tint(.white)
                                } else {
                                    Image(systemName: "arrow.down.circle.fill")
                                }
                                Text(isUploading ? "上传中…" : "安装到桌面")
                            }
                        }
                        .buttonStyle(PrimaryActionStyle())
                        .disabled(isUploading || bundleInfo == nil)

                        Button {
                            isEditing = true
                            errorText = nil
                        } label: {
                            Label("修改服务器设置", systemImage: "slider.horizontal.3")
                        }
                        .buttonStyle(GhostActionStyle(compact: true))
                        .disabled(isUploading)
                    }
                }
            }
        }
    }

    private func installationActions(_ outcome: InstallResult) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Metric.Space.m) {
                InfoRow(title: "安装清单",
                        value: outcome.manifestURL.absoluteString,
                        monospaced: true,
                        selectable: true)

                Button {
                    openInstaller(outcome.installationURL)
                } label: {
                    Label("打开系统安装器", systemImage: "arrow.down.app")
                }
                .buttonStyle(PrimaryActionStyle(compact: true))

                HStack(spacing: Metric.Space.s) {
                    Button {
                        UIPasteboard.general.string = outcome.installationURL.absoluteString
                        noticeIsSuccess = true
                        noticeText = "安装链接已复制，可以粘贴到 Safari 打开。"
                    } label: {
                        Label("复制安装链接", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(GhostActionStyle(compact: true))

                    Button {
                        result = nil
                        errorText = nil
                        progress = 0
                    } label: {
                        Label("重新上传", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(GhostActionStyle(compact: true))
                }

                if let noticeText {
                    NoticeBar(level: noticeIsSuccess ? .success : .danger, text: noticeText)
                }
                if let errorText {
                    NoticeBar(level: .danger, text: errorText)
                }
            }
        }
    }

    private var hostText: String {
        store.settings.uploadURL?.host ?? "安装服务器"
    }

    // MARK: - 服务器设置

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: Metric.Space.s) {
            SectionHeader(title: "安装服务器")

            Card {
                VStack(alignment: .leading, spacing: Metric.Space.l) {
                    NoticeBar(level: .info,
                              text: "先把这个脚本放到网站根目录：lcsign-upload.php。"
                                 + "它负责接收上传、把文件落盘到 lcsign/ 目录。")

                    field(title: "上传地址",
                          placeholder: "https://example.com/lcsign-upload.php",
                          text: $uploadAddress,
                          keyboard: .URL,
                          note: "必须是 HTTPS。支持裸 PUT 的自建接口也可以。")

                    Divider().background(Brand.hairline)

                    field(title: "公开访问前缀（可选）",
                          placeholder: "https://example.com",
                          text: $baseAddress,
                          keyboard: .URL,
                          note: "接口没返回文件地址时，用「前缀 + lcsign/…」拼出下载地址。")

                    Divider().background(Brand.hairline)

                    field(title: "令牌（可选）",
                          placeholder: "与脚本里的 TOKEN 一致",
                          text: $token,
                          keyboard: .default,
                          note: "令牌只保存在本机钥匙串，不会写进明文配置。")

                    Divider().background(Brand.hairline)

                    Toggle(isOn: $autoInstall) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("签名成功后自动打开")
                                .font(Typo.body)
                                .foregroundColor(.primary)
                            Text("只弹出这一页，不会未经确认就上传。")
                                .font(Typo.micro)
                                .fontWeight(.regular)
                                .foregroundColor(.secondary)
                        }
                    }
                    .tint(Brand.accent)
                }
            }

            HStack(spacing: Metric.Space.s) {
                Button {
                    copyServerScript()
                } label: {
                    Label("复制上传脚本", systemImage: "doc.on.doc")
                }
                .buttonStyle(GhostActionStyle(compact: true))

                Button {
                    runTest()
                } label: {
                    if isTesting {
                        HStack(spacing: Metric.Space.xs) {
                            ProgressView()
                            Text("测试中…")
                        }
                    } else {
                        Label("测试连接", systemImage: "bolt.horizontal")
                    }
                }
                .buttonStyle(GhostActionStyle(compact: true))
                .disabled(isTesting || isUploading)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metric.Space.xs)

            if let noticeText {
                NoticeBar(level: noticeIsSuccess ? .success : .danger, text: noticeText)
            }
            if let errorText {
                NoticeBar(level: .danger, text: errorText)
            }

            Button {
                saveAndInstall()
            } label: {
                Label(task.outputURL == nil ? "保存设置" : "保存并安装",
                      systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(PrimaryActionStyle())
            .disabled(isTesting || isUploading)
            .padding(.top, Metric.Space.xs)

            if store.settings.isConfigured {
                Button {
                    isEditing = false
                    errorText = nil
                    noticeText = nil
                } label: {
                    Text("取消修改")
                }
                .buttonStyle(GhostActionStyle(compact: true))
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func field(title: String,
                       placeholder: String,
                       text: Binding<String>,
                       keyboard: UIKeyboardType,
                       note: String) -> some View {
        VStack(alignment: .leading, spacing: Metric.Space.s) {
            Text(title)
                .font(Typo.micro)
                .foregroundColor(.secondary)
                .textCase(.uppercase)

            TextField(placeholder, text: text)
                .keyboardType(keyboard)
                .disableAutocorrection(true)
                .textInputAutocapitalization(.never)
                .font(Typo.identifier(14))
                .padding(Metric.Space.m)
                .background(Brand.sunken)
                .clipShape(RoundedRectangle(cornerRadius: Metric.Radius.small,
                                            style: .continuous))

            Text(note)
                .font(Typo.micro)
                .fontWeight(.regular)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 逻辑

    private func loadDraft() {
        guard !didLoadDraft else { return }
        didLoadDraft = true

        let saved = store.settings
        uploadAddress = saved.uploadURL?.absoluteString ?? ""
        baseAddress = saved.publicBaseURL?.absoluteString ?? ""
        token = saved.token
        autoInstall = saved.autoInstallAfterSigning

        // 还没配过：预填一个可改的模板，省掉从头敲 URL 的功夫
        if uploadAddress.isEmpty {
            uploadAddress = "https://rjy.ipaioscc.cn/lcsign-upload.php"
            baseAddress = "https://rjy.ipaioscc.cn"
        }
        isEditing = !saved.isConfigured
    }

    private func readBundleInfo() {
        guard let output = task.outputURL else {
            bundleError = "产物文件不见了，请重新签名。"
            return
        }
        do {
            bundleInfo = try IPAArchive.readBundleInfo(ipa: output)
        } catch {
            bundleError = (error as? LocalizedError)?.errorDescription
                       ?? error.localizedDescription
        }
    }

    private func saveSettings() -> InstallSettings? {
        errorText = nil
        noticeText = nil

        let trimmed = uploadAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let upload = InstallService.normalizeURL(trimmed) else {
            errorText = "上传地址必须是 HTTPS 地址，例如 https://example.com/lcsign-upload.php。"
            return nil
        }

        var base: URL?
        let rawBase = baseAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rawBase.isEmpty {
            guard let parsed = InstallService.normalizeURL(rawBase) else {
                errorText = "公开访问前缀必须是 HTTPS 地址。"
                return nil
            }
            base = parsed
        }

        let settings = InstallSettings(
            uploadURL: upload,
            publicBaseURL: base,
            token: token.trimmingCharacters(in: .whitespacesAndNewlines),
            autoInstallAfterSigning: autoInstall
        )
        store.save(settings)
        return settings
    }

    private func saveAndInstall() {
        guard let settings = saveSettings() else { return }
        isEditing = false

        guard task.outputURL != nil else { return }
        startUpload(settings: settings)
    }

    private func startUpload(settings: InstallSettings? = nil) {
        guard !isUploading else { return }
        guard let settings = settings ?? savedSettingsForUpload() else { return }
        guard let output = task.outputURL else {
            errorText = "产物文件不见了，请重新签名。"
            return
        }
        guard bundleInfo != nil else {
            errorText = bundleError ?? "读不到产物信息，无法生成安装清单。"
            return
        }

        isUploading = true
        progress = 0
        statusText = "准备上传"
        errorText = nil
        result = nil

        Task {
            do {
                let outcome = try await InstallService().install(ipa: output,
                                                                 settings: settings) { fraction, status in
                    Task { @MainActor in
                        progress = fraction
                        statusText = status
                    }
                }
                await MainActor.run {
                    isUploading = false
                    progress = 1
                    result = outcome
                    openInstaller(outcome.installationURL)
                }
            } catch {
                await MainActor.run {
                    isUploading = false
                    errorText = Self.message(for: error)
                }
            }
        }
    }

    private func savedSettingsForUpload() -> InstallSettings? {
        guard store.settings.isConfigured else {
            errorText = "先配置安装服务器。"
            return nil
        }
        return store.settings
    }

    private func runTest() {
        guard let settings = saveSettings() else { return }
        // 测试完把草稿留在页面上，用户看到结果再决定要不要安装
        guard settings.isConfigured else { return }

        isTesting = true
        noticeText = nil
        Task {
            do {
                let url = try await InstallService().test(settings: settings)
                await MainActor.run {
                    isTesting = false
                    noticeIsSuccess = true
                    noticeText = "服务器可用，探针文件：\(url.absoluteString)"
                }
            } catch {
                await MainActor.run {
                    isTesting = false
                    noticeIsSuccess = false
                    noticeText = Self.message(for: error)
                }
            }
        }
    }

    private func copyServerScript() {
        guard let url = Bundle.main.url(forResource: "lcsign-upload", withExtension: "php"),
              let script = try? String(contentsOf: url, encoding: .utf8) else {
            noticeIsSuccess = false
            noticeText = "App 里没有找到上传脚本资源，请从仓库的 Server/lcsign-upload.php 取。"
            return
        }
        UIPasteboard.general.string = script
        noticeIsSuccess = true
        noticeText = "脚本已复制。把它保存为网站根目录下的 lcsign-upload.php，"
                   + "并把脚本里的 TOKEN 改成与这里填写的一致。"
    }

    private func openInstaller(_ url: URL) {
        UIApplication.shared.open(url, options: [:]) { opened in
            guard !opened else { return }
            Task { @MainActor in
                errorText = "系统没有接管 itms-services 链接。"
                          + "可以复制安装链接后在 Safari 中打开。"
            }
        }
    }

    private static func message(for error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        if let suggestion = (error as? LocalizedError)?.recoverySuggestion {
            return "\(text)\n\n\(suggestion)"
        }
        return text
    }
}
