import SwiftUI
import UIKit

// MARK: - iOS 16 Compatibility Modifiers & Views

extension Animation {
    /// Drop-in replacement for iOS 17's `.snappy`.
    static let compatSnappy: Animation = .spring(response: 0.3, dampingFraction: 0.85)
}

extension View {
    /// Cross-version `.onChange(of:)` supporting iOS 16+ without deprecation warnings or iOS 17-only closures.
    @ViewBuilder
    func compatOnChange<V: Equatable>(of value: V, perform action: @escaping (V) -> Void) -> some View {
        if #available(iOS 17.0, *) {
            self.onChange(of: value) { _, newValue in action(newValue) }
        } else {
            self.onChange(of: value, perform: action)
        }
    }

    @ViewBuilder
    func compatOnChange<V: Equatable>(of value: V, perform action: @escaping () -> Void) -> some View {
        if #available(iOS 17.0, *) {
            self.onChange(of: value) { _, _ in action() }
        } else {
            self.onChange(of: value) { _ in action() }
        }
    }

    /// iOS 16+ replacement for `.onGeometryChange(for: CGRect.self)` in a named coordinate space.
    @ViewBuilder
    func compatOnFrame(in space: CoordinateSpace, action: @escaping (CGRect) -> Void) -> some View {
        if #available(iOS 18.0, *) {
            self.onGeometryChange(for: CGRect.self) { $0.frame(in: space) } action: { action($0) }
        } else {
            // No PreferenceKey: nested users of one key overwrite each other's value.
            self.background(
                GeometryReader { geo in
                    let f = geo.frame(in: space)
                    Color.clear.onAppear { action(f) }.compatOnChange(of: f) { v in action(v) }
                }
            )
        }
    }

    /// iOS 16+ replacement for `.onGeometryChange(for: CGSize.self)`.
    @ViewBuilder
    func compatOnSize(action: @escaping (CGSize) -> Void) -> some View {
        if #available(iOS 18.0, *) {
            self.onGeometryChange(for: CGSize.self) { $0.size } action: { action($0) }
        } else {
            self.background(
                GeometryReader { geo in
                    Color.clear.onAppear { action(geo.size) }.compatOnChange(of: geo.size) { v in action(v) }
                }
            )
        }
    }

    /// iOS 16+ replacement for `.onScrollGeometryChange(for: Bool.self)` threshold detection.
    /// On iOS 18+, uses native `onScrollGeometryChange`; on iOS 16–17 the scroll view's content carries `compatScrollContent()`.
    @ViewBuilder
    func compatOnScrolled(threshold: CGFloat = 4, action: @escaping (Bool) -> Void) -> some View {
        if #available(iOS 18.0, *) {
            self.onScrollGeometryChange(for: Bool.self) {
                $0.contentOffset.y + $0.contentInsets.top > threshold
            } action: { _, v in action(v) }
        } else {
            self.modifier(CompatScrolled(threshold: threshold, action: action))
        }
    }

    /// Put on the content inside a ScrollView that uses `compatOnScrolled` (no-op on iOS 18+).
    @ViewBuilder
    func compatScrollContent() -> some View {
        if #available(iOS 18.0, *) {
            self
        } else {
            self.background(alignment: .top) {
                GeometryReader { g in
                    Color.clear.preference(key: CompatScrollKey.self, value: g.frame(in: .named(CompatScrolled.space)).minY)
                }
                .frame(height: 0)
            }
        }
    }

    /// iOS 16+ replacement for `.onScrollGeometryChange(for: CGFloat.self)` scroll Y reporting.
    @ViewBuilder
    func compatOnScrollY(action: @escaping (CGFloat) -> Void) -> some View {
        if #available(iOS 18.0, *) {
            self.onScrollGeometryChange(for: CGFloat.self) {
                $0.contentOffset.y + $0.contentInsets.top
            } action: { _, y in action(y) }
        } else {
            self
        }
    }

    /// iOS 16.4+ `.scrollBounceBehavior(.basedOnSize)` with iOS 16.0-16.3 fallback.
    @ViewBuilder
    func compatScrollBounceBasedOnSize(axes: Axis.Set = [.vertical]) -> some View {
        if #available(iOS 16.4, *) {
            self.scrollBounceBehavior(.basedOnSize, axes: axes)
        } else {
            self
        }
    }

    /// iOS 17+ `.defaultScrollAnchor` with iOS 16 fallback.
    @ViewBuilder
    func compatDefaultScrollAnchor(_ anchor: UnitPoint?) -> some View {
        if #available(iOS 17.0, *) {
            self.defaultScrollAnchor(anchor)
        } else {
            self
        }
    }

    /// iOS 17+ `.sensoryFeedback(.selection, trigger:)` with UIKit haptic fallback on iOS 16.
    @ViewBuilder
    func compatSelectionFeedback<T: Equatable>(trigger: T) -> some View {
        if #available(iOS 17.0, *) {
            self.sensoryFeedback(.selection, trigger: trigger)
        } else {
            self.onChange(of: trigger) { _ in
                UISelectionFeedbackGenerator().selectionChanged()
            }
        }
    }

    /// iOS 17+ `.contentTransition(.symbolEffect(.replace))` with iOS 16 fallback.
    @ViewBuilder
    func compatSymbolReplace() -> some View {
        if #available(iOS 17.0, *) {
            self.contentTransition(.symbolEffect(.replace))
        } else {
            self
        }
    }

    /// iOS 17+ `.symbolEffect(.variableColor.iterative, isActive:)` with iOS 16 fallback.
    @ViewBuilder
    func compatSymbolVariableColor(isActive: Bool) -> some View {
        if #available(iOS 17.0, *) {
            self.symbolEffect(.variableColor.iterative, isActive: isActive)
        } else {
            self.opacity(isActive ? 1.0 : 0.55)
        }
    }

    /// iOS 16.4+ `.presentationBackground` with iOS 16.0-16.3 fallback.
    @ViewBuilder
    func compatPresentationBackground<S: ShapeStyle>(_ style: S) -> some View {
        if #available(iOS 16.4, *) {
            self.presentationBackground(style)
        } else {
            self
        }
    }

    /// iOS 16.4+ `.presentationCornerRadius` with iOS 16.0-16.3 fallback.
    @ViewBuilder
    func compatPresentationCornerRadius(_ radius: CGFloat?) -> some View {
        if #available(iOS 16.4, *) {
            self.presentationCornerRadius(radius)
        } else {
            self
        }
    }
}

