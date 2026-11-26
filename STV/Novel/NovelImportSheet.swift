import SwiftUI
import UniformTypeIdentifiers

/// ui-redesign 07: one sheet for every import path — local books, a source URL, the clipboard or a source file.
/// Results stay in the sheet as a banner instead of an alert.
struct NovelImportSheet: View {
    var onLocalFiles: () -> Void = {}
    /// 书源 page opens the sheet without the 书籍 group.
    var showBooks = true
    @ObservedObject private var store = LegadoSourceStore.shared
    @State private var url = ""
    @State private var busy = false
    @State private var fileImport = false
    @State private var result: Result?

    struct Result: Equatable { var ok: Bool; var title: String; var detail: String? }

    var body: some View {
        DSSheet("导入", closeID: "import.close") {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if showBooks {
                        label("书籍")
                        group {
                            row("doc.text", "本地 TXT / EPUB", "可多选，自动识别编码和章节", id: "import.local", action: onLocalFiles)
                        }
                    }
                    label("书源（阅读 / Legado 格式）")
                    HStack(spacing: 10) {
                        DSTextField("https://example.invalid/src.json", text: $url, icon: "link", id: "import.url")
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .submitLabel(.go).onSubmit(importURL)
                        Button { url = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" } label: { MiniButtonLabel(title: "粘贴") }
                            .buttonStyle(PressScale())
                    }
                    Button(action: importURL) {
                        ZStack {
                            PillButtonLabel(title: busy ? "" : "导入书源", tone: .accent, expand: true)
                            if busy { DSSpinner(size: 18, tint: STVTheme.onAccent) }
                        }
                    }
                    .buttonStyle(PressScale(scale: 0.98)).disabled(busy).padding(.top, 10).accessibilityIdentifier("import.submit")
                    group {
                        row("doc.on.clipboard", "从剪贴板导入", "支持书源 JSON 或书源链接", id: "import.clipboard", action: importClipboard)
                        Hairline()
                        row("folder", "从文件导入", "选择 .json 书源文件", id: "import.file") { fileImport = true }
                    }
                    .padding(.top, 10)
                    if let result { banner(result).padding(.top, 12).transition(.move(edge: .bottom).combined(with: .opacity)) }
                    Text("App 不内置任何书源，导入的书源只保存在本机。")
                        .font(.system(size: 12)).foregroundStyle(STVTheme.tertiary).lineSpacing(6).padding(.horizontal, 4).padding(.top, 12)
                }
                .padding(.horizontal, 20).padding(.bottom, 34)
                .animation(DS.panel, value: result)
            }
            .compatScrollBounceBasedOnSize()
        }
        .dsSheetChrome(showBooks ? [.height(650), .large] : [.height(540), .large])
        .fileImporter(isPresented: $fileImport, allowedContentTypes: [.json, .plainText, .text]) { r in
            guard case .success(let u) = r else { return }
            let scoped = u.startAccessingSecurityScopedResource()
            defer { if scoped { u.stopAccessingSecurityScopedResource() } }
            report { try store.add(LegadoSourceStore.parse(try Data(contentsOf: u))) }
        }
    }

    private func label(_ t: String) -> some View {
        Text(t).dsFont(13, .semibold, relativeTo: .footnote).foregroundStyle(STVTheme.secondary).padding(.horizontal, 4).padding(.top, 12).padding(.bottom, 8)
    }

    private func group<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(spacing: 0) { c() }.padding(.horizontal, 14)
            .background(STVTheme.glass, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func row(_ icon: String, _ title: String, _ sub: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                IconWell(systemName: icon, size: 40, corner: 12)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 16, weight: .medium)).foregroundStyle(STVTheme.text)
                    Text(sub).font(.system(size: 12)).foregroundStyle(STVTheme.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(STVTheme.tertiary)
            }
            .frame(minHeight: 66).contentShape(Rectangle())
        }
        .buttonStyle(PressScale(scale: 0.98))
        .accessibilityIdentifier(id)
    }

    private func banner(_ r: Result) -> some View {
        HStack(spacing: 10) {
            Image(systemName: r.ok ? "checkmark.circle" : "exclamationmark.circle").font(.system(size: 18, weight: .medium))
            VStack(alignment: .leading, spacing: 1) {
                Text(r.title).font(.system(size: 14, weight: .semibold))
                if let d = r.detail { Text(d).font(.system(size: 12)).foregroundStyle(STVTheme.secondary) }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(r.ok ? STVTheme.ok : STVTheme.accentWarm)
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(r.ok ? STVTheme.okSoft : STVTheme.warmSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityIdentifier("import.result")
    }

    private func report(_ f: () throws -> (added: Int, updated: Int, unsupported: Int)) {
        do {
            let r = try f()
            let allUnsupported = r.unsupported > 0 && r.unsupported == r.added + r.updated
            result = Result(ok: !allUnsupported, title: allUnsupported ? "当前书源类型不支持" : "新增 \(r.added) 个，更新 \(r.updated) 个",
                            detail: r.unsupported > 0 ? "其中 \(r.unsupported) 个类型/规则暂不支持，不会启用。漫画/仅下载类型或所需规则尚未实现；文本、有声、视频和 RSS 按各自运行时处理，不表示网站失效。" : nil)
        } catch { result = Result(ok: false, title: "导入失败", detail: (error as? LegadoSourceImportError)?.localizedDescription ?? "不是有效的 Legado 文本/媒体/RSS 源 JSON") }
    }

    private func importClipboard() {
        guard let t = UIPasteboard.general.string, !t.isEmpty else { result = Result(ok: false, title: "剪贴板是空的"); return }
        if let u = URL(string: t.trimmingCharacters(in: .whitespacesAndNewlines)), u.scheme?.hasPrefix("http") == true { url = u.absoluteString; importURL(); return }
        report { try store.importText(t) }
    }

    private func importURL() {
        let text=url.trimmingCharacters(in:.whitespacesAndNewlines)
        if text.hasPrefix("{") || text.hasPrefix("[") {
            DS.endEditing();report {try store.importText(text)};return
        }
        guard let u = URL(string: text), u.scheme?.hasPrefix("http") == true else {
            result = Result(ok: false, title: "网址无效", detail: "请输入 http(s) 开头的书源地址"); return
        }
        DS.endEditing(); busy = true
        Task {
            do { let r = try await store.importURL(u); report { r } }
            catch { result = Result(ok: false, title: "导入失败", detail: error.localizedDescription) }
            busy = false
        }
    }
}
