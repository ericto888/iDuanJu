import SwiftUI

enum TGFmt {
    // Building a DateFormatter costs more than laying the card out: one per format, shared.
    private static let thisYear = formatter("M月d日 HH:mm"), older = formatter("yyyy年M月d日")
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = format
        return f
    }
    static func date(_ d: Date?) -> String {
        guard let d else { return "" }
        let s = Date().timeIntervalSince(d)
        if s < 60 { return "刚刚" }
        if s < 3600 { return "\(Int(s / 60)) 分钟前" }
        if s < 86400 { return "\(Int(s / 3600)) 小时前" }
        return (Calendar.current.isDate(d, equalTo: Date(), toGranularity: .year) ? thisYear : older).string(from: d)
    }
}

/// Post text with tappable links. Link detection runs once per text, not once per body.
@MainActor enum TGText {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private final class Box { let value: AttributedString; init(_ v: AttributedString) { value = v } }
    private static let cache: NSCache<NSString, Box> = { let c = NSCache<NSString, Box>(); c.countLimit = 400; return c }()
    static func attributed(_ text: String) -> AttributedString {
        if let hit = cache.object(forKey: text as NSString) { return hit.value }
        var a = AttributedString(text)
        let ns = text as NSString
        for m in detector?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? [] {
            guard let url = m.url, let r = Range(m.range, in: text),
                  let lo = AttributedString.Index(r.lowerBound, within: a), let hi = AttributedString.Index(r.upperBound, within: a) else { continue }
            a[lo..<hi].link = url
        }
        cache.setObject(Box(a), forKey: text as NSString)
        return a
    }
}

/// What a post card asks its feed to do. One reference per feed: closures inside a struct never compare equal, so every card
/// re-ran its body whenever anything in the feed changed.
final class TGActions {
    var openImages: (TGPost, Int) -> Void = { _, _ in }
    var playVideo: (TGPost, Int) -> Void = { _, _ in }
    var download: (TGPost, Int) -> Void = { _, _ in }
    var block: (TGPost) -> Void = { _ in }
    var bot: (TGBotLink) -> Void = { _ in }
}

