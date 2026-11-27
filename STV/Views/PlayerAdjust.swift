import SwiftUI
import UIKit
import MediaPlayer
import AVFoundation

/// Brightness (left) / volume (right) vertical-swipe adjustment for the player.
/// Zones: outer 1/5 strips in both orientations (the middle keeps episode paging),
/// always excluding the edge-back strip. Brightness is restored when the player goes away.
enum AdjustSide { case brightness, volume }

@MainActor
final class PlayerAdjuster: ObservableObject {
    @Published var hud: (side: AdjustSide, value: Double)?
    private var originalBrightness: CGFloat?
    private var startValue: Double = 0
    private var lastAppliedVolume: Double = -1
    private var hideTask: Task<Void, Never>?
    /// Hidden MPVolumeView & its internal UISlider — the sanctioned iOS way to adjust system hardware volume.
    weak var volumeView: MPVolumeView?
    weak var volumeSlider: UISlider?

    /// Outer 28% strips in portrait (preserving middle 44% for episode swiping), full halves in landscape.
    static func zone(x: CGFloat, width: CGFloat, landscape: Bool, edge: CGFloat) -> AdjustSide? {
        guard width > 0, x >= edge, x <= width - 8 else { return nil }
        if landscape {
            if x < width * 0.45 { return .brightness }
            if x > width * 0.55 { return .volume }
            return nil
        }
        if x < width * 0.28 { return .brightness }
        if x > width * 0.72 { return .volume }
        return nil
    }

    nonisolated static func findSlider(in root: UIView) -> UISlider? {
        if let s = root as? UISlider { return s }
        for sub in root.subviews {
            if let found = findSlider(in: sub) { return found }
        }
        return nil
    }

    private func resolveSlider() -> UISlider? {
        if let s = volumeSlider { return s }
        if let v = volumeView {
            v.layoutIfNeeded()
            if let s = Self.findSlider(in: v) {
                volumeSlider = s
                return s
            }
        }
        return nil
    }

    func begin(_ side: AdjustSide) {
        hideTask?.cancel()
        switch side {
        case .brightness:
            if originalBrightness == nil { originalBrightness = UIScreen.main.brightness }
            startValue = Double(UIScreen.main.brightness)
        case .volume:
            let session = AVAudioSession.sharedInstance()
            try? session.setActive(true)
            let sysVol = Double(session.outputVolume)
            let slider = resolveSlider()
            if sysVol >= 0, sysVol <= 1 {
                startValue = sysVol
                slider?.setValue(Float(sysVol), animated: false)
            } else {
                startValue = Double(slider?.value ?? 0.5)
            }
            lastAppliedVolume = startValue
        }
        hud = (side, startValue)
    }

    /// `fraction` = total vertical travel / usable height (up = positive).
    func change(_ side: AdjustSide, fraction: Double) {
        let v = min(1, max(0, startValue + fraction))
        switch side {
        case .brightness:
            UIScreen.main.brightness = CGFloat(v)
        case .volume:
            if abs(v - lastAppliedVolume) >= 0.008 || v == 0 || v == 1 {
                lastAppliedVolume = v
                applySystemVolume(Float(v))
            }
        }
        hud = (side, v)
    }

    func end() {
        if let current = hud, current.side == .volume {
            applySystemVolume(Float(current.value))
        }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.2)) { hud = nil }
        }
    }

    private func applySystemVolume(_ v: Float) {
        guard let slider = resolveSlider() else { return }
        slider.setValue(v, animated: false)
        slider.sendActions(for: .valueChanged)
        slider.sendActions(for: .touchUpInside)
    }

    func restoreBrightness() {
        if let b = originalBrightness { UIScreen.main.brightness = b }
        originalBrightness = nil
    }
}

/// Off-screen full-size MPVolumeView container: iOS 16–26 requires a real non-trivial frame attached to a window
/// before `MPVolumeSlider` binds to `AVSystemController` (1×1 or hidden frames silently ignore volume writes).
struct HiddenVolumeView: UIViewRepresentable {
    let adjuster: PlayerAdjuster

    func makeUIView(context: Context) -> VolumeBridgeContainer {
        let container = VolumeBridgeContainer(adjuster: adjuster)
        return container
    }

    func updateUIView(_ uiView: VolumeBridgeContainer, context: Context) {
        uiView.bindSliderIfNeeded()
    }

    final class VolumeBridgeContainer: UIView {
        private let volumeView = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 160, height: 36))
        private weak var adjuster: PlayerAdjuster?

        init(adjuster: PlayerAdjuster) {
            self.adjuster = adjuster
            super.init(frame: CGRect(x: 0, y: 0, width: 160, height: 36))
            isUserInteractionEnabled = false
            alpha = 0.01
            volumeView.showsVolumeSlider = true
            volumeView.isUserInteractionEnabled = false
            addSubview(volumeView)
            adjuster.volumeView = volumeView
            bindSliderIfNeeded()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.bindSliderIfNeeded() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            volumeView.frame = bounds.isEmpty ? CGRect(x: 0, y: 0, width: 160, height: 36) : bounds
            bindSliderIfNeeded()
        }

        func bindSliderIfNeeded() {
            guard let adjuster else { return }
            adjuster.volumeView = volumeView
            if let slider = PlayerAdjuster.findSlider(in: volumeView) {
                adjuster.volumeSlider = slider
            }
        }
    }
}

/// Compact precision HUD pinned near the top edge: icon + film-signal bar + percentage.
struct PlayerAdjustHUD: View {
    let side: AdjustSide
    let value: Double
    private var icon: String {
        switch side {
        case .brightness: value < 0.34 ? "sun.min.fill" : "sun.max.fill"
        case .volume: value <= 0.001 ? "speaker.slash.fill" : value < 0.34 ? "speaker.wave.1.fill" : value < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        }
    }
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(PlayerPalette.signal)
                .frame(width: 18)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22))
                Capsule().fill(PlayerPalette.signal).frame(width: max(4, 112 * value))
            }
            .frame(width: 112, height: 4)
            Text("\(Int((value * 100).rounded()))%")
                .font(.system(size: 12, weight: .semibold, design: .monospaced).monospacedDigit())
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: 34, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(PlayerPalette.hudSurface, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(side == .brightness ? "亮度 \(Int(value * 100))%" : "音量 \(Int(value * 100))%")
    }
}
