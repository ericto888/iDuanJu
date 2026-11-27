import SwiftUI
import AVFoundation

/// Player controls and panels. White on glass; brand blue only for the current episode, the scrub delta and a non-1× rate.
/// Glass comes from `GlassKit` only: bars, buttons and the panel are glass, rows inside a panel are plain.

extension View {
    /// The one panel surface of the player.
    func playerPanel(_ corner: CGFloat = 28) -> some View {
        liquidGlass(corner: corner, tone: .panel, onMedia: true).environment(\.colorScheme, .dark)
    }
}

// MARK: Tech strip

/// One small muted line, not a collection of badges.
struct PlayerTechStrip: View {
    @ObservedObject var telemetry: PlaybackTelemetry
    var landscape = false
    var body: some View {
        if let tech = telemetry.tech {
            let parts = [tech.resolution, tech.hdr ? "HDR" : "SDR", tech.codec, tech.audio,
                         tech.fps > 0 ? "\(tech.fps) fps" : ""].filter { !$0.isEmpty }
            HStack(spacing: 6) {
                Text(parts.joined(separator: " · "))
                if !landscape && !tech.engine.isEmpty { Text(tech.engine).accessibilityIdentifier("player.engine").opacity(0.7) }
                if !landscape && tech.network > 0 { Text(PlayerTech.speed(tech.network)).monospacedDigit() }
            }
            .font(.system(size: 11, weight: .medium)).tracking(0.3).foregroundStyle(.white.opacity(0.55))
            .lineLimit(1).fixedSize().shadow(color: .black.opacity(0.4), radius: 2)
            .accessibilityElement(children: .combine).accessibilityIdentifier("player.tech")
        }
    }
}

/// iPad drawer footer: what is being decoded.
struct PlayerDecodeSummary: View {
    @ObservedObject var telemetry: PlaybackTelemetry
    let engine: PlayerEngineKind
    var body: some View {
        let t = telemetry.tech
        let parts = [t?.resolution, t?.hdr == true ? "HDR / DV" : nil, t?.codec, t?.audio].compactMap { $0 }.filter { !$0.isEmpty }
        VStack(alignment: .leading, spacing: 4) {
            Text("当前解码与音轨")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
            Text(parts.isEmpty ? "\(engine.short) 就绪" : (parts + [engine.short]).joined(separator: " · "))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(STVTheme.accent)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: Centre controls

/// ⟲10 · ▶ · ⟳10 as three glass buttons; the ring around ▶ doubles as buffer / loading progress. Live: ▶ only.
struct PlayerCenterControls: View {
    let co: PlaybackCoordinator
    let onInteract: () -> Void
    var spacing: CGFloat = 44

    var body: some View {
        let loading = co.readyIndex == nil || (co.waitingForMedia && !co.paused)
        LiquidGlassGroup(spacing: 12) {
            HStack(spacing: spacing) {
                if !co.isLive { skip(-10, "gobackward.10", "快退10秒", "player.back10") }
                Button { co.togglePause(); onInteract() } label: {
                    Image(systemName: co.paused ? "play.fill" : "pause.fill").font(.system(size: 27, weight: .regular))
                        .offset(x: co.paused ? 2 : 0)
                        .compatSymbolReplace()
                        .frame(width: 72, height: 72)
                        .overlay { PlayerBufferRing(clock: co.clock, loading: loading).padding(1) }
                        .liquidGlass(Circle(), tone: .clear, interactive: true, onMedia: true)
                        .contentShape(Circle())
                }
                .accessibilityLabel(co.paused ? "播放" : "暂停").accessibilityIdentifier("player.playPause")
                if !co.isLive { skip(10, "goforward.10", "快进10秒", "player.fwd10") }
            }
        }
        .buttonStyle(PressScale(scale: 0.92))
        .foregroundStyle(.white)
    }

    private func skip(_ s: Double, _ symbol: String, _ label: String, _ id: String) -> some View {
        Button { co.seek(by: s); onInteract() } label: {
            Image(systemName: symbol).font(.system(size: 24, weight: .regular))
                .frame(width: 52, height: 52)
                .liquidGlass(Circle(), tone: .clear, interactive: true, onMedia: true)
                .contentShape(Circle())
        }
        .accessibilityLabel(label).accessibilityIdentifier(id)
    }
}

private struct PlayerBufferRing: View {
    @ObservedObject var clock: PlaybackClock
    let loading: Bool
    @State private var spin = false
    var body: some View {
        let s = clock.sample
        let buffered = s.duration > 0 ? min(1, s.bufferedUntil / s.duration) : 0
        if loading {
            Circle().trim(from: 0, to: 0.28).stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(spin ? 360 : 0))
                .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spin)
                .onAppear { spin = true }.onDisappear { spin = false }
        } else {
            Circle().trim(from: 0, to: buffered).stroke(.white.opacity(0.75), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

/// Loading indicator shown while an episode is being opened.
struct PlayerLoading: View {
    var text = "正在载入"
    @State private var spin = false
    var body: some View {
        VStack(spacing: 10) {
            Circle().trim(from: 0, to: 0.28).stroke(.white, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                .frame(width: 34, height: 34)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spin)
            Text(text).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.8))
        }
        .shadow(color: .black.opacity(0.5), radius: 6)
        .onAppear { spin = true }
        .accessibilityElement(children: .combine)
    }
}

/// Error card over the video: what happened, 重试, and where else to go.
struct PlayerErrorCard: View {
    let message: String
    var canVerify = false
    var hasLines = false
    var onVerify: () -> Void = {}
    var onLines: () -> Void = {}
    let onRetry: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 26, weight: .light)).foregroundStyle(.white.opacity(0.85))
            Text(message).font(.system(size: 14)).foregroundStyle(.white.opacity(0.9)).multilineTextAlignment(.center)
            HStack(spacing: 10) {
                if canVerify { button("去验证", prominent: true, onVerify) }
                if hasLines { button("换线路", prominent: false, onLines) }
                button("重试", prominent: !canVerify, onRetry)
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 20)
        .frame(maxWidth: 320)
        .playerPanel(26)
        .padding(24)
    }

