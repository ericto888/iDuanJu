import SwiftUI

// Liquid Glass, in one place.
//
// iOS 26+: the system material (`glassEffect` / `GlassEffectContainer` / `.buttonStyle(.glass)`): real lensing,
// specular highlights, touch response and morphing. Nothing is painted underneath it.
// iOS 16–25: one material fallback with the same shapes and paddings, so layouts are identical on every system.
//
// Rules (Apple HIG, "Liquid Glass"):
//  · glass is for the control layer floating over content (bars, buttons, panels), never for list rows or cards;
//  · never stack glass on glass: put neighbours in one `LiquidGlassGroup` instead, and mark sheets / panels with
//    `onGlassSurface()` so the controls inside draw plain fills;
//  · tint only for the primary action / the selected state.

enum LiquidGlassTone: Equatable {
    case regular
    /// More transparent: controls floating over video or artwork.
    case clear
    /// Panels with text over moving video: a touch denser so content stays readable.
    case panel
    case tinted(Color)
}

extension View {
    /// Liquid Glass behind this view, clipped to `shape`.
    /// `interactive`: the material reacts to touch (buttons, chips, sliders).
    /// `onMedia`: this floats over video / artwork, so the fallback stays dark in both colour schemes.
    @ViewBuilder
    func liquidGlass<S: Shape>(_ shape: S, tone: LiquidGlassTone = .regular, interactive: Bool = false, onMedia: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(LiquidGlassTone.system(tone, interactive: interactive, onMedia: onMedia), in: shape)
        } else {
            self.modifier(LiquidGlassFallback(shape: shape, tone: tone, onMedia: onMedia))
        }
        #else
        self.modifier(LiquidGlassFallback(shape: shape, tone: tone, onMedia: onMedia))
        #endif
    }

    func liquidGlass(corner: CGFloat, tone: LiquidGlassTone = .regular, interactive: Bool = false, onMedia: Bool = false) -> some View {
        liquidGlass(RoundedRectangle(cornerRadius: corner, style: .continuous), tone: tone, interactive: interactive, onMedia: onMedia)
    }

    func liquidGlassCapsule(tone: LiquidGlassTone = .regular, interactive: Bool = false, onMedia: Bool = false) -> some View {
        liquidGlass(Capsule(style: .continuous), tone: tone, interactive: interactive, onMedia: onMedia)
    }

    /// Identity for glass that morphs between states inside a `LiquidGlassGroup`.
    @ViewBuilder
    func liquidGlassID<ID: Hashable & Sendable>(_ id: ID, in ns: Namespace.ID) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { self.glassEffectID(id, in: ns) } else { self.matchedGeometryEffect(id: id, in: ns) }
        #else
        self.matchedGeometryEffect(id: id, in: ns)
        #endif
    }

    /// Merge this glass shape with its siblings carrying the same id into a single surface.
    @ViewBuilder
    func liquidGlassUnion<ID: Hashable & Sendable>(_ id: ID, in ns: Namespace.ID) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { self.glassEffectUnion(id: id, namespace: ns) } else { self }
        #else
        self
        #endif
    }

    /// Sheet chrome: on iOS 26 partial-height sheets are Liquid Glass as long as nothing paints their background;
    /// earlier systems get the app's sheet colour.
    @ViewBuilder
    func liquidSheetBackground() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { self } else { self.compatPresentationBackground(STVTheme.sheet) }
        #else
        self.compatPresentationBackground(STVTheme.sheet)
        #endif
    }

    /// Soft system edge effect where scrolling content passes under floating glass.
    @ViewBuilder
    func liquidScrollEdge() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { self.scrollEdgeEffectStyle(.soft, for: .all) } else { self }
        #else
        self
        #endif
    }

    /// Artwork behind floating bars: iOS 26 mirrors and blurs it into the safe areas around it.
    @ViewBuilder
    func liquidBackgroundExtension() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { self.backgroundExtensionEffect() } else { self }
        #else
        self
        #endif
    }

    /// How glass inside a `LiquidGlassGroup` appears / disappears when it has no partner to morph into.
    @ViewBuilder
    func liquidGlassMaterialize() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { self.glassEffectTransition(.materialize) } else { self.transition(.opacity.combined(with: .scale(scale: 0.92))) }
        #else
        self.transition(.opacity.combined(with: .scale(scale: 0.92)))
        #endif
    }

    /// Marks this subtree as sitting on a glass surface (sheet, dialog, floating panel): controls inside draw plain
    /// fills instead of their own glass, so glass never stacks on glass.
    func onGlassSurface(_ on: Bool = true) -> some View { environment(\.onGlass, on) }

    /// Floating header of a scrolling page. iOS 26: a system bar, so content dissolves under it with the soft scroll
    /// edge effect; earlier: the same layout over `LiquidEdgeFade`.
    @ViewBuilder
    func liquidTopBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.safeAreaBar(edge: .top, spacing: 0, content: bar).scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self.safeAreaInset(edge: .top, spacing: 0) { bar().background { LiquidEdgeFade() } }
        }
        #else
        self.safeAreaInset(edge: .top, spacing: 0) { bar().background { LiquidEdgeFade() } }
        #endif
    }

    /// Floating footer (action bar) of a scrolling page.
    @ViewBuilder
    func liquidBottomBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.safeAreaBar(edge: .bottom, spacing: 0, content: bar).scrollEdgeEffectStyle(.soft, for: .bottom)
        } else {
            self.safeAreaInset(edge: .bottom, spacing: 0) { bar().background { LiquidEdgeFade(edge: .bottom) } }
        }
        #else
        self.safeAreaInset(edge: .bottom, spacing: 0) { bar().background { LiquidEdgeFade(edge: .bottom) } }
        #endif
    }
}

