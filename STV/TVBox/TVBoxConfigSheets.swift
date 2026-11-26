import SwiftUI

struct TVBoxNotice: Equatable {
    let text: String
    let bad: Bool
}

/// Progress and failure of an import, inside the sheet that started it.
private struct SheetStatus: View {
    let busy: String?
    let error: TVBoxNotice?
    var body: some View {
        if let busy {
            HStack(spacing: 8) { DSSpinner(size: 14); Text(busy).dsFont(13, relativeTo: .footnote).foregroundStyle(STVTheme.secondary) }
        } else if let error, error.bad {
            Text(error.text).dsFont(13, relativeTo: .footnote).foregroundStyle(STVTheme.accentWarm).lineLimit(4).accessibilityIdentifier("tvbox.sheet.error")
        }
    }
}

/// Pinned action of a sheet with its own progress.
private struct SheetAction: View {
    let title: String
    let busy: Bool
    let enabled: Bool
    let id: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack {
                PillButtonLabel(title: busy ? "" : title, expand: true)
                if busy { DSSpinner(size: 18, tint: STVTheme.onAccent) }
            }
        }
        .buttonStyle(PressScale(scale: 0.98))
        .disabled(busy || !enabled).opacity(enabled ? 1 : 0.4)
        .accessibilityIdentifier(id)
    }
}

// MARK: - Import

/// 粘贴内容: a config, a channel list, or just an address.
struct TVBoxPasteSheet: View {
    let busy: String?
    let error: TVBoxNotice?
    let submit: (String) -> Void
    @State private var text = ""

    var body: some View {
        DSSheet("粘贴内容", subtitle: "配置 JSON、M3U / TXT 频道列表或地址") {
            VStack(alignment: .leading, spacing: 10) {
                DSTextEditor(placeholder: "配置 JSON、M3U / TXT 频道列表或地址", text: $text, mono: true)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("tvbox.paste.text")
                SheetStatus(busy: busy, error: error)
            }
            .padding(.horizontal, 20)
        } footer: {
            DSSheetFooter {
                Button { text = UIPasteboard.general.string ?? text } label: { PillButtonPlain(title: "从剪贴板") }.buttonStyle(PressScale(scale: 0.98))
                SheetAction(title: "导入", busy: busy != nil, enabled: !text.trimmed.isEmpty, id: "tvbox.paste.import") { submit(text) }
            }
        }
        .dsSheetChrome([.large])
    }
}

/// 手动加站: one 苹果 CMS endpoint.
struct TVBoxManualSheet: View {
    let adult: Bool
    let busy: String?
    let error: TVBoxNotice?
    let submit: (String, String, Bool) -> Void
    @State private var name = ""
    @State private var api = ""
    @State private var isAdult = false

    var body: some View {
        DSSheet("手动加站", subtitle: "苹果 CMS 采集接口，加入「自建配置」") {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    DSTextField("站点名称（可选）", text: $name, icon: "tag")
                    DSTextField("http(s)://…/api.php/provide/vod/", text: $api, icon: "link", id: "tvbox.manual.api")
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    if adult {
                        HStack(spacing: 12) {
                            Text("成人内容（隐藏在片源管理之后）").dsFont(15).foregroundStyle(STVTheme.text).frame(maxWidth: .infinity, alignment: .leading)
                            DSSwitchControl(isOn: $isAdult, label: "成人内容")
                        }
                        .padding(.vertical, 6)
                    }
                    SheetStatus(busy: busy, error: error)
                }
                .padding(.horizontal, 20).padding(.bottom, 12)
            }
        } footer: {
            DSSheetFooter {
                SheetAction(title: "添加", busy: busy != nil, enabled: !api.trimmed.isEmpty, id: "tvbox.manual.add") { submit(name, api, isAdult) }
            }
        }
        .dsSheetChrome([.medium, .large])
    }
}

