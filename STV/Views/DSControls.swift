import SwiftUI
import UIKit

// Form controls and settings lists of the design system. They replace the stock Toggle / Slider / TextField / Picker /
// Form looks, and keep the system accessibility semantics (VoiceOver and UI tests still see switches, sliders, fields).

// MARK: - Switch

/// Toggle style of the app: `Toggle("…", isOn: …).toggleStyle(DSSwitch())`. The whole row is the hit area.
struct DSSwitch: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            DS.tick()
            withAnimation(DS.select) { configuration.isOn.toggle() }
        } label: {
            HStack(spacing: 12) {
                configuration.label.frame(maxWidth: .infinity, alignment: .leading)
                DSSwitchGlyph(isOn: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(DSSwitchPress())
        // VoiceOver / UI tests get a real switch; the explicit style keeps this representation from styling itself.
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(SwitchToggleStyle()) }
    }
}

/// Switch without a label, for rows that lay out their own text.
struct DSSwitchControl: View {
    @Binding var isOn: Bool
    let label: String
    var body: some View {
        Button {
            DS.tick()
            withAnimation(DS.select) { isOn.toggle() }
        } label: { DSSwitchGlyph(isOn: isOn).contentShape(Capsule().inset(by: -8)) }
            .buttonStyle(DSSwitchPress())
            .accessibilityRepresentation { Toggle(label, isOn: $isOn).toggleStyle(SwitchToggleStyle()) }
    }
}

private struct SwitchPressedKey: EnvironmentKey { static let defaultValue = false }
private extension EnvironmentValues {
    var switchPressed: Bool {
        get { self[SwitchPressedKey.self] }
        set { self[SwitchPressedKey.self] = newValue }
    }
}

private struct DSSwitchPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.environment(\.switchPressed, configuration.isPressed)
            .animation(DS.press, value: configuration.isPressed)
    }
}

private struct DSSwitchGlyph: View {
    let isOn: Bool
    @Environment(\.switchPressed) private var pressed
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate
    var body: some View {
        Capsule()
            .fill(isOn ? STVTheme.accent : STVTheme.glassBorder)
            .overlay { Capsule().strokeBorder(isOn ? .clear : STVTheme.hairline, lineWidth: 1) }
            .frame(width: 54, height: 30)
            .overlay(alignment: .leading) {
                if differentiate && isOn { Capsule().fill(.white.opacity(0.9)).frame(width: 2, height: 10).padding(.leading, 11) }
            }
            .overlay(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(Color.white.shadow(.drop(color: .black.opacity(0.18), radius: 2.5, y: 1)))
                    .frame(width: pressed ? 34 : 30, height: 24)
                    .padding(3)
            }
            .opacity(enabled ? 1 : 0.4)
    }
}

// MARK: - Slider

/// Capsule slider: touch anywhere on the track, the thumb turns to clear glass while it is dragged.
struct DSSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var step: Double? = nil
    var tint: Color = STVTheme.accent
    var track: Color = STVTheme.glassBorder
    /// Spoken value; percentages by default.
    var valueLabel: ((Double) -> String)? = nil
    var onEditing: (Bool) -> Void = { _ in }
    @State private var dragging = false
    @Environment(\.isEnabled) private var enabled

    private var span: Double { max(range.upperBound - range.lowerBound, .ulpOfOne) }
    private var fraction: Double { min(max((value - range.lowerBound) / span, 0), 1) }

    var body: some View {
        GeometryReader { g in
            let thumb: CGFloat = 30, room = max(g.size.width - thumb, 1), x = room * fraction
            ZStack(alignment: .leading) {
                Capsule().fill(track).frame(height: 6)
                Capsule().fill(tint).frame(width: x + thumb / 2, height: 6)
                thumbView
                    .frame(width: thumb, height: 22)
                    .scaleEffect(dragging ? 1.28 : 1)
                    .offset(x: x)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if !dragging { withAnimation(DS.press) { dragging = true }; onEditing(true) }
                    apply(range.lowerBound + span * min(max((v.location.x - thumb / 2) / room, 0), 1))
                }
                .onEnded { _ in withAnimation(DS.press) { dragging = false }; onEditing(false) })
        }
        .frame(height: 36)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityElement()
        .accessibilityValue(valueLabel?(value) ?? "\(Int((fraction * 100).rounded()))%")
        .accessibilityAdjustableAction { d in
            let delta = step ?? span / 20
            onEditing(true); apply(min(max(value + (d == .increment ? delta : -delta), range.lowerBound), range.upperBound)); onEditing(false)
        }
    }

    @ViewBuilder private var thumbView: some View {
        if #available(iOS 26.0, *), dragging {
            Color.clear.liquidGlassCapsule(tone: .clear, interactive: true)
        } else {
            Capsule().fill(Color.white.shadow(.drop(color: .black.opacity(0.22), radius: 3, y: 1)))
        }
    }

    private func apply(_ raw: Double) {
        let v = step.map { (raw / $0).rounded() * $0 } ?? raw
        if v != value { value = min(max(v, range.lowerBound), range.upperBound) }
    }
}