    private func button(_ title: String, prominent: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(prominent ? STVTheme.onAccent : .white)
                .padding(.horizontal, 18).frame(height: 38)
                .background(prominent ? STVTheme.accent : Color.white.opacity(0.14), in: Capsule())
                .contentShape(Capsule())
        }.buttonStyle(PressScale())
    }
}

// MARK: Caption

struct PlayerMetaRow<Trailing: View>: View {
    let source: String?
    let line: String
    let lineStrong: String
    let rest: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            if let source {
                Text(source).font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 7).frame(height: 20)
                    .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            (Text(line).foregroundColor(.white.opacity(0.72)) + Text(lineStrong).foregroundColor(.white).fontWeight(.semibold) + Text(rest).foregroundColor(.white.opacity(0.72)))
                .font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 8)
            trailing
        }
        .foregroundStyle(.white)
    }
}

/// Red dot + 直播, or 回看.
struct PlayerLiveBadge: View {
    var replay = false
    var body: some View {
        HStack(spacing: 5) {
            if replay { Image(systemName: "clock.arrow.circlepath").font(.system(size: 10, weight: .bold)) }
            else { Circle().fill(Color(red: 1, green: 0.36, blue: 0.36)).frame(width: 7, height: 7) }
            Text(replay ? "回看" : "直播").font(.system(size: 11, weight: .bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8).frame(height: 20)
        .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityIdentifier("player.live")
    }
}

// MARK: Actions

enum PlayerPanel: String, Identifiable {
    case episodes, quality, rates, audio, subtitles, danmaku, more, guide
    var id: Self { self }
}

/// One entry of the bottom action bar; portrait and landscape draw the same list.
struct PlayerAction: Identifiable {
    let id: String
    let a11y: String
    let symbol: String
    let title: String
    var value: String? = nil
    var active = false
    var accent = false
    var dimmed = false
    let action: () -> Void
}

/// Uncrowded Direction 1 portrait bottom dock: Play/Pause + Episodes capsule on left, 3 crisp tools on right.
struct PlayerPortraitDock: View {
    let paused: Bool
    let episodeBadge: String
    let episodesActive: Bool
    let rateLabel: String
    let rateAccented: Bool
    let rateActive: Bool
    let danmakuAvailable: Bool
    let danmakuEnabled: Bool
    var isLive: Bool = false
    var liveChannelsTitle: String = "频道"
    var liveGuideActive: Bool = false
    let onPlayPause: () -> Void
    let onEpisodes: () -> Void
    let onRateOrGuide: () -> Void
    let onDanmakuOrQuality: () -> Void
    var showFullscreen: Bool = true
    let onFullscreen: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onPlayPause) {
                Image(systemName: paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .offset(x: paused ? 1 : 0)
                    .foregroundStyle(PlayerPalette.ivory)
                    .frame(width: 38, height: 38)
                    .background(Color.white.opacity(0.12), in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
                    .contentShape(Circle())
            }
            .buttonStyle(PressScale())
            .accessibilityLabel(paused ? "播放" : "暂停")
            .accessibilityIdentifier("player.playPause")

            Button(action: onEpisodes) {
                HStack(spacing: 6) {
                    Image(systemName: isLive ? "list.bullet" : "square.grid.2x2")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(episodesActive ? PlayerPalette.signal : PlayerPalette.ivory)
                    Text(isLive ? liveChannelsTitle : episodeBadge)
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(episodesActive ? PlayerPalette.signal : PlayerPalette.ivory)
                        .lineLimit(1)
                }
                .padding(.horizontal, 13).frame(height: 38)
                .background(episodesActive ? PlayerPalette.signalSoft : Color.white.opacity(0.11), in: Capsule())
                .overlay(Capsule().strokeBorder(episodesActive ? PlayerPalette.signal.opacity(0.55) : .white.opacity(0.14), lineWidth: 0.5))
                .contentShape(Capsule())
            }
            .buttonStyle(PressScale())
            .accessibilityLabel(isLive ? "频道" : "选集")
            .accessibilityIdentifier("player.episodes")

            Spacer(minLength: 6)

            Button(action: onRateOrGuide) {
                HStack(spacing: 4) {
                    if isLive {
                        Image(systemName: "calendar")
                            .font(.system(size: 13, weight: .medium))
                        Text("节目单")
                            .font(.system(size: 12.5, weight: .semibold))
                    } else {
                        Text(rateLabel)
                            .font(.system(size: 12.5, weight: .bold, design: .monospaced).monospacedDigit())
                    }
                }
                .foregroundStyle((isLive ? liveGuideActive : (rateAccented || rateActive)) ? PlayerPalette.signal : PlayerPalette.ivory)
                .padding(.horizontal, 11).frame(height: 36)
                .background((isLive ? liveGuideActive : (rateAccented || rateActive)) ? PlayerPalette.signalSoft : Color.white.opacity(0.10), in: Capsule())
                .overlay(Capsule().strokeBorder((isLive ? liveGuideActive : (rateAccented || rateActive)) ? PlayerPalette.signal.opacity(0.5) : .white.opacity(0.12), lineWidth: 0.5))
                .contentShape(Capsule())
            }
            .buttonStyle(PressScale())
            .accessibilityLabel(isLive ? "节目单" : "播放倍速 \(rateLabel)")
            .accessibilityIdentifier(isLive ? "player.guide" : "player.rate")

            Button(action: onDanmakuOrQuality) {
                Image(systemName: isLive ? "antenna.radiowaves.left.and.right" : (danmakuEnabled && danmakuAvailable ? "captions.bubble.fill" : "captions.bubble"))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isLive ? PlayerPalette.ivory : (danmakuAvailable && danmakuEnabled ? PlayerPalette.signal : .white.opacity(danmakuAvailable ? 0.82 : 0.36)))
                    .frame(width: 36, height: 36)
                    .background((!isLive && danmakuAvailable && danmakuEnabled) ? PlayerPalette.signalSoft : Color.white.opacity(0.10), in: Circle())
                    .overlay(Circle().strokeBorder((!isLive && danmakuAvailable && danmakuEnabled) ? PlayerPalette.signal.opacity(0.5) : .white.opacity(0.12), lineWidth: 0.5))
                    .contentShape(Circle())
            }
            .buttonStyle(PressScale())
            .accessibilityLabel(isLive ? "线路" : (danmakuEnabled ? "关闭弹幕" : "开启弹幕"))
            .accessibilityIdentifier(isLive ? "player.quality" : "player.danmaku")

            if showFullscreen {
                Button(action: onFullscreen) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(PlayerPalette.ivory)
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.10), in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                        .contentShape(Circle())
                }
                .buttonStyle(PressScale())
                .accessibilityLabel("横屏全屏")
                .accessibilityIdentifier("player.fullscreen")
            }
        }
        .frame(height: 44)
    }
}