private struct OnGlassKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// True inside a glass surface: see `onGlassSurface()`.
    var onGlass: Bool {
        get { self[OnGlassKey.self] }
        set { self[OnGlassKey.self] = newValue }
    }
}

#if compiler(>=6.2)
extension LiquidGlassTone {
    @available(iOS 26.0, *)
    static func system(_ tone: LiquidGlassTone, interactive: Bool, onMedia: Bool) -> Glass {
        let base: Glass
        switch tone {
        case .regular: base = .regular
        // Clear glass does not adapt: over a bright picture its white icons need the dimming the HIG asks for.
        case .clear: base = onMedia ? .clear.tint(Color.black.opacity(0.34)) : .clear
        case .panel: base = .regular.tint(Color.black.opacity(0.28))
        case .tinted(let c): base = .regular.tint(c)
        }
        return interactive ? base.interactive() : base
    }
}
#endif

/// Pre-iOS 26 look. One material, one tint, one rim: shared by every surface so nothing is hand-rolled per screen.
private struct LiquidGlassFallback<S: Shape>: ViewModifier {
    let shape: S
    let tone: LiquidGlassTone
    let onMedia: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var dark: Bool { onMedia || scheme == .dark }

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    if reduceTransparency {
                        shape.fill(dark ? Color(white: 0.13) : Color(white: 0.97))
                    } else {
                        shape.fill(tone == .panel ? Material.regularMaterial : Material.ultraThinMaterial).environment(\.colorScheme, dark ? .dark : .light)
                        shape.fill(wash)
                    }
                }
            }
            .overlay {
                shape.stroke(
                    LinearGradient(colors: [.white.opacity(dark ? 0.30 : 0.75), .white.opacity(dark ? 0.06 : 0.22), .white.opacity(dark ? 0.14 : 0.45)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 0.7)
                .allowsHitTesting(false)
            }
            .clipShape(shape)
    }

    private var wash: Color {
        switch tone {
        // Light: dense enough that grey labels stay readable over covers (the tab bar), as on Android.
        case .regular: return dark ? Color.white.opacity(0.06) : Color.white.opacity(0.52)
        case .panel: return dark ? Color.black.opacity(0.36) : Color.white.opacity(0.45)
        case .clear: return onMedia ? Color.black.opacity(0.26) : (dark ? Color.black.opacity(0.10) : Color.white.opacity(0.12))
        case .tinted(let c): return c.opacity(0.85)
        }
    }
}

