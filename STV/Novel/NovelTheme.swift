import SwiftUI

/// The novel module uses the app palette and one set of navigation, surface and row rules (DesignKit).
enum NovelStyle {
    static let title = Font.system(size: 17, weight: .semibold)
    static let metadata = Font.system(size: 12)
}

struct NovelBookRow: View {
    let title: String
    let author: String
    let kind: String
    let cover: String?
    var latest = ""
    var subtitle = ""
    var rank: Int? = nil
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            WebCover(url: cover, title: title).frame(width: 58, height: 80)
            VStack(alignment: .leading, spacing: 7) {
                Text(rank.map { "\($0). \(title)" } ?? title).font(NovelStyle.title).foregroundStyle(STVTheme.text).lineLimit(2)
                Text([author, kind].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(NovelStyle.metadata).foregroundStyle(STVTheme.secondary).lineLimit(2)
                if !latest.isEmpty { Text(latest).font(.caption2).foregroundStyle(STVTheme.secondary).lineLimit(1) }
                if !subtitle.isEmpty { Text(subtitle).font(.caption2).foregroundStyle(STVTheme.accent).lineLimit(1) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