/// One post in the 朋友圈-style feed: avatar · name · time, text, media grid, buttons, link preview.
struct TGPostCard: View {
    let post: TGPost
    let channel: TGChannel?
    var verdict: TGVerdict = .pass
    var actions = TGActions()
    @State private var expanded = false
    @State private var unfolded = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        if verdict.blocked && !unfolded {
            folded
        } else {
            card
        }
    }

    private var folded: some View {
        Button { withAnimation(DS.panel) { unfolded = true } } label: {
            HStack(spacing: 8) {
                Image(systemName: "eye.slash").font(.caption)
                Text("已屏蔽 · \(channel?.displayName ?? "@" + post.channel)").font(.caption.weight(.semibold))
                Text(verdict.reason).font(.caption).lineLimit(1)
                Spacer()
                Text("展开").font(.caption)
            }
            .foregroundStyle(STVTheme.secondary)
            .padding(.horizontal, 14).frame(minHeight: 44)
            .background(STVTheme.glass, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale(scale: 0.99))
        .accessibilityIdentifier("tg.folded.\(post.id)")
    }

    private var card: some View {
        HStack(alignment: .top, spacing: 10) {
            avatar
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(channel?.displayName ?? "@" + post.channel).font(.subheadline.weight(.semibold)).foregroundStyle(STVTheme.accent).lineLimit(1)
                    if channel?.isAdult == true { DSStatus(text: "18+", tone: .warn) }
                    Spacer(minLength: 0)
                    if verdict.blocked { Label("已屏蔽", systemImage: "eye.slash").font(.caption2).foregroundStyle(STVTheme.secondary) }
                }
                if !post.forwardedFrom.isEmpty {
                    Text("转发自 \(post.forwardedFrom)").font(.caption).foregroundStyle(STVTheme.secondary)
                }
                if !post.text.isEmpty { textBlock }
                if !post.media.isEmpty { TGMediaGrid(post: post, actions: actions) }
                if let p = post.preview, !(p.title.isEmpty && p.desc.isEmpty) { previewCard(p) }
                if !post.buttons.isEmpty { buttons }
                footer
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .contentShape(Rectangle())
        .contextMenu { menu }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tg.post.\(post.id)")
    }

    private var avatar: some View {
        Group {
            if let a = channel?.avatar, !a.isEmpty { CoverView(url: a, corner: 20, maxPixelSize: CoverPixels.thumb) }
            else {
                Circle().fill(STVTheme.elevated)
                    .overlay(Text(String((channel?.displayName ?? post.channel).prefix(1))).font(.headline).foregroundStyle(STVTheme.text))
            }
        }
        .frame(width: 40, height: 40).clipShape(Circle())
    }

    private var textBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            // No `.textSelection` here: it copies the whole text only (the long-press menu already does) and puts a text
            // interaction on every card of the feed.
            Text(TGText.attributed(post.text)).font(.body).foregroundStyle(STVTheme.text).lineLimit(expanded ? nil : 8)
                .tint(STVTheme.accent)
            if !expanded && (post.text.utf16.count > 260 || post.text.lazy.filter { $0 == "\n" }.prefix(8).count > 7) {
                Button { withAnimation(DS.panel) { expanded = true } } label: { Text("全文").font(.subheadline.weight(.medium)).foregroundStyle(STVTheme.accent).contentShape(Rectangle().inset(by: -8)) }
                    .buttonStyle(.plain)
            }
        }
    }

    private func previewCard(_ p: TGLinkPreview) -> some View {
        Button { if let u = URL(string: p.url) { openURL(u) } } label: {
            HStack(alignment: .top, spacing: 8) {
                Rectangle().fill(STVTheme.accent).frame(width: 3)
                VStack(alignment: .leading, spacing: 2) {
                    if !p.site.isEmpty { Text(p.site).font(.caption.weight(.semibold)).foregroundStyle(STVTheme.accent) }
                    if !p.title.isEmpty { Text(p.title).font(.subheadline.weight(.semibold)).foregroundStyle(STVTheme.text).lineLimit(2) }
                    if !p.desc.isEmpty { Text(p.desc).font(.caption).foregroundStyle(STVTheme.secondary).lineLimit(3) }
                }
                Spacer(minLength: 0)
                if !p.image.isEmpty { CoverView(url: p.image, corner: 8, maxPixelSize: CoverPixels.thumb).frame(width: 54, height: 54) }
            }
            .padding(10)
            .background(STVTheme.glass, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }.buttonStyle(PressScale(scale: 0.99))
    }

    private var buttons: some View {
        VStack(spacing: 6) {
            ForEach(Array(post.buttons.enumerated()), id: \.offset) { _, b in
                Button {
                    if let bot = TGBotLink(url: b.url) { actions.bot(bot) } else if let u = URL(string: b.url) { openURL(u) }
                } label: {
                    Text(b.text).font(.subheadline).foregroundStyle(STVTheme.text).lineLimit(1).frame(maxWidth: .infinity, minHeight: 40)
                        .background(STVTheme.glass, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .contentShape(Rectangle())
                }.buttonStyle(PressScale(scale: 0.98))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Text(TGFmt.date(post.date)).font(.caption).foregroundStyle(STVTheme.secondary)
            if !post.views.isEmpty { Label(post.views, systemImage: "eye").font(.caption).foregroundStyle(STVTheme.secondary) }
            Spacer()
            ForEach(post.botLinks, id: \.self) { b in
                Button { actions.bot(b) } label: { Label("@\(b.bot)", systemImage: "cpu").font(.caption) }
                    .foregroundStyle(STVTheme.accent).buttonStyle(.plain)
            }
            if post.media.contains(where: { $0.video != nil || $0.kind == .photo }) {
                Button { actions.download(post, firstDownloadable) } label: { Image(systemName: "arrow.down.circle").contentShape(Rectangle().inset(by: -10)) }
                    .foregroundStyle(STVTheme.secondary).buttonStyle(PressScale())
                    .accessibilityLabel("下载").accessibilityIdentifier("tg.download.\(post.id)")
            }
            Button { if let u = URL(string: post.permalink) { openURL(u) } } label: { Image(systemName: "paperplane").contentShape(Rectangle().inset(by: -10)) }
                .foregroundStyle(STVTheme.secondary).buttonStyle(PressScale()).accessibilityLabel("在 Telegram 中打开")
        }
    }

    private var firstDownloadable: Int { post.media.firstIndex { $0.video != nil } ?? 0 }

    @ViewBuilder private var menu: some View {
        Button { actions.block(post) } label: { Label("加入屏蔽…", systemImage: "hand.raised") }
        if !post.media.isEmpty {
            Button { for i in post.media.indices { actions.download(post, i) } } label: { Label("下载全部媒体（\(post.media.count)）", systemImage: "arrow.down.circle") }
        }
        Button { UIPasteboard.general.string = post.permalink } label: { Label("复制链接", systemImage: "link") }
        if !post.text.isEmpty { Button { UIPasteboard.general.string = post.text } label: { Label("复制文字", systemImage: "doc.on.doc") } }
        Button { if let u = URL(string: post.permalink) { openURL(u) } } label: { Label("在 Telegram 中打开", systemImage: "paperplane") }
    }
}

/// 1 item: full width; 2–4: 2 columns; 5+: 3 columns (朋友圈 grid).
struct TGMediaGrid: View {
    let post: TGPost
    var actions: TGActions
    var body: some View {
        let m = post.media
        if m.count == 1 {
            cell(0).aspectRatio(m[0].kind == .photo ? 4 / 3 : 16 / 9, contentMode: .fit).frame(maxWidth: .infinity)
        } else {
            let cols = m.count <= 4 ? 2 : 3, rows = (m.count + cols - 1) / cols
            // At most ten items: a lazy grid inside a lazy row only adds layout passes.
            VStack(spacing: 4) {
                ForEach(0..<rows, id: \.self) { r in
                    HStack(spacing: 4) {
                        ForEach(0..<cols, id: \.self) { c in
                            let i = r * cols + c
                            if i < m.count { cell(i).aspectRatio(1, contentMode: .fit) } else { Color.clear.aspectRatio(1, contentMode: .fit) }
                        }
                    }
                }
            }
        }
    }

    private func cell(_ i: Int) -> some View {
        let it = post.media[i]
        return Button {
            if it.kind == .photo { actions.openImages(post, i) } else { actions.playVideo(post, i) }
        } label: {
            ZStack {
                if it.spoiler { CoverBackdrop(url: it.thumb) }
                else { CoverView(url: it.thumb, corner: 0, maxPixelSize: post.media.count == 1 ? CoverPixels.hero : CoverPixels.poster) }
                if it.kind != .photo {
                    Image(systemName: it.video == nil ? "paperplane.fill" : "play.fill")
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 44, height: 44).background(.black.opacity(0.42), in: Circle())
                    if it.duration > 0 {
                        Text(Fmt.clock(it.duration)).font(.caption2.monospacedDigit().weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 2).background(.black.opacity(0.55), in: Capsule())
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(6)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressScale(scale: 0.98))
        .accessibilityLabel(it.kind == .photo ? "图片 \(i + 1)" : "视频 \(i + 1)")
        .accessibilityIdentifier("tg.media.\(post.id).\(i)")
    }
}
