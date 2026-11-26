import SwiftUI

/// 书源登录: the source's loginUi form (text / password / select / button) or, for a plain login URL, the
/// in-app browser. Values are saved as the source's login info; 「登录」 runs the source's `login()`.
struct NovelSourceLoginView: View {
    let source: LegadoSource
    @State private var fields: [LegadoClient.LoginField] = []
    @State private var values: [String: String] = [:]
    @State private var busy = false
    @State private var message: String?
    @State private var loggedIn = false

    var body: some View {
        let inputs = fields.filter { $0.type != "button" }, buttons = fields.filter { $0.type == "button" }
        let canLogin = LegadoClient.loginJS(source) != nil
        DSSheet(source.bookSourceName, subtitle: "书源登录") {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    DSSection {
                        HStack(spacing: 10) {
                            Circle().fill(loggedIn ? STVTheme.ok : STVTheme.tertiary).frame(width: 8, height: 8)
                            Text(loggedIn ? "已登录 / 已保存登录信息" : "未登录").dsFont(15, .medium).foregroundStyle(loggedIn ? STVTheme.ok : STVTheme.secondary)
                            Spacer(minLength: 0)
                            if loggedIn {
                                Button { LegadoSourceState.logout(source.bookSourceUrl); values = [:]; loggedIn = false } label: { MiniButtonLabel(title: "退出登录", tint: DSTone.danger, ground: DSTone.dangerSoft) }
                                    .buttonStyle(PressScale())
                            }
                        }
                        .dsRow()
                    }
                    if let url = LegadoClient.loginPage(source) {
                        DSSection(footer: "在网页里登录账号后点右上角「完成」，登录状态（Cookie）会用于这个书源的请求。") {
                            DSRow("在内置浏览器里登录", icon: "safari", chevron: true) {
                                Task { await LegadoBrowser.open(url: url, html: nil, title: "登录 " + source.bookSourceName, sourceURL: source.bookSourceUrl); refresh() }
                            }
                            .accessibilityIdentifier("login.browser")
                        }
                    }
                    if !inputs.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(inputs, id: \.name) { f in input(f) }
                            Button { save(); message = "已保存" } label: { PillButtonPlain(title: "保存") }.buttonStyle(PressScale(scale: 0.98))
                        }
                        .padding(.horizontal, 20)
                    }
                    if !buttons.isEmpty {
                        DSSection {
                            ForEach(buttons, id: \.name) { f in
                                DSRow(f.name, icon: "bolt") { run(f.action ?? "") }.disabled(busy || (f.action ?? "").isEmpty)
                            }
                        }
                    }
                    if let message {
                        Text(message).dsFont(14, .medium, relativeTo: .subheadline).foregroundStyle(STVTheme.accent)
                            .padding(.horizontal, 20).textSelection(.enabled)
                    }
                }
                .padding(.bottom, 16)
            }
        } footer: {
            if canLogin {
                DSSheetFooter {
                    Button { save(); run("typeof login === 'function' ? login() : ''") } label: {
                        ZStack {
                            PillButtonLabel(title: busy ? "" : "登录", expand: true)
                            if busy { DSSpinner(size: 18, tint: STVTheme.onAccent) }
                        }
                    }
                    .buttonStyle(PressScale(scale: 0.98))
                    .disabled(busy)
                    .accessibilityLabel("登录")
                    .accessibilityIdentifier("login.submit")
                }
            }
        }
        .dsSheetChrome([.large])
        .onAppear {
            fields = LegadoClient.loginFields(source)
            values = LegadoSourceState.loginInfo(source.bookSourceUrl)
            for f in fields where values[f.name] == nil && !f.defaultValue.isEmpty && f.type == "select" { values[f.name] = f.defaultValue }
            refresh()
        }
    }

    @ViewBuilder private func input(_ f: LegadoClient.LoginField) -> some View {
        let b = Binding(get: { values[f.name] ?? "" }, set: { values[f.name] = $0 })
        switch f.type {
        case "password": DSTextField(f.name, text: b, icon: "lock", secure: true)
        case "select":
            DSPicker(f.name, options: f.options, selection: b, style: .row) { $0 }
                .background(STVTheme.glass, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        default: DSTextField(f.name, text: b, icon: "person").textInputAutocapitalization(.never).autocorrectionDisabled()
        }
    }

    private func refresh() { loggedIn = LegadoSourceState.isLoggedIn(source.bookSourceUrl) }

    private func save() {
        if !values.isEmpty { LegadoSourceState.setLoginInfo(source.bookSourceUrl, values) }
    }

    private func run(_ action: String) {
        let s = source
        busy = true; message = nil
        Task {
            do {
                let r = try await LegadoClient.run { try LegadoClient.runLogin(s, action) }
                message = r.isEmpty ? "已执行" : r
            } catch {
                message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            busy = false
            refresh()
        }
    }
}