/// Page colour + blur dissolving away from a screen edge: what floating headers sit on where the system scroll edge
/// effect is not available (iOS 16–25, and headers shared by several scroll views). `visible` fades it in on scroll.
struct LiquidEdgeFade: View {
    var edge: VerticalEdge = .top
    var visible = true
    /// How far the fade reaches past the bar.
    var overhang: CGFloat = 22
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Dense under the whole bar (labels sit on it), gone within the overhang.
    private func ramp(_ a: Double, _ b: Double) -> LinearGradient {
        LinearGradient(stops: [.init(color: STVTheme.bg.opacity(a), location: 0), .init(color: STVTheme.bg.opacity(b), location: 0.74),
                               .init(color: STVTheme.bg.opacity(b * 0.6), location: 0.87), .init(color: STVTheme.bg.opacity(0), location: 1)],
                       startPoint: edge == .top ? .top : .bottom, endPoint: edge == .top ? .bottom : .top)
    }

    var body: some View {
        Group {
            if reduceTransparency {
                STVTheme.bg
            } else {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial).mask(ramp(1, 0.96))
                    ramp(0.88, 0.74)
                }
                .padding(edge == .top ? .bottom : .top, -overhang)
            }
        }
        .ignoresSafeArea(edges: edge == .top ? .top : .bottom)
        .opacity(visible ? 1 : 0)
        .animation(.easeOut(duration: 0.22), value: visible)
        .allowsHitTesting(false)
    }
}

/// Groups neighbouring glass so the system renders (and morphs) it as one layer. Also the cheap way to draw
/// several glass controls: one container samples the backdrop once.
struct LiquidGlassGroup<Content: View>: View {
    var spacing: CGFloat? = nil
    @ViewBuilder var content: Content
    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// Text / icon button on Liquid Glass. `prominent` = the one primary action of a screen.
struct LiquidGlassButtonStyle: ButtonStyle {
    var prominent = false
    var tint: Color = STVTheme.accent
    var onMedia = false
    var corner: CGFloat? = nil
    func makeBody(configuration: Configuration) -> some View {
        Body_(configuration: configuration, prominent: prominent, tint: tint, onMedia: onMedia, corner: corner)
    }

    private struct Body_: View {
        let configuration: Configuration
        let prominent: Bool
        let tint: Color
        let onMedia: Bool
        let corner: CGFloat?
        @Environment(\.isEnabled) private var enabled
        @Environment(\.onGlass) private var onGlass
        var body: some View {
            let tone: LiquidGlassTone = prominent ? .tinted(tint) : .regular
            let label = configuration.label
                .foregroundStyle(prominent ? STVTheme.onAccent : (onMedia ? Color.white : STVTheme.text))
                .contentShape(Rectangle())
            Group {
                if onGlass {
                    // Already on a glass surface: a plain fill, never a second layer of glass.
                    label.background(prominent ? tint : STVTheme.glass, in: RoundedRectangle(cornerRadius: corner ?? 100, style: .continuous))
                } else if let corner {
                    label.liquidGlass(corner: corner, tone: tone, interactive: true, onMedia: onMedia)
                } else {
                    label.liquidGlassCapsule(tone: tone, interactive: true, onMedia: onMedia)
                }
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(enabled ? 1 : 0.4)
            .animation(DS.press, value: configuration.isPressed)
        }
    }
}

/// Ground of round icon buttons: glass when floating, a plain fill on a glass surface.
struct LiquidCircleGround: ViewModifier {
    var onGlass: Bool
    var onMedia = false
    var tone: LiquidGlassTone? = nil
    func body(content: Content) -> some View {
        if onGlass {
            content.background(Circle().fill(STVTheme.glass))
        } else {
            content.liquidGlass(Circle(), tone: tone ?? (onMedia ? .clear : .regular), interactive: true, onMedia: onMedia)
        }
    }
}

/// Round glass icon button (36 / 40 / 44 pt) for bars and floating controls; 44 pt hit area.
struct LiquidGlassIconButton: View {
    let systemName: String
    var label: String
    var size: CGFloat = 40
    var tint: Color? = nil
    var selected = false
    var onMedia = false
    let action: () -> Void
    @Environment(\.onGlass) private var onGlass

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(tint ?? (selected ? STVTheme.accent : (onMedia ? Color.white : STVTheme.text)))
                .frame(width: size, height: size)
                .modifier(LiquidCircleGround(onGlass: onGlass, onMedia: onMedia))
                .frame(width: max(44, size), height: max(44, size))
                .contentShape(Circle())
        }
        .buttonStyle(GlassPress())
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
