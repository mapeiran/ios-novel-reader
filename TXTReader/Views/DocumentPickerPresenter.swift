import UIKit
import UniformTypeIdentifiers

/// 用 UIKit 的文档选择器代替 SwiftUI `.fileImporter`：
/// - 代理回调稳定可靠
/// - asCopy = true 会返回沙盒内的副本，无需安全作用域即可读取
final class DocumentPickerPresenter: NSObject, UIDocumentPickerDelegate {

    static let shared = DocumentPickerPresenter()
    private var onPick: (([URL]) -> Void)?

    func present(onPick: @escaping ([URL]) -> Void) {
        self.onPick = onPick

        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })
                ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first,
              var top = window.rootViewController else {
            DebugLog.log("document picker: no presenting controller")
            onPick([])
            self.onPick = nil
            return
        }
        while let presented = top.presentedViewController {
            top = presented
        }

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item],
                                                    asCopy: true)
        // 单选：最近项目里点文件即选中并可直接“打开”，无需先点“选择”
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.delegate = self
        top.present(picker, animated: true)
        DebugLog.log("document picker presented")
    }

    func documentPicker(_ controller: UIDocumentPickerViewController,
                        didPickDocumentsAt urls: [URL]) {
        DebugLog.log("document picker didPick count=\(urls.count)")
        onPick?(urls)
        onPick = nil
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        DebugLog.log("document picker cancelled")
        onPick = nil
    }
}
