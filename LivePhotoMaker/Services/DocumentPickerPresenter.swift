import UIKit
import UniformTypeIdentifiers

/// 选择器的访问方式。
///
/// - `inPlace`：原地打开（`asCopy: false`），适合本地存储、iCloud 等支持 open-in-place 的位置。
/// - `copy`：拷贝到 App 沙盒（`asCopy: true`）。
///
/// 外接 U 盘（相机 USB 存储、随身盘）在系统文件提供者上通常不支持“原地打开”，
/// 表现就是选择器里文件夹与文件全部灰显、点不动。这类位置必须用 `copy` 模式，
/// 由系统把选中的内容复制进 App 的 Inbox 目录后再处理。
enum PickAccess {
    case inPlace
    case copy
}

/// 直接用 UIKit 呈现系统文档选择器。
///
/// 不把 `UIDocumentPickerViewController` 放进 SwiftUI 的 `.sheet`，
/// 否则在部分 iOS 版本 / 外接存储场景下会出现：
/// - 文件夹点不进去、无法选中；
/// - 看不到右上角的“打开 / 拷贝”按钮；
/// - delegate 回调后 sheet 状态异常。
@MainActor
final class DocumentPickerPresenter: NSObject, UIDocumentPickerDelegate {
    static let shared = DocumentPickerPresenter()

    private var completion: (([URL]?) -> Void)?
    private weak var activePicker: UIDocumentPickerViewController?

    // MARK: - 对外入口

    /// 选择文件夹。
    func presentFolderPicker(
        access: PickAccess = .inPlace,
        completion: @escaping ([URL]?) -> Void
    ) {
        present(contentTypes: [.folder], access: access, allowMultiple: false, completion: completion)
    }

    /// 选择视频文件（多选）。用 `.item` 而不是 `.movie`：
    /// 外接存储的文件类型标注经常不可靠，限定 `.movie` 会导致整批置灰。
    func presentMoviePicker(
        access: PickAccess = .copy,
        completion: @escaping ([URL]?) -> Void
    ) {
        present(contentTypes: [.item], access: access, allowMultiple: true, completion: completion)
    }

    /// 选择图片文件（多选），同理用 `.item` 保证可点选。
    func presentImagePicker(
        access: PickAccess = .copy,
        completion: @escaping ([URL]?) -> Void
    ) {
        present(contentTypes: [.item], access: access, allowMultiple: true, completion: completion)
    }

    // MARK: - 通用呈现

    private func present(
        contentTypes: [UTType],
        access: PickAccess,
        allowMultiple: Bool,
        completion: @escaping ([URL]?) -> Void
    ) {
        guard let presenter = Self.topViewController() else {
            completion(nil)
            return
        }

        self.completion = completion

        // 已经有一个选择器在展示时，先关掉旧的，避免 present 失败后回调丢失。
        if let existing = presenter.presentedViewController, existing is UIDocumentPickerViewController {
            existing.dismiss(animated: false)
        }

        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: contentTypes,
            asCopy: access == .copy
        )
        picker.delegate = self
        picker.allowsMultipleSelection = allowMultiple
        picker.shouldShowFileExtensions = true
        activePicker = picker

        presenter.present(picker, animated: true)
    }

    // MARK: - UIDocumentPickerDelegate

    func documentPicker(
        _ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]
    ) {
        finish(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finish(nil)
    }

    // MARK: - Private

    private func finish(_ urls: [URL]?) {
        let completion = self.completion
        self.completion = nil

        guard let picker = activePicker, picker.presentingViewController != nil else {
            completion?(urls)
            return
        }

        picker.dismiss(animated: true) {
            completion?(urls)
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
