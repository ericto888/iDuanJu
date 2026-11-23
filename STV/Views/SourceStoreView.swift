import SwiftUI

/// iDuanJu online source catalog. The catalog only distributes idj1 plugins;
/// MacCMS, M3U and user-entered source URLs remain in their existing workflows.
struct SourceStoreView: View {
    private static let catalogURL = "https://raw.githubusercontent.com/ericto888/iduanju-sources/main/index.json"

    private struct Catalog: Decodable {
        struct Category: Decodable, Identifiable {
            let id: String
            let name: String
        }
        struct Entry: Decodable, Identifiable {
            let id: String
            let name: String
            let manifest: String
            let type: String?
            let adult: Bool?
            let version: String?
            let description: String?
            let category: String?
            let author: String?
            var isAdult: Bool { adult ?? false }
        }
        let schema: Int
        let name: String?
        let updatedAt: String?
        let categories: [Category]
        let plugins: [Entry]
    }

    @ObservedObject private var store = PluginStore.shared
    @ObservedObject private var gate = SourceGate.shared
    @State private var catalog: Catalog?
    @State private var category = "all"
    @State private var keyword = ""
    @State private var loading = false
    @State private var preparingID: String?
    @State private var pending: PendingInstall?
    @State private var message: String?

    private var visibleEntries: [Catalog.Entry] {
        (catalog?.plugins ?? []).filter { entry in
            (!entry.isAdult || gate.unlocked)
                && (category == "all" || entry.category == category)
                && (keyword.isEmpty || [entry.name, entry.id, entry.description ?? "", entry.author ?? ""]
                    .joined(separator: " ").localizedCaseInsensitiveContains(keyword))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(catalog?.name ?? "iDuanJu 站源商店")
                            .font(.title2.weight(.bold)).foregroundStyle(STVTheme.text)
                        Text("独立站源 · 在线安装 · 持续更新")
                            .font(.caption).foregroundStyle(STVTheme.secondary)
                    }
                    Spacer()
                    Button {
                        Task { await loadCatalog() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(STVTheme.accent)
                            .padding(10)
                            .background(STVTheme.surface, in: Circle())
                    }
                    .disabled(loading)
                    .accessibilityIdentifier("sourceStore.refresh")
                }
                .padding(.horizontal, 16)

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(STVTheme.secondary)
                    TextField("搜索站源名称、作者或说明", text: $keyword)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .padding(12)
                .background(STVTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16)

                if let catalog {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            categoryChip("全部", id: "all")
                            ForEach(catalog.categories) { item in categoryChip(item.name, id: item.id) }
                        }.padding(.horizontal, 16)
                    }

                    if visibleEntries.isEmpty {
                        emptyState(keyword.isEmpty ? "这个分类暂时没有可用站源" : "没有找到匹配的站源")
                    } else {
                        VStack(spacing: 10) {
                            ForEach(visibleEntries) { entry in sourceCard(entry) }
                        }.padding(.horizontal, 16)
                    }