/// Entries of a 多仓; picking one imports it.
struct TVBoxDepotSheet: View {
    let depot: DepotRecord
    /// Address of the active config.
    let current: String?
    let busy: String?
    let error: TVBoxNotice?
    let pick: (TVBoxDepotEntry) -> Void

    var body: some View {
        DSSheet(depot.name, subtitle: "\(depot.entries.count) 个配置") {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    SheetStatus(busy: busy, error: error).padding(.horizontal, 20).padding(.vertical, busy == nil && error?.bad != true ? 0 : 8)
                    ForEach(depot.entries) { e in
                        Button { DS.tick(); pick(e) } label: { TVBoxRow(title: e.name, note: e.url, selected: e.url == current) }
                            .buttonStyle(DSRowPress())
                            .disabled(busy != nil)
                            .accessibilityIdentifier("tvbox.depot.entry")
                        if e.url != depot.entries.last?.url { Hairline().padding(.leading, 16) }
                    }
                }
                .padding(.bottom, 24)
            }
        }
        .dsSheetChrome()
    }
}

// MARK: - One config

/// 更多: refresh, rename, trust, address, delete.
struct TVBoxRepoSheet: View {
    enum Choice { case refresh, rename, trust, remove }
    let repo: TVBoxRepo
    let choose: (Choice) -> Void
    @State private var copied: String?

    private var remote: Bool { !repo.record.url.isEmpty }

    var body: some View {
        DSSheet(repo.name) {
            ScrollView {
                VStack(spacing: 18) {
                    DSSection(separatorInset: 58) {
                        if remote { DSRow("刷新", icon: "arrow.clockwise", subtitle: "重新获取配置，站点的缓存一并更新") { choose(.refresh) }.accessibilityIdentifier("tvbox.repo.refresh") }
                        DSRow("重命名", icon: "pencil") { choose(.rename) }.accessibilityIdentifier("tvbox.repo.rename")
                        if repo.hasCode {
                            DSRow(repo.trusted ? "取消信任" : "信任", icon: repo.trusted ? "shield.slash" : "shield", subtitle: repo.trusted ? "它的代码站点将停止运行" : nil) { choose(.trust) }
                                .accessibilityIdentifier("tvbox.repo.trust")
                        }
                        if remote {
                            DSRow("地址", icon: "link", subtitle: repo.record.url) {
                                UIPasteboard.general.string = repo.record.url
                                copied = "已复制地址"
                            }
                        }
                    }
                    DSSection(separatorInset: 58) { DSRow("删除", icon: "trash", role: .destructive) { choose(.remove) }.accessibilityIdentifier("tvbox.repo.delete") }
                }
                .padding(.top, 4).padding(.bottom, 24)
            }
        }
        .dsToast($copied, icon: "checkmark.circle.fill")
        .dsSheetChrome([.height(CGFloat(150 + rows * 64)), .large])
    }

    private var rows: Int { 2 + (remote ? 2 : 0) + (repo.hasCode ? 1 : 0) }
}

/// 默认解析.
struct TVBoxParseSheet: View {
    let repo: TVBoxRepo
    let pick: (String) -> Void

    var body: some View {
        DSSheet("默认解析") {
            DSOptionList(options: [""] + repo.config.parses.map(\.name), selected: repo.record.parse, label: { $0.isEmpty ? "自动（超级解析）" : $0 }, note: note, pick: pick)
        }
        .dsSheetChrome()
    }

    private func note(_ name: String) -> String? {
        if name.isEmpty { return "JSON 解析与网页嗅探同时进行，先到先用" }
        guard let p = repo.config.parses.first(where: { $0.name == name }) else { return nil }
        switch p.type {
        case 0: return "网页嗅探"
        case 1: return "JSON"
        case 2, 3: return "JAR 扩展（经桥接）"
        default: return "超级解析"
        }
    }
}

/// 安全 DNS.
struct TVBoxDohSheet: View {
    let options: [TVBoxDoh]
    let current: String
    let pick: (String) -> Void