/// Landscape: labelled glass capsules.
struct PlayerActionChips: View {
    let actions: [PlayerAction]
    var body: some View {
        LiquidGlassGroup(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(actions) { PlayerChip(action: $0) }
            }
        }
    }
}

struct PlayerChip: View {
    let action: PlayerAction
    var body: some View {
        let on = action.active || action.accent
        Button(action: action.action) {
            HStack(spacing: 6) {
                Image(systemName: action.symbol).font(.system(size: 14, weight: .regular))
                    .foregroundStyle(on ? PlayerPalette.signal : PlayerPalette.ivory)
                (Text(action.title).foregroundColor(on ? PlayerPalette.signal : .white.opacity(0.86))
                 + Text(action.value.map { " " + $0 } ?? "").fontWeight(.semibold).foregroundColor(on ? PlayerPalette.signal : .white))
                    .font(.system(size: 13)).lineLimit(1).fixedSize()
            }
            .padding(.horizontal, 13).frame(height: 36)
            .liquidGlassCapsule(tone: .clear, interactive: true, onMedia: true)
            .opacity(action.dimmed ? 0.45 : 1)
            .contentShape(Capsule())
            .animation(DS.select, value: on)
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(action.a11y).accessibilityIdentifier(action.id)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: Panel pieces

struct PlayerPopoverRow: View {
    let title: String
    var detail: String = ""
    var subtitle: String? = nil
    let selected: Bool
    var id: String? = nil
    var rowHeight: CGFloat = 46
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 15, weight: selected ? .semibold : .regular)).lineLimit(1)
                    if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1) }
                }
                Spacer(minLength: 8)
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 12, weight: selected ? .semibold : .regular).monospacedDigit())
                        .foregroundStyle(selected ? STVTheme.accent.opacity(0.85) : .white.opacity(0.6)).lineLimit(1)
                }
                if selected { Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(STVTheme.accent) }
            }
            .foregroundStyle(selected ? STVTheme.accent : .white)
            .padding(.horizontal, 12).frame(minHeight: subtitle == nil ? rowHeight : 54)
            .background(selected ? Color.white.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale(scale: 0.98))
        .accessibilityIdentifier(id ?? "player.option")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct PlayerSectionTitle: View {
    let text: String
    /// The panel's own title (17 pt bold) rather than a group label (12 pt).
    var heading = false
    var trailing: String? = nil
    var body: some View {
        if heading {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(text).font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                Spacer(minLength: 8)
                if let trailing { Text(trailing).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)) }
            }
            .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 6)
        } else {
            Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.6)).padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 8)
        }
    }
}