private struct CompatScrollKey: PreferenceKey {
    static var defaultValue: CGFloat? { nil }
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) { value = value ?? nextValue() }
}

/// iOS 16–17 scroll threshold: the first reported position is the resting one (content insets included).
private struct CompatScrolled: ViewModifier {
    static let space = "compat.scroll"
    let threshold: CGFloat
    let action: (Bool) -> Void
    @State private var rest: CGFloat?
    @State private var last = false
    func body(content: Content) -> some View {
        content
            .coordinateSpace(name: Self.space)
            .onPreferenceChange(CompatScrollKey.self) { y in
                guard let y else { return }
                guard let rest else { self.rest = y; return }
                let v = rest - y > threshold
                if v != last { last = v; action(v) }
            }
    }
}

/// iOS 16+ drop-in replacement for `UnevenRoundedRectangle`.
struct CompatUnevenRoundedRectangle: Shape {
    var topLeadingRadius: CGFloat = 0
    var bottomLeadingRadius: CGFloat = 0
    var bottomTrailingRadius: CGFloat = 0
    var topTrailingRadius: CGFloat = 0
    var style: RoundedCornerStyle = .continuous

    func path(in rect: CGRect) -> Path {
        let tl = min(topLeadingRadius, min(rect.width, rect.height) / 2)
        let tr = min(topTrailingRadius, min(rect.width, rect.height) / 2)
        let bl = min(bottomLeadingRadius, min(rect.width, rect.height) / 2)
        let br = min(bottomTrailingRadius, min(rect.width, rect.height) / 2)

        var p = Path()
        p.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr), radius: tr, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        p.addArc(center: CGPoint(x: rect.maxX - br, y: rect.maxY - br), radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        p.addArc(center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl), radius: bl, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        p.addArc(center: CGPoint(x: rect.minX + tl, y: rect.minY + tl), radius: tl, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}

/// Kept for older call sites: the app's own empty state on every system.
struct CompatEmptyStateView: View {
    let title: String
    let systemImage: String
    var description: String? = nil

    var body: some View { DSEmptyState(title, systemImage: systemImage, message: description) }
}