    var body: some View {
        DSSheet("安全 DNS") {
            DSOptionList(options: [""] + options.map(\.name), selected: current, label: { $0.isEmpty ? "系统默认" : $0 }, note: { n in options.first { $0.name == n }?.url }, pick: pick)
        }
        .dsSheetChrome()
    }
}

// MARK: - JAR bridge

/// JAR 桥接: JAR sites run on a paired Android device in the same local network.
struct TVBoxBridgeSection: View {
    @ObservedObject private var status = BridgeClient.shared.status
    @State private var address = ""
    @State private var code = ""
    @State private var pairing = false
    @State private var error: String?
    @State private var unpairing = false

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        DSSection("JAR 桥接", footer: "iOS 不能运行 JAR：由同一局域网里的安卓设备代为运行已信任配置里的 JAR 站点。在安卓端「TVBox 配置 → 局域网桥接」打开开关，把那里的地址和 12 位配对码填到这里；每个请求都用配对码签名，配对码只保存在本机钥匙串。", separatorInset: 58) {
            if status.paired && !pairing {
                device
                DSRow("解除配对", icon: "minus.circle", role: .destructive) { unpairing = true }.accessibilityIdentifier("tvbox.bridge.unpair")
            } else {
                form
            }
        }
        .dsConfirm("解除配对？", isPresented: $unpairing, message: "JAR 站点会停止工作，之后可以重新配对。", confirm: "解除") { BridgeClient.shared.unpair() }
        .task { if status.state == .unknown { await BridgeClient.shared.refresh() } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tvbox.bridge")
    }

    private var device: some View {
        HStack(spacing: 12) {
            IconWell(systemName: "personalhotspot", size: 32, corner: 10, tint: offline ? STVTheme.accentWarm : STVTheme.accent, ground: offline ? STVTheme.warmSoft : STVTheme.accentSoft)
            VStack(alignment: .leading, spacing: 3) {
                Text(status.address).dsFont(16, .medium).foregroundStyle(STVTheme.text).lineLimit(1).minimumScaleFactor(0.8)
                Text(detail).dsFont(12, relativeTo: .caption).foregroundStyle(offline ? STVTheme.accentWarm : STVTheme.secondary).lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if status.state == .checking { DSSpinner(size: 16) }
            else {
                Button { Task { await BridgeClient.shared.refresh() } } label: { MiniButtonLabel(title: "检测") }.buttonStyle(PressScale()).accessibilityIdentifier("tvbox.bridge.check")
            }
        }
        .dsRow()
    }

    private var offline: Bool { if case .offline = status.state { return true } else { return false } }
    private var detail: String {
        guard let seen = status.lastSeen, status.state != .online else { return status.text }
        return "\(status.text) · 上次连接 \(Self.clock.string(from: seen))"
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            DSTextField("安卓设备地址，如 192.168.1.2:\(BridgeClient.defaultPort)", text: $address, icon: "network", id: "tvbox.bridge.address")
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.numbersAndPunctuation)
            DSTextField("\(BridgeClient.codeLength) 位配对码", text: $code, icon: "key", mono: true, id: "tvbox.bridge.code")
                .textInputAutocapitalization(.characters).autocorrectionDisabled().keyboardType(.asciiCapable)
            if let error { Text(error).dsFont(13, relativeTo: .footnote).foregroundStyle(STVTheme.accentWarm).accessibilityIdentifier("tvbox.bridge.error") }
            SheetAction(title: "配对", busy: pairing, enabled: ready, id: "tvbox.bridge.pair", action: pair)
        }
        .dsRow(vertical: 14)
        .compatOnChange(of: address) { error = nil }
        .compatOnChange(of: code) { error = nil }
    }

    private var ready: Bool { !address.trimmed.isEmpty && BridgeClient.normalizeCode(code).count == BridgeClient.codeLength }

    private func pair() {
        DS.endEditing()
        pairing = true
        error = nil
        Task {
            do {
                try await BridgeClient.shared.pair(address: address, code: code)
                address = ""
                code = ""
            } catch { self.error = tvboxErrorText(error) }
            pairing = false
        }
    }
}