// MARK: - Text field

/// Rounded field with optional icon, secure entry and a clear button. `id` is the text field's accessibility identifier.
struct DSTextField: View {
    let placeholder: String
    @Binding var text: String
    var icon: String? = nil
    var secure = false
    var mono = false
    var clearable = true
    var id: String? = nil
    @FocusState private var focused: Bool
    @State private var reveal = false

    init(_ placeholder: String, text: Binding<String>, icon: String? = nil, secure: Bool = false, mono: Bool = false, clearable: Bool = true, id: String? = nil) {
        self.placeholder = placeholder
        _text = text
        self.icon = icon
        self.secure = secure
        self.mono = mono
        self.clearable = clearable
        self.id = id
    }

    var body: some View {
        HStack(spacing: 10) {
            if let icon { Image(systemName: icon).font(.system(size: 15, weight: .medium)).foregroundStyle(STVTheme.tertiary).accessibilityHidden(true) }
            field
                .font(mono ? .system(.subheadline, design: .monospaced) : .body)
                .foregroundStyle(STVTheme.text).tint(STVTheme.accent)
                .focused($focused)
                .modifier(OptionalID(id: id))
            if secure {
                Button { reveal.toggle() } label: {
                    Image(systemName: reveal ? "eye.slash" : "eye").font(.system(size: 14, weight: .medium)).foregroundStyle(STVTheme.tertiary)
                        .frame(width: 30, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel(reveal ? "隐藏" : "显示")
            } else if clearable && focused && !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundStyle(STVTheme.tertiary)
                        .frame(width: 30, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("清除")
            }
        }
        .padding(.leading, 14).padding(.trailing, 8)
        .frame(minHeight: 46)
        .background(STVTheme.glass, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(focused ? STVTheme.accentLine : STVTheme.glassBorder, lineWidth: 1) }
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .animation(.easeOut(duration: 0.15), value: focused)
    }

    @ViewBuilder private var field: some View {
        let prompt = Text(placeholder).foregroundColor(STVTheme.tertiary)
        if secure && !reveal { SecureField(placeholder, text: $text, prompt: prompt) }
        else { TextField(placeholder, text: $text, prompt: prompt) }
    }

    private struct OptionalID: ViewModifier {
        let id: String?
        func body(content: Content) -> some View { if let id { content.accessibilityIdentifier(id) } else { content } }
    }
}

// MARK: - Settings list

/// Titled card of rows with hairline separators between them (replaces Form / List sections).
struct DSSection<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    var separatorInset: CGFloat = 16
    @ViewBuilder var content: Content

    init(_ title: String? = nil, footer: String? = nil, separatorInset: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.separatorInset = separatorInset
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).dsFont(13, .semibold, relativeTo: .footnote).foregroundStyle(STVTheme.secondary)
                    .padding(.horizontal, 20).accessibilityAddTraits(.isHeader)
            }
            _VariadicView.Tree(DSRowStack(inset: separatorInset)) { content }
                // Press highlights follow the card's corners.
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .dsCard(18)
                .padding(.horizontal, 16)
            if let footer {
                Text(footer).dsFont(12, relativeTo: .caption).foregroundStyle(STVTheme.tertiary).lineSpacing(3)
                    .padding(.horizontal, 20)
            }
        }
    }
}

private struct DSRowStack: _VariadicView_UnaryViewRoot {
    let inset: CGFloat
    @ViewBuilder func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        VStack(spacing: 0) {
            ForEach(children) { child in
                child
                if child.id != last { Hairline().padding(.leading, inset) }
            }
        }
    }
}

/// Icon + title + optional subtitle / value: the content of one settings row.
struct DSRowLabel: View {
    let title: String
    var icon: String? = nil
    var subtitle: String? = nil
    var value: String? = nil
    var tint: Color = STVTheme.text
    var iconTint: Color = STVTheme.accent
    var iconGround: Color = STVTheme.accentSoft
    var chevron = false
    var body: some View {
        HStack(spacing: 12) {
            if let icon { IconWell(systemName: icon, size: 32, corner: 10, tint: iconTint, ground: iconGround) }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).dsFont(16, .medium).foregroundStyle(tint).multilineTextAlignment(.leading)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).dsFont(12, relativeTo: .caption).foregroundStyle(STVTheme.secondary).multilineTextAlignment(.leading).lineSpacing(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let value, !value.isEmpty {
                Text(value).dsFont(14, relativeTo: .subheadline).foregroundStyle(STVTheme.secondary).lineLimit(1)
            }
            if chevron { Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(STVTheme.tertiary).accessibilityHidden(true) }
        }
    }
}