/// Selectable capsule used inside panels (plain fill: the panel is the glass).
struct PlayerPanelChip: View {
    let title: String
    let selected: Bool
    var symbol: String? = nil
    var height: CGFloat = 32
    var id: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 12, weight: .semibold)) }
                Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular)).lineLimit(1)
            }
            .foregroundStyle(selected ? PlayerPalette.signal : .white.opacity(0.88))
            .padding(.horizontal, 13).frame(height: height)
            .background(selected ? PlayerPalette.signalSoft : Color.white.opacity(0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? PlayerPalette.signal.opacity(0.45) : .clear, lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScale())
        .accessibilityIdentifier(id ?? "player.chip")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct PlayerChipScroller: View {
    let titles: [String]
    let selected: Int?
    var height: CGFloat = 32
    let id: String
    let onTap: (Int) -> Void
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(titles.indices, id: \.self) { i in
                        PlayerPanelChip(title: titles[i], selected: i == selected, height: height, id: "\(id).\(i)") { onTap(i) }.id(i)
                    }
                }
            }
            .onAppear { if let selected { proxy.scrollTo(selected, anchor: .center) } }
        }
    }
}

/// Rewritten Precision Speed Control Panel: live readout + −/+ calibrated tick bar + one-tap preset capsules.
struct SpeedPopover: View {
    let current: Double
    var landscape = false
    /// Active core's ceiling.
    var maxRate: Double = 3
    let onPick: (Double) -> Void
    var onClose: () -> Void = {}

