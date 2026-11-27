import SwiftUI

/// 我的 → 数据备份与迁移 → WebDAV 多端同步
struct WebDAVSyncView: View {
    @ObservedObject private var sync = WebDAVSync.shared
    @State private var message: String?
    @State private var showPassword = false
    @State private var confirmClear = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statusHeader

                DSSection("常用服务快捷填充", separatorInset: 58) {
                    DSRow("坚果云 WebDAV", icon: "cloud", subtitle: "https://dav.jianguoyun.com/dav/") {
                        sync.serverURL = "https://dav.jianguoyun.com/dav/"
                        if sync.remoteFolder.isEmpty { sync.remoteFolder = "iDuanJu" }
                        message = "已填入坚果云地址，请填写注册邮箱与应用密码"
                    }
                    DSRow("Alist / OpenList / NAS", icon: "externaldrive.connected.to.line.below", subtitle: "支持局域网 http:// 与公网 https://") {
                        if sync.serverURL.isEmpty { sync.serverURL = "https://your-nas.example.com/dav/" }
                        message = "请将地址改为你的 WebDAV 根路径"
                    }
                }

                DSSection("服务器配置", footer: "密码保存在系统钥匙串（Keychain）中，不会写入导出的备份文件。坚果云请前往网页版「安全选项」生成应用专用密码。", separatorInset: 16) {
                    VStack(spacing: 12) {
                        DSTextField("服务器地址，如 https://dav.jianguoyun.com/dav/", text: $sync.serverURL, icon: "link")
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        DSTextField("账号 / 邮箱", text: $sync.username, icon: "person")
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        passwordField
                        DSTextField("远程目录（默认 iDuanJu）", text: $sync.remoteFolder, icon: "folder")
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .padding(14)

                    Toggle(isOn: Binding(get: { sync.autoSync }, set: { sync.autoSync = $0; sync.saveConfig() })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("自动多端同步").dsFont(15, .medium).foregroundStyle(STVTheme.text)
                            Text("启动与切到后台时自动双向合并进度和插件").dsFont(12, relativeTo: .caption).foregroundStyle(STVTheme.secondary)
                        }
                    }
                    .toggleStyle(DSSwitch())
                    .dsRow()
                }

                VStack(spacing: 10) {
                    Button { runAction { try await sync.syncNow() } } label: {
                        PillButtonLabel(title: sync.busy ?? "立即双向同步（推荐）", icon: "arrow.triangle.2.circlepath", expand: true)
                    }
                    .buttonStyle(PressScale(scale: 0.98))
                    .disabled(sync.busy != nil)
                    .opacity(sync.busy != nil ? 0.55 : 1)

                    HStack(spacing: 10) {
                        Button { runAction { try await sync.testConnection() } } label: {
                            PillButtonPlain(title: "测试并保存", icon: "checkmark.shield", height: 42, expand: true)
                        }
                        .disabled(sync.busy != nil)
                        Button { runAction { try await sync.pushOnly() } } label: {
                            PillButtonPlain(title: "仅上传", icon: "icloud.and.arrow.up", height: 42, expand: true)
                        }
                        .disabled(sync.busy != nil)
                        Button { runAction { try await sync.pullOnly() } } label: {
                            PillButtonPlain(title: "仅拉取", icon: "icloud.and.arrow.down", height: 42, expand: true)
                        }
                        .disabled(sync.busy != nil)
                    }
                    .buttonStyle(PressScale(scale: 0.98))
                }
                .padding(.horizontal, 16)

                if sync.isConfigured {
                    DSSection("管理") {
                        DSRow("清除 WebDAV 配置", icon: "trash", role: .destructive) {
                            confirmClear = true
                        }
                    }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .dsNavigation("WebDAV 多端同步")
        .dsConfirm("清除 WebDAV 配置？", isPresented: $confirmClear, message: "仅清除本机保存的服务器信息与钥匙串密码，不会删除云端已同步文件。", confirm: "清除配置") {
            sync.clearConfig()
            message = "已清除 WebDAV 配置"
        }
        .dsToast($message, icon: "checkmark.circle.fill", bottom: 16)
    }

    private var statusHeader: some View {
        HStack(spacing: 12) {
            IconWell(systemName: sync.isConfigured ? "icloud.and.arrow.up" : "icloud.slash", size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(sync.isConfigured ? "多端智能合并同步" : "尚未配置 WebDAV")
                    .dsFont(16, .semibold, relativeTo: .headline)
                    .foregroundStyle(STVTheme.text)
                Text(statusDetail)
                    .dsFont(12, relativeTo: .caption)
                    .foregroundStyle(STVTheme.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .dsCard(20)
        .padding(.horizontal, 16)
    }

    private var statusDetail: String {
        if let busy = sync.busy { return busy }
        if let st = sync.lastStatus {
            if let at = sync.lastSyncAt {
                return "\(st) · \(at.formatted(.dateTime.month().day().hour().minute()))"
            }
            return st
        }
        return "同步观看进度、我的收藏、已安装插件及脚本、订阅源、CMS、TVBox、首页排序与阅读书源。"
    }

    private var passwordField: some View {
        HStack(spacing: 10) {
            Image(systemName: "key")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(STVTheme.secondary)
                .frame(width: 18)
            Group {
                if showPassword {
                    TextField("应用密码", text: $sync.password)
                } else {
                    SecureField("应用密码", text: $sync.password)
                }
            }
            .font(.system(size: 15))
            .foregroundStyle(STVTheme.text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            Button { showPassword.toggle() } label: {
                Image(systemName: showPassword ? "eye.slash" : "eye")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(STVTheme.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showPassword ? "隐藏密码" : "显示密码")
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(STVTheme.glass, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func runAction(_ work: @escaping () async throws -> String) {
        Task {
            do {
                message = try await work()
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