/// Paddings + minimum height of one row.
struct DSRowInset: ViewModifier {
    var vertical: CGFloat = 10
    func body(content: Content) -> some View {
        content.padding(.horizontal, 14).padding(.vertical, vertical).frame(minHeight: 52).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
}

extension View {
    /// Any custom content laid out as a settings row.
    func dsRow(vertical: CGFloat = 10) -> some View { modifier(DSRowInset(vertical: vertical)) }
}

/// Press highlight for rows inside a card.
struct DSRowPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? STVTheme.glass : .clear)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// One row: a plain label, an action, or a custom trailing accessory.
struct DSRow<Accessory: View>: View {
    let title: String
    var icon: String? = nil
    var subtitle: String? = nil
    var value: String? = nil
    var role: ButtonRole? = nil
    var chevron = false
    var action: (() -> Void)? = nil
    let accessory: Accessory
    @Environment(\.isEnabled) private var enabled

    init(title: String, icon: String? = nil, subtitle: String? = nil, value: String? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.icon = icon
        self.subtitle = subtitle
        self.value = value
        self.accessory = accessory()
    }

    private var destructive: Bool { role == .destructive }

    var body: some View {
        if let action {
            Button(role: role, action: action) { row }.buttonStyle(DSRowPress()).opacity(enabled ? 1 : 0.4)
        } else { row }
    }

    private var row: some View {
        HStack(spacing: 10) {
            DSRowLabel(title: title, icon: icon, subtitle: subtitle, value: value, tint: destructive ? DSTone.danger : STVTheme.text,
                       iconTint: destructive ? DSTone.danger : STVTheme.accent, iconGround: destructive ? DSTone.dangerSoft : STVTheme.accentSoft, chevron: chevron)
            accessory
        }
        .dsRow()
    }
}

extension DSRow where Accessory == EmptyView {
    init(_ title: String, icon: String? = nil, subtitle: String? = nil, value: String? = nil, role: ButtonRole? = nil, chevron: Bool = false, action: (() -> Void)? = nil) {
        self.init(title: title, icon: icon, subtitle: subtitle, value: value) { EmptyView() }
        self.role = role
        self.chevron = chevron
        self.action = action
    }
}

/// Row that pushes a route.
struct DSLinkRow<V: Hashable>: View {
    let title: String
    let route: V
    var icon: String? = nil
    var subtitle: String? = nil
    var value: String? = nil
    init(_ title: String, route: V, icon: String? = nil, subtitle: String? = nil, value: String? = nil) {
        self.title = title
        self.route = route
        self.icon = icon
        self.subtitle = subtitle
        self.value = value
    }
    var body: some View {
        NavigationLink(value: route) {
            DSRowLabel(title: title, icon: icon, subtitle: subtitle, value: value, chevron: true).dsRow()
        }
        .buttonStyle(DSRowPress())
    }
}

/// Row with a switch.
struct DSToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    var icon: String? = nil
    var subtitle: String? = nil
    init(_ title: String, isOn: Binding<Bool>, icon: String? = nil, subtitle: String? = nil) {
        self.title = title
        _isOn = isOn
        self.icon = icon
        self.subtitle = subtitle
    }
    var body: some View {
        Toggle(isOn: $isOn) { DSRowLabel(title: title, icon: icon, subtitle: subtitle) }
            .toggleStyle(DSSwitch())
            .dsRow()
    }
}

/// Semantic colours that are not brand colours.
enum DSTone {
    static let danger = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 1, green: 0.42, blue: 0.40, alpha: 1) : UIColor(red: 0.86, green: 0.20, blue: 0.18, alpha: 1) })
    static let dangerSoft = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 1, green: 0.42, blue: 0.40, alpha: 0.16) : UIColor(red: 0.86, green: 0.20, blue: 0.18, alpha: 0.10) })
}

// MARK: - Picker

/// One choice out of a few: segmented (2–4 short options), a capsule with a system menu (compact places), or a row that
/// opens an option sheet (long lists).
struct DSPicker<T: Hashable>: View {
    enum Style { case segmented, menu, row }
    let title: String
    let options: [T]
    @Binding var selection: T
    let label: (T) -> String
    var style: Style = .segmented
    var icon: String? = nil
    var subtitle: String? = nil
    @State private var open = false

    init(_ title: String, options: [T], selection: Binding<T>, style: Style = .segmented, icon: String? = nil, subtitle: String? = nil, label: @escaping (T) -> String) {
        self.title = title
        self.options = options
        _selection = selection
        self.style = style
        self.icon = icon
        self.subtitle = subtitle
        self.label = label
    }