    static let portraitSteps: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3]
    private var allSteps: [Double] { PlaybackCoordinator.rateSteps.filter { $0 <= maxRate + 0.001 } }
    private var presets: [Double] { [0.75, 1.0, 1.25, 1.5, 2.0, 3.0].filter { $0 <= maxRate + 0.001 } }
    private var currentIndex: Int {
        allSteps.enumerated().min(by: { abs($0.element - current) < abs($1.element - current) })?.offset ?? 0
    }

    var body: some View {
        let isNormal = abs(current - 1.0) < 0.01
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                Text("倍速播放")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(PlayerPalette.ivory)
                Text(Self.shortLabel(current))
                    .font(.system(size: 18, weight: .bold, design: .monospaced).monospacedDigit())
                    .foregroundStyle(isNormal ? PlayerPalette.ivory : PlayerPalette.signal)
                Spacer(minLength: 4)
                if !isNormal {
                    Button {
                        DS.tick()
                        onPick(1.0)
                    } label: {
                        Text("恢复原速")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(PlayerPalette.signal)
                            .padding(.horizontal, 10).frame(height: 28)
                            .background(PlayerPalette.signalSoft, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(PressScale())
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.10), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(PressScale())
                .accessibilityLabel("关闭")
            }

            // Precision − / calibrated tick track / + stepper
            HStack(spacing: 10) {
                stepButton("minus", enabled: currentIndex > 0) {
                    let next = allSteps[max(0, currentIndex - 1)]
                    UISelectionFeedbackGenerator().selectionChanged()
                    onPick(next)
                }
                calibratedTrack
                stepButton("plus", enabled: currentIndex < allSteps.count - 1) {
                    let next = allSteps[min(allSteps.count - 1, currentIndex + 1)]
                    UISelectionFeedbackGenerator().selectionChanged()
                    onPick(next)
                }
            }

            // Quick preset capsules in one clean row
            HStack(spacing: 6) {
                ForEach(presets, id: \.self) { r in
                    let on = abs(r - current) < 0.01
                    Button {
                        UISelectionFeedbackGenerator().selectionChanged()
                        onPick(r)
                    } label: {
                        Text(Self.shortLabel(r))
                            .font(.system(size: 12.5, weight: on ? .bold : .medium, design: .monospaced).monospacedDigit())
                            .foregroundStyle(on ? .white : PlayerPalette.ivory.opacity(0.86))
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background(on ? PlayerPalette.signal : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(PressScale())
                    .accessibilityIdentifier("player.rate.\(r)")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }

            Text("长按画面任意处即刻 2× 速看，左右滑动微调 · 上滑锁定")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.48))
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    private func stepButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(enabled ? PlayerPalette.ivory : .white.opacity(0.28))
                .frame(width: 34, height: 34)
                .background(Color.white.opacity(0.10), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PressScale())
        .disabled(!enabled)
    }

    private var calibratedTrack: some View {
        let count = max(2, allSteps.count)
        let frac = CGFloat(currentIndex) / CGFloat(count - 1)
        return GeometryReader { g in
            let w = max(1, g.size.width)
            let innerW = max(1, w - 16)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.16))
                    .frame(height: 5)
                    .padding(.horizontal, 8)
                Capsule()
                    .fill(STVTheme.accent)
                    .frame(width: max(5, innerW * frac), height: 5)
                    .padding(.leading, 8)
                HStack(spacing: 0) {
                    ForEach(allSteps.indices, id: \.self) { i in
                        let isOne = abs(allSteps[i] - 1.0) < 0.01
                        Circle()
                            .fill(i <= currentIndex ? .white : .white.opacity(isOne ? 0.55 : 0.25))
                            .frame(width: isOne ? 5 : 3.5, height: isOne ? 5 : 3.5)
                        if i < count - 1 { Spacer(minLength: 0) }
                    }
                }
                .padding(.horizontal, 8)
                Circle()
                    .fill(.white)
                    .frame(width: 18, height: 18)
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
                    .offset(x: innerW * frac - 1)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let ratio = min(1, max(0, (v.location.x - 8) / innerW))
                        let idx = Int((ratio * CGFloat(count - 1)).rounded())
                        let next = allSteps[max(0, min(count - 1, idx))]
                        if abs(next - current) >= 0.01 {
                            UISelectionFeedbackGenerator().selectionChanged()
                            onPick(next)
                        }
                    }
            )
            .accessibilityLabel("拖动调节倍速")
        }
        .frame(height: 34)
    }

    static func shortLabel(_ r: Double) -> String {
        if abs(r - Double(Int(r))) < 0.01 { return "\(Int(r)).0×" }
        return String(format: "%g", r) + "×"
    }

    static func label(_ r: Double) -> String {
        let s = r == Double(Int(r)) ? "\(Int(r))×" : (String(format: "%g", r) + "×")
        return r == 1 ? s + " 正常速度" : s
    }
}

