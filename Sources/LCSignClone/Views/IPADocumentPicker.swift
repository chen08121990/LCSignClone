import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 选 IPA 用的系统文件选择器。
///
/// 不用 SwiftUI 的 `.fileImporter`：它按 UTI 过滤，而 `.ipa` 在 iOS 上
/// 没有可信的系统类型映射，从别的 App 存进来的 ipa 会被整个置灰、点不动。
/// 这里以 `.item`（所有文件）打开并直接拷贝一份，选完再按扩展名校验。
struct IPADocumentPicker: UIViewControllerRepresentable {

    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {

        private let parent: IPADocumentPicker

        init(_ parent: IPADocumentPicker) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else {
                parent.onCancel()
                return
            }
            parent.onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
        }
    }
}
