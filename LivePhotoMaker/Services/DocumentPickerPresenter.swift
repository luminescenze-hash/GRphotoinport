import UIKit
import UniformTypeIdentifiers

/// 直接用 UIKit 呈现系统文件夹选择器。
///
/// 不把 UIDocumentPickerViewController 放进 SwiftUI 的 .sheet，
/// 否则在部分 iOS 版本 / 外接存储场景下会出现：
/// - 文件夹点不进去、无法选中；
/// - 看不到右上角的“打开”按钮；
/// - delegate 回调后 sheet 状态异常。
@MainActor
final class DocumentPickerPresenter: NSObject, UIDocumentPickerDelegate {
    static let shared = DocumentPickerPresenter()

    private var completion: ((URL?) -> Void)?
    private weak var activePicker: UIDocumentPickerViewController?

    func presentFolderPicker(completion: @escaping (URL?) -> Void) {
        guard let presenter = Self.topViewController() else {
            completion(nil)
            return
        }

        self.completion = completion

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = false
        picker.modalPresentationStyle = .fullScreen
        activePicker = picker

        presenter.present(picker, animated: true)
    }

    // MARK: - UIDocumentPickerDelegate

    func documentPicker(
        _ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]
    ) {
        finish(urls.first)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finish(nil)
    }

    // MARK: - Private

    private func finish(_ url: URL?) {
        let completion = self.completion
        self.completion = nil

        guard let picker = activePicker, picker.presentingViewController != nil else {
            completion?(url)
            return
        }

        picker.dismiss(animated: true) {
            completion?(url)
        }
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first

        guard let window = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first,
              let root = window.rootViewController else {
            return nil
        }

        return topmost(from: root)
    }

    private static func topmost(from viewController: UIViewController) -> UIViewController {
        if let presented = viewController.presentedViewController {
            return topmost(from: presented)
        }
        if let navigation = viewController as? UINavigationController,
           let visible = navigation.visibleViewController {
            return topmost(from: visible)
        }
        if let tab = viewController as? UITabBarController,
           let selected = tab.selectedViewController {
            return topmost(from: selected)
        }
        return viewController
    }
}