struct QualityPopover: View {
    let streams: [HGStream]
    let chosen: HGStream?
    let sources: [(title: String, detail: String, current: Bool, action: () -> Void)]
    var streamsTitle = "画质"
    var lines: [HGPlayLine] = []
    var lineIndex = 0
    var onLine: (Int) -> Void = { _ in }
    let onPick: (HGStream) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            PlayerSectionTitle(text: streams.isEmpty && !lines.isEmpty ? "线路" : streamsTitle, heading: true)
            ForEach(streams) { s in
                PlayerPopoverRow(title: s.quality ?? "自动", detail: Self.detail(s), selected: s == chosen, id: "player.stream") { onPick(s) }
            }
            if lines.count > 1 {
                if !streams.isEmpty { PlayerSectionTitle(text: "线路 · \(lines.count)") }
                ForEach(lines.indices, id: \.self) { i in
                    PlayerPopoverRow(title: lines[i].name, detail: "\(lines[i].episodes.count) 集", selected: i == lineIndex, id: "player.line") { onLine(i) }
                }
            }
            if !sources.isEmpty {
                PlayerSectionTitle(text: "播放源")
                ForEach(sources.indices, id: \.self) { i in
                    let s = sources[i]
                    PlayerPopoverRow(title: s.title, detail: s.detail, selected: s.current, id: "player.source") { s.action() }
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
    }

    static func detail(_ s: HGStream) -> String {
        var parts: [String] = []
        if let w = s.width, let h = s.height, w > 0, h > 0 { parts.append("\(w)×\(h)") }
        else if let c = s.codec, !c.isEmpty { parts.append(c.uppercased() == "H264" ? "H.264" : c) }
        if let b = s.bitrate, b > 0 { parts.append(String(format: "%.1fMbps", Double(b) / 1_000_000)) }
        return parts.joined(separator: " · ")
    }
}

struct TrackPopover: View {
    let title: String
    let options: [MediaTrack]
    let selected: Int?
    let allowsOff: Bool
    let emptyText: String
    /// Track id; nil = off.
    let onPick: (Int?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            PlayerSectionTitle(text: title, heading: true)
            if options.isEmpty {
                Text(emptyText).font(.system(size: 14)).foregroundStyle(.white.opacity(0.7)).padding(.horizontal, 12).frame(minHeight: 44)
            } else {
                if allowsOff { PlayerPopoverRow(title: "关闭", selected: selected == nil) { onPick(nil) } }
                ForEach(options) { o in
                    PlayerPopoverRow(title: o.title, selected: o.id == selected) { onPick(o.id) }
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
    }
}

/// 选集: season chips → line chips → range chips → grid (numbers for dramas, titles for multi-line titles, rows for long videos).
struct EpisodesPopover: View {
    enum Style { case numbers, titles, rows }
    let episodes: [HGEpisode]
    let current: Int
    let seasons: [(id: String, title: String)]
    let currentSeason: String?
    let style: Style
    var lines: [HGPlayLine] = []
    var lineIndex = 0
    var dateLine: String? = nil
    let onPick: (Int) -> Void
    var onSeason: (String) -> Void = { _ in }
    var onLine: (Int) -> Void = { _ in }
    @Environment(\.layoutMetrics) private var layout
    @State private var group = 0
    @State private var reversed = false

    var body: some View {
        let ranges = EpisodeGroups.ranges(total: episodes.count)
        VStack(alignment: .leading, spacing: 12) {
            if episodes.isEmpty {
                Text("分集还在加载").font(.system(size: 14)).foregroundStyle(.white.opacity(0.7)).frame(minHeight: 44)
            } else {
                if style != .rows { header }
                if seasons.count > 1 {
                    PlayerChipScroller(titles: seasons.map(\.title), selected: seasons.firstIndex { $0.id == currentSeason }, id: "player.season") { onSeason(seasons[$0].id) }
                }
                if lines.count > 1 {
                    PlayerChipScroller(titles: lines.map(\.name), selected: lineIndex, id: "player.linechip", onTap: onLine)
                }
                if style != .rows, ranges.count > 1 {
                    PlayerChipScroller(titles: ranges.map { EpisodeGroups.label($0, episodes: episodes) }, selected: group, height: 28, id: "player.epgroup") { i in
                        withAnimation(.compatSnappy) { group = i }
                    }
                }
                switch style {
                case .numbers: grid(ranges, columns: layout.episodeGridItems(spacing: 8)) { "\(episodes[$0].ep)" }
                case .titles: grid(ranges, columns: [GridItem(.adaptive(minimum: 92), spacing: 8)]) { episodes[$0].title.isEmpty ? "第\(episodes[$0].ep)集" : episodes[$0].title }
                case .rows: rows
                }
            }
        }
        .foregroundStyle(.white)
        .padding(style == .rows ? 10 : 16)
        .onAppear { if let i = ranges.firstIndex(where: { current >= $0.start && current <= $0.end }) { group = i } }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("选集").font(.system(size: 17, weight: .bold))
            Spacer()
            Text("共 \(episodes.count) 集").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
            Button { withAnimation(.compatSnappy) { reversed.toggle() } } label: {
                Label(reversed ? "倒序" : "正序", systemImage: "arrow.up.arrow.down")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.8)).contentShape(Rectangle())
            }
            .buttonStyle(PressScale()).accessibilityIdentifier("player.eporder")
        }
    }