    var body: some View {
        switch style {
        case .segmented:
            SegmentedTabs(items: options, selection: $selection, label: label, idPrefix: "picker.\(title)")
                .accessibilityElement(children: .contain).accessibilityLabel(title)
        case .menu:
            Menu {
                ForEach(options, id: \.self) { o in
                    Button { selection = o } label: {
                        if o == selection { Label(label(o), systemImage: "checkmark") } else { Text(label(o)) }
                    }
                }
            } label: { CapsuleLabel(title: label(selection), icon: icon, trailingIcon: "chevron.up.chevron.down") }
                .accessibilityLabel(title).accessibilityValue(label(selection))
        case .row:
            Button { open = true } label: {
                DSRowLabel(title: title, icon: icon, subtitle: subtitle, value: label(selection), chevron: true).dsRow()
            }
            .buttonStyle(DSRowPress())
            .dsOptions(isPresented: $open, title: title, options: options, selection: $selection, label: label)
        }
    }
}

// MARK: - Search field

/// Capsule search field with a trailing action. `floating`: in a header over scrolling content (glass capsule).
struct SearchField: View {
    @Binding var text: String
    var placeholder = "搜索短剧 / 演员"
    var floating = false
    var id: String? = nil
    var onSubmit: () -> Void
    var onCancel: (() -> Void)?
    @FocusState private var focused: Bool
    @Environment(\.onGlass) private var onGlass
    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .medium)).foregroundStyle(STVTheme.secondary).accessibilityHidden(true)
                TextField(placeholder, text: $text, prompt: Text(placeholder).foregroundColor(STVTheme.tertiary))
                    .focused($focused).submitLabel(.search).onSubmit(onSubmit)
                    .font(.system(size: 16)).foregroundStyle(STVTheme.text).tint(STVTheme.accent)
                    .accessibilityIdentifier(id ?? "search.input")
                if !text.isEmpty {
                    Button { text = ""; focused = true } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(STVTheme.tertiary)
                            .frame(width: 32, height: 32).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityLabel("清除")
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .padding(.leading, 14).padding(.trailing, 6).frame(height: 44)
            .modifier(SearchGround(glass: floating && !onGlass))
            .animation(DS.press, value: text.isEmpty)
            if let onCancel {
                Button(action: onCancel) { Text("取消").font(.system(size: 15, weight: .medium)).foregroundStyle(STVTheme.text).frame(minHeight: 44).contentShape(Rectangle()) }
                    .buttonStyle(PressScale())
            } else {
                Button(action: onSubmit) { Text("搜索").font(.system(size: 15, weight: .semibold)).foregroundStyle(STVTheme.accent).frame(minHeight: 44).contentShape(Rectangle()) }
                    .buttonStyle(PressScale())
            }
        }
    }

    private struct SearchGround: ViewModifier {
        let glass: Bool
        func body(content: Content) -> some View {
            if glass { content.liquidGlassCapsule(interactive: true) }
            else { content.background(STVTheme.glass, in: Capsule()).overlay { Capsule().strokeBorder(STVTheme.hairline, lineWidth: 1) } }
        }
    }
}

/// Multi-line editor in the same shape as `DSTextField`.
struct DSTextEditor: View {
    let placeholder: String
    @Binding var text: String
    var mono = false
    @FocusState private var focused: Bool
    var body: some View {
        TextEditor(text: $text)
            .scrollContentBackground(.hidden)
            .font(mono ? .system(.footnote, design: .monospaced) : .body)
            .foregroundStyle(STVTheme.text).tint(STVTheme.accent)
            .focused($focused)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .overlay(alignment: .topLeading) {
                if text.isEmpty { Text(placeholder).font(.footnote).foregroundStyle(STVTheme.tertiary).padding(.horizontal, 15).padding(.vertical, 16).allowsHitTesting(false) }
            }
            .background(STVTheme.glass, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(focused ? STVTheme.accentLine : STVTheme.glassBorder, lineWidth: 1) }
    }
}

/// 正序 / 倒序 switch used by chapter and episode lists.
struct DSOrderToggle: View {
    @Binding var ascending: Bool
    var id: String? = nil
    var body: some View {
        Button { DS.tick(); withAnimation(DS.select) { ascending.toggle() } } label: {
            HStack(spacing: 4) {
                Image(systemName: ascending ? "arrow.up" : "arrow.down").font(.system(size: 11, weight: .bold)).compatSymbolReplace()
                Text(ascending ? "正序" : "倒序").font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(STVTheme.secondary)
            .contentShape(Rectangle().inset(by: -10))
        }
        .buttonStyle(PressScale())
        .accessibilityLabel("排序").accessibilityValue(ascending ? "正序" : "倒序")
        .accessibilityIdentifier(id ?? "order.toggle")
    }
}
