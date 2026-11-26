import SwiftUI
import UIKit

// MARK: - iOS 16 Compatibility Modifiers & Views

extension Animation {
    /// Drop-in replacement for iOS 17's `.snappy`.
    static let compatSnappy: Animation = .spring(response: 0.3, dampingFraction: 0.85)
}

private struct CompatRectKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

private struct CompatSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

struct TabBarScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Scroll geometry used by the home chrome state machine. Optional dimensions are nil on
/// pre-iOS 18 fallback paths, where only the active drag gate is available.
struct CompatScrollMetrics: Equatable {
    let offsetY: CGFloat
    let contentHeight: CGFloat?
    let containerHeight: CGFloat?
    let containerWidth: CGFloat?
    let isWithinScrollRange: Bool?
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
            self.background(
                GeometryReader { geo in
                    Color.clear.preference(key: CompatRectKey.self, value: geo.frame(in: space))
                }
            )
            .onPreferenceChange(CompatRectKey.self, perform: action)
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
                    Color.clear.preference(key: CompatSizeKey.self, value: geo.size)
                }
            )
            .onPreferenceChange(CompatSizeKey.self, perform: action)
        }
    }

    /// iOS 16+ replacement for `.onScrollGeometryChange(for: Bool.self)` threshold detection.
    /// On iOS 18+, uses native `onScrollGeometryChange`; on iOS 16-17, attach `CompatScrollProbe` at the top of the ScrollView content.
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

    /// Put on the content inside a ScrollView that uses compatOnScrolled (iOS 16–17 fallback).
    @ViewBuilder
    func compatScrollContent() -> some View {
        if #available(iOS 18.0, *) {
            self
        } else {
            self.background(alignment: .top) {
                GeometryReader { geo in
                    Color.clear.preference(key: CompatScrollKey.self, value: geo.frame(in: .named(CompatScrolled.space)).minY)
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

    /// Reports native scroll geometry on iOS 18+, including content and viewport dimensions.
    /// Those dimensions let callers ignore offset jumps caused by asynchronous content/layout changes.
    @ViewBuilder
    func compatOnScrollMetrics(action: @escaping (CompatScrollMetrics) -> Void) -> some View {
        if #available(iOS 18.0, *) {
            self.onScrollGeometryChange(for: CompatScrollMetrics.self) { geometry in
                let minimumOffset = -geometry.contentInsets.top
                let maximumOffset = max(
                    minimumOffset,
                    geometry.contentSize.height - geometry.containerSize.height + geometry.contentInsets.bottom
                )
                let withinRange = geometry.contentOffset.y >= minimumOffset - 0.5
                    && geometry.contentOffset.y <= maximumOffset + 0.5
                return CompatScrollMetrics(
                    offsetY: geometry.contentOffset.y + geometry.contentInsets.top,
                    contentHeight: geometry.contentSize.height,
                    containerHeight: geometry.containerSize.height,
                    containerWidth: geometry.containerSize.width,
                    isWithinScrollRange: withinRange
                )
            } action: { _, metrics in
                action(metrics)
            }
        } else {
            self
        }
    }

    /// Reports genuine vertical interaction. iOS 18 uses ScrollPhase; older systems use a
    /// simultaneous drag observer so programmatic scrolling and momentum cannot drive chrome.
    @ViewBuilder
    func compatOnScrollInteraction(action: @escaping (Bool) -> Void) -> some View {
        if #available(iOS 18.0, *) {
            self.onScrollPhaseChange { _, phase in
                action(phase == .interacting)
            }
        } else {
            self.simultaneousGesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if abs(value.translation.height) > abs(value.translation.width) {
                            action(true)
                        }
                    }
                    .onEnded { _ in action(false) }
            )
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

/// iOS 16+ drop-in replacement for `ContentUnavailableView`.
struct CompatEmptyStateView: View {
    let title: String
    let systemImage: String
    var description: String? = nil

    var body: some View {
        if #available(iOS 17.0, *) {
            if let description {
                ContentUnavailableView(title, systemImage: systemImage, description: Text(description))
            } else {
                ContentUnavailableView(title, systemImage: systemImage)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(STVTheme.secondary)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(STVTheme.text)
                if let description {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(STVTheme.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        }
    }
}

private struct CompatScrollKey: PreferenceKey {
    static var defaultValue: CGFloat? { nil }
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) { value = value ?? nextValue() }
}

/// iOS 16–17 scroll threshold probe. The first content position is treated as rest so safe-area insets do not count as scrolling.
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
                let value = rest - y > threshold
                if value != last { last = value; action(value) }
            }
    }
}