                    if let updatedAt = catalog.updatedAt {
                        Text("目录更新：\(updatedAt)")
                            .font(.caption2).foregroundStyle(STVTheme.secondary)
                            .frame(maxWidth: .infinity).padding(.top, 4)
                    }
                } else if loading {
                    ProgressView("正在加载站源目录…").frame(maxWidth: .infinity).padding(36)
                } else {
                    emptyState(message ?? "暂时无法连接站源商店，请稍后刷新")
                }

                Text("站源在独立沙箱中运行。安装或更新前会显示权限清单；权限发生变化时需要再次确认。手动输入地址添加站源的功能保持不变。")
                    .font(.caption2).foregroundStyle(STVTheme.secondary).padding(.horizontal, 16)
            }
            .padding(.vertical, 16)
        }
        .background(STVTheme.bg.ignoresSafeArea())
        .navigationTitle("站源商店")
        .navigationBarTitleDisplayMode(.inline)
        .task { if catalog == nil { await loadCatalog() } }
        .overlay {
            if loading && catalog != nil {
                ProgressView().padding(14).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .sheet(item: $pending) { item in
            PluginConsentSheet(pending: item) { accepted in
                pending = nil
                guard accepted else { return }
                do {
                    try store.commit(item)
                    message = "已安装 \(item.manifest.name) \(item.manifest.version)"
                } catch {
                    message = error.localizedDescription
                }
            }
        }
        .alert("站源商店", isPresented: Binding(
            get: { message != nil && pending == nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("好", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    private func categoryChip(_ title: String, id: String) -> some View {
        Button { category = id } label: {
            Text(title).font(.subheadline.weight(category == id ? .semibold : .regular))
                .foregroundStyle(category == id ? STVTheme.text : STVTheme.secondary)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(category == id ? STVTheme.glassBorder : STVTheme.surface, in: Capsule())
        }.buttonStyle(.plain)
    }

    // Installed entries always expose a live manifest check; catalog version metadata is only advisory.
    private func sourceCard(_ entry: Catalog.Entry) -> some View {
        let installed = store.plugin(entry.id)
        // If the catalog omits its cached version, still let the user check the
        // remote manifest; prepare() will validate the actual version before commit.
        let isCurrent: Bool
        if let installed, let version = entry.version {
            isCurrent = PluginManifest.compare(installed.manifest.version, version) >= 0
        } else {
            isCurrent = false
        }
        return HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 12)
                .fill(STVTheme.glass)
                .frame(width: 46, height: 46)
                .overlay {
                    Image(systemName: entry.isAdult ? "lock.fill" : "puzzlepiece.extension")
                        .font(.system(size: 19, weight: .medium)).foregroundStyle(STVTheme.accent)
                }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(entry.name).font(.headline).foregroundStyle(STVTheme.text)
                    if entry.isAdult { Text("18+").font(.caption2.weight(.semibold)).foregroundStyle(STVTheme.accentWarm) }
                }
                Text(entry.description ?? "iDuanJu idj1 站源")
                    .font(.caption).foregroundStyle(STVTheme.secondary).lineLimit(2)
                HStack(spacing: 8) {
                    if let type = entry.type { Text(typeLabel(type)) }
                    if let version = entry.version { Text("v\(version)") }
                    if let author = entry.author { Text(author) }
                }.font(.caption2).foregroundStyle(STVTheme.secondary)
            }
            Spacer(minLength: 4)
            if let installed {
                VStack(alignment: .trailing, spacing: 4) {
                    Text("已安装 v\(installed.manifest.version)")
                        .font(.caption2).foregroundStyle(STVTheme.secondary)
                    Button(preparingID == entry.id ? "检查中" : "检查更新") {
                        Task { await prepare(entry) }
                    }.buttonStyle(.borderedProminent).tint(STVTheme.accent).disabled(preparingID != nil)
                }
            } else {
                Button(preparingID == entry.id ? "处理中" : "安装") {
                    Task { await prepare(entry) }
                }.buttonStyle(.borderedProminent).tint(STVTheme.accent).disabled(preparingID != nil)
            }
        }
        .padding(14)
        .background(STVTheme.surface, in: RoundedRectangle(cornerRadius: 15))
        .accessibilityIdentifier("sourceStore.entry.\(entry.id)")
    }

    private func typeLabel(_ value: String) -> String {
        switch value {
        case "video": return "长视频"
        case "shortdrama": return "短剧"
        case "comic": return "漫画"
        case "live": return "直播"
        default: return value
        }
    }

    private func emptyState(_ title: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 28)).foregroundStyle(STVTheme.secondary)
            Text(title).font(.subheadline).foregroundStyle(STVTheme.secondary)
            if catalog == nil {
                Text("目录地址：iduanju-sources / index.json")
                    .font(.caption2).foregroundStyle(STVTheme.secondary)
            }
            Button("重新加载") { Task { await loadCatalog() } }
                .font(.subheadline.weight(.semibold)).foregroundStyle(STVTheme.accent)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity).padding(28)
        .background(STVTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
    }

    @MainActor private func loadCatalog() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let freshCatalogURL = Self.catalogURL + "?_=" + String(Int(Date().timeIntervalSince1970))
            let data = try await PluginInstaller.download(freshCatalogURL, limit: 1 << 20)
            let decoded = try JSONDecoder().decode(Catalog.self, from: data)
            guard decoded.schema == 1 else { throw PluginError.install("站源目录版本不兼容") }
            catalog = decoded
            message = nil
        } catch {
            message = "站源目录加载失败：\(error.localizedDescription)"
        }
    }

    @MainActor private func prepare(_ entry: Catalog.Entry) async {
        guard preparingID == nil else { return }
        preparingID = entry.id
        defer { preparingID = nil }
        do {
            let candidate = try await PluginInstaller.prepare(manifestURL: entry.manifest, origin: "iDuanJu 站源商店")
            if let installed = store.plugin(entry.id) {
                let comparison = PluginManifest.compare(candidate.manifest.version, installed.manifest.version)
                if comparison > 0 {
                    pending = candidate
                } else if comparison == 0 {
                    message = "\(entry.name) 已是最新版本 v\(installed.manifest.version)"
                } else {
                    message = "远程版本 v\(candidate.manifest.version) 低于已安装版本 v\(installed.manifest.version)，为避免降级已取消"
                }
            } else {
                pending = candidate
            }
        } catch {
            message = "检查/准备站源更新失败：\(error.localizedDescription)"
        }
    }
}
