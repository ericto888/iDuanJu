import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Imperative wrapper around `UIDocumentPickerViewController(..., asCopy: true)`.
///
/// Why not SwiftUI `.fileImporter`?
/// 1. `.fileImporter` opens security-scoped URLs in-place (`asCopy: false`), which fails or blocks on external
///    FileProviders (iCloud Drive / WeChat / Telegram) unless coordinated off the main thread.
/// 2. `.fileImporter` invokes its callback *before* the picker's dismissal animation finishes, so presenting a
///    follow-up `.sheet` (e.g. `PluginConsentSheet`) immediately gets dropped by UIKit ("Attempt to present while a
///    dismissal is in progress").
/// 3. Presenting `.fileImporter` from inside or right after dismissing another `.sheet` (`NovelImportSheet`) silently
///    wedges SwiftUI's presentation bridge on iOS 17–26.
@MainActor
enum SystemFilePicker {
    private static var activeSession: Session?

    static func pick(
        types: [UTType] = [.item, .data, .content],
        multiple: Bool = false
    ) async -> [URL] {
        guard activeSession == nil else { return [] }
        // Wait if a preceding sheet (e.g. import options) is still animating out so UIKit does not drop presentation.
        for _ in 0..<25 {
            if !hasDismissingModal() { break }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        guard activeSession == nil, let presenter = topViewController() else { return [] }
        // Always include `.item` and `.data` so custom extensions (.idjplugin, .m3u, .json/txt downloaded as public.data) are selectable.
        var allTypes = types
        for fallback in [UTType.data, UTType.item] where !allTypes.contains(fallback) {
            allTypes.append(fallback)
        }
        return await withCheckedContinuation { cont in
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: allTypes, asCopy: true)
            picker.allowsMultipleSelection = multiple
            let session = Session(picker: picker, continuation: cont)
            activeSession = session
            picker.delegate = session
            picker.presentationController?.delegate = session
            presenter.present(picker, animated: true)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 150_000_000)
                if activeSession === session, picker.presentingViewController == nil, !picker.isBeingPresented {
                    await session.finish([])
                }
            }
        }
    }

    /// Off-main helper: reads a copied temporary URL and removes the temporary copy afterwards.
    nonisolated static func readAndClean(_ url: URL, maxBytes: Int? = nil) throws -> (name: String, ext: String, data: Data) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
            try? FileManager.default.removeItem(at: url)
        }
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        if let maxBytes,
           let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize),
           size > maxBytes {
            throw CocoaError(.fileReadTooLarge)
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        if let maxBytes, data.count > maxBytes {
            throw CocoaError(.fileReadTooLarge)
        }
        return (name, ext, data)
    }

    private static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes
            .first { $0.activationState == .foregroundActive }?
            .windows.first { $0.isKeyWindow }
            ?? scenes.flatMap(\.windows).first { $0.isKeyWindow }
            ?? scenes.flatMap(\.windows).first
    }

    private static func hasDismissingModal() -> Bool {
        var cur = keyWindow()?.rootViewController
        while let presented = cur?.presentedViewController {
            if presented.isBeingDismissed { return true }
            cur = presented
        }
        return false
    }

    private static func topViewController() -> UIViewController? {
        var top = keyWindow()?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }

    @MainActor
    private final class Session: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
        private weak var picker: UIDocumentPickerViewController?
        private var continuation: CheckedContinuation<[URL], Never>?

        init(picker: UIDocumentPickerViewController, continuation: CheckedContinuation<[URL], Never>) {
            self.picker = picker
            self.continuation = continuation
        }

        nonisolated func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            Task { @MainActor in await self.finish(urls) }
        }

        nonisolated func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            Task { @MainActor in await self.finish([]) }
        }

        nonisolated func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            Task { @MainActor in await self.finish([]) }
        }

        fileprivate func finish(_ urls: [URL]) async {
            guard let cont = continuation else { return }
            continuation = nil
            // Wait until UIKit has fully torn down the picker transition before returning to callers that present sheets.
            for _ in 0..<25 {
                if picker?.presentingViewController == nil && picker?.isBeingDismissed != true { break }
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
            SystemFilePicker.activeSession = nil
            cont.resume(returning: urls)
        }
    }
}
