import Combine
import Foundation

/// One sample of the playhead. Published as a single value so a tick costs one invalidation.
struct PlaybackSample: Equatable {
    var time: Double = 0
    var duration: Double = 0
    /// Furthest playable position buffered by the core around the playhead (seconds).
    var loadedUntil: Double = 0
    /// Time the contiguous byte pre-buffer reaches (long videos through the loopback proxy).
    var prebufferedUntil: Double = 0

    var fraction: Double { duration > 0 ? min(1, max(0, time / duration)) : 0 }
    var bufferedUntil: Double { max(loadedUntil, prebufferedUntil) }
}

/// The 4 Hz part of the player state. Kept out of `PlaybackCoordinator` on purpose: the player page observes the
/// coordinator, and redrawing the whole page on every tick was what made the player stutter.
/// Only the views that draw time observe this: progress bar, time labels, skip-intro, buffer ring.
@MainActor final class PlaybackClock: ObservableObject {
    @Published private(set) var sample = PlaybackSample()
    /// Time under the finger while the progress bar is dragged (time row follows it).
    @Published var scrubPreview: Double?

    func update(_ change: (inout PlaybackSample) -> Void) {
        var next = sample
        change(&next)
        if next != sample { sample = next }
    }
}

/// Technical readouts (tech strip, pre-buffer HUD, host-drawn subtitles), also outside the coordinator.
@MainActor final class PlaybackTelemetry: ObservableObject {
    struct Prebuffer: Equatable { var bytes: Int; var until: Double; var lowStorage: Bool }
    @Published var tech: PlayerTech?
    @Published var prebuffer: Prebuffer?
    /// Cue text drawn by the host (external subtitles, and cores without their own subtitle renderer).
    @Published var subtitle: String?
}