    private func grid(_ ranges: [EpisodeRange], columns: [GridItem], label: @escaping (Int) -> String) -> some View {
        let r = ranges.indices.contains(group) ? ranges[group] : EpisodeRange(0, max(0, episodes.count - 1))
        let range = Array(r.start...max(r.start, min(r.end, episodes.count - 1)))
        return ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(reversed ? range.reversed() : range, id: \.self) { i in
                    let on = i == current
                    Button { onPick(i) } label: {
                        Text(label(i)).font(.system(size: style == .numbers ? 15 : 13, weight: .semibold).monospacedDigit())
                            .lineLimit(style == .numbers ? 1 : 2).multilineTextAlignment(.center).padding(.horizontal, 4)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(Color.white.opacity(on ? 0.20 : 0.08), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                            .overlay(alignment: .topTrailing) { if on { Circle().fill(STVTheme.accent).frame(width: 5, height: 5).padding(6) } }
                            .foregroundStyle(on ? STVTheme.accent : .white)
                    }
                    .buttonStyle(PressScale())
                    .accessibilityIdentifier("player.ep.\(episodes[i].ep)")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private var rows: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(episodes.indices, id: \.self) { i in
                        let e = episodes[i]
                        PlayerPopoverRow(title: (episodes.count > 1 ? "E\(e.ep)  " : "") + (e.title.isEmpty ? "第\(e.ep)集" : e.title),
                                         detail: e.duration > 0 ? "\(max(1, e.duration / 60)) 分钟" : "",
                                         subtitle: dateLine, selected: i == current, id: "player.ep.\(e.ep)") { onPick(i) }
                            .id(i)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .onAppear { proxy.scrollTo(current, anchor: .center) }
        }
    }
}

// MARK: More settings

/// Feeds the pre-buffer figure to the panel without making the page observe it.
struct MoreSettingsHost<Content: View>: View {
    @ObservedObject var telemetry: PlaybackTelemetry
    let content: (String?) -> Content
    var body: some View {
        content(telemetry.prebuffer.map { $0.lowStorage ? "存储不足，已停止预缓冲" : "已预缓冲 \($0.bytes / 1_048_576) MB" })
    }
}

/// `更多设置` panel (a SwiftUI `Menu` would rebuild its backdrop on every change; synced 1:1 with Android `MoreSettingsPanel`).
struct MoreSettingsPopover: View {
    let fillScreen: Bool
    let enhanceLevel: Int
    let sdrToHdr: Bool
    let isNativeHdr: Bool
    let sleepMode: Int
    let autoNext: Bool
    let autoNextDrama: Bool
    let showAutoNext: Bool
    let showAutoNextDrama: Bool
    let showTech: Bool
    let muted: Bool
    let showDanmaku: Bool
    let danmakuSummary: String
    let prebufferInfo: String?
    var qualityLabel: String? = nil
    var onOpenQuality: (() -> Void)? = nil
    var onOpenAudio: (() -> Void)? = nil
    let onClose: () -> Void
    let onOpenDanmaku: () -> Void
    let onFillScreen: (Bool) -> Void
    let onEnhance: (Int) -> Void
    let onSdrToHdr: (Bool) -> Void
    let onSleep: (Int) -> Void
    let onAutoNext: (Bool) -> Void
    let onAutoNextDrama: (Bool) -> Void
    let onToggleTech: () -> Void
    let onToggleMute: () -> Void
    let onCopyTitle: () -> Void

    private var sleepSubtitle: String? {
        switch sleepMode {
        case -1: return "定时：播完本集"
        case let m where m > 0: return "定时：\(m) 分钟"
        default: return prebufferInfo
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("更多设置").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                    if let sub = sleepSubtitle, !sub.isEmpty {
                        Text(sub).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                    }
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 30, height: 30)
                        .background(Color.white.opacity(0.12), in: Circle())
                        .frame(width: 44, height: 44).contentShape(Circle())
                }
                .buttonStyle(PressScale())
                .accessibilityLabel("关闭")
            }

            if onOpenQuality != nil || onOpenAudio != nil {
                HStack(spacing: 8) {
                    if let onOpenQuality {
                        Button(action: onOpenQuality) {
                            HStack(spacing: 6) {
                                Image(systemName: "sparkles.tv").font(.system(size: 14, weight: .medium))
                                Text(qualityLabel ?? "画质与线路").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            }
                            .foregroundStyle(PlayerPalette.ivory)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(PressScale())
                        .accessibilityIdentifier("player.more.quality")
                    }
                    if let onOpenAudio {
                        Button(action: onOpenAudio) {
                            HStack(spacing: 6) {
                                Image(systemName: "captions.bubble").font(.system(size: 14, weight: .medium))
                                Text("音轨与字幕").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            }
                            .foregroundStyle(PlayerPalette.ivory)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(PressScale())
                        .accessibilityIdentifier("player.more.audio")
                    }
                }
            }

            if showDanmaku {
                Button(action: onOpenDanmaku) {
                    HStack(spacing: 10) {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                        Text("弹幕设置").font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                        Spacer()
                        Text(danmakuSummary).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(.horizontal, 12).frame(height: 46)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressScale())
            }

            optionSection("画面比例", items: [("适应", false), ("铺满", true)], selected: fillScreen, onSelect: onFillScreen)
            optionSection("画质增强", items: [("关闭", 0), ("标准", 1), ("强效", 2)], selected: enhanceLevel, onSelect: onEnhance)
            if isNativeHdr {
                optionSection("SDR 转 HDR · 当前片源已是原生 HDR", items: [("原生 HDR", true)], selected: true, onSelect: { _ in })
                    .opacity(0.55).allowsHitTesting(false)
            } else {
                optionSection("SDR 转 HDR (逆色调映射)", items: [("关闭", false), ("开启", true)], selected: sdrToHdr, onSelect: onSdrToHdr)
            }
            optionSection("定时关闭", items: [("关", 0), ("本集完", -1), ("15分", 15), ("30分", 30), ("60分", 60)], selected: sleepMode, onSelect: onSleep)
            if showAutoNext {
                optionSection("自动连播", items: [("开启", true), ("关闭", false)], selected: autoNext, onSelect: onAutoNext)
            }
            if showAutoNextDrama {
                optionSection("播完连刷推荐", items: [("开启", true), ("关闭", false)], selected: autoNextDrama, onSelect: onAutoNextDrama)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("快捷操作").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        PlayerPanelChip(title: "技术信息", selected: showTech, symbol: "info.circle", height: 34, action: onToggleTech)
                        PlayerPanelChip(title: muted ? "已静音" : "静音", selected: muted, symbol: muted ? "speaker.slash.fill" : "speaker.wave.2", height: 34, action: onToggleMute)
                        PlayerPanelChip(title: "复制剧名", selected: false, symbol: "doc.on.doc", height: 34, action: onCopyTitle)
                    }
                }
            }
        }
        .padding(.leading, 18).padding(.trailing, 14).padding(.vertical, 14)
    }

    private func optionSection<T: Equatable>(_ label: String, items: [(String, T)], selected: T, onSelect: @escaping (T) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.6))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(items.indices, id: \.self) { idx in
                        let on = items[idx].1 == selected
                        PlayerPanelChip(title: items[idx].0, selected: on) {
                            guard !on else { return }
                            UISelectionFeedbackGenerator().selectionChanged()
                            onSelect(items[idx].1)
                        }
                    }
                }
            }
        }
    }
}
