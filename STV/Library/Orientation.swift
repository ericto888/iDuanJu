import SwiftUI
import UIKit

/// Root-level status bar visibility gate so `.statusBarHidden` works reliably in portrait even inside
/// nested `GeometryReader` -> `TabView` -> `NavigationStack` hierarchies on iOS 17+.
@MainActor
final class StatusBarGate: ObservableObject {
    static let shared = StatusBarGate()
    @Published private(set) var hidden = false

    func setHidden(_ value: Bool, animated: Bool = true) {
        guard hidden != value else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.2)) { hidden = value }
        } else {
            hidden = value
        }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for win in scene.windows {
                win.rootViewController?.setNeedsStatusBarAppearanceUpdate()
            }
        }
    }
}

/// iPhone starts portrait-locked; confirmed landscape episodes opt into device rotation, while
/// portrait episodes and an explicit fullscreen exit remain portrait-locked. iPad supports all orientations.
final class OrientationGate: NSObject, UIApplicationDelegate {
    private static var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    static var mask: UIInterfaceOrientationMask = UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait
    private static var rotationGeneration = 0

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.isPad ? .all : Self.mask
    }

    @MainActor private static func foregroundScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first(where: { $0.activationState == .foregroundActive })
            ?? scenes.first(where: { $0.activationState == .foregroundInactive })
            ?? scenes.first
    }

    /// Request after UIKit has observed the updated app-delegate orientation mask.
    @MainActor private static func request(_ orientation: UIInterfaceOrientationMask,
                                           in scene: UIWindowScene,
                                           generation: Int) {
        Task { @MainActor in
            await Task.yield()
            guard generation == rotationGeneration else { return }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation)) { error in
                NSLog("[OrientationGate] geometry update to %@ failed: %@", String(describing: orientation), error.localizedDescription)
            }
        }
    }

    /// Allow the system to follow physical device rotation. This changes only the supported mask;
    /// it deliberately does not request a new orientation or force the phone to rotate.
    @MainActor static func allowDeviceRotation() {
        rotationGeneration += 1
        mask = isPad ? .all : .allButUpsideDown
        refresh()
    }

    /// Freeze the current interface orientation while a new episode is loading.
    /// No geometry request is issued, so the existing player layout is not moved.
    @MainActor static func freezeCurrentOrientation() {
        rotationGeneration += 1
        guard !isPad else { mask = .all; refresh(); return }
        let orientation = foregroundScene()?.interfaceOrientation
        mask = orientation?.isLandscape == true ? .landscape : .portrait
        refresh()
    }
    /// Enter fullscreen and keep the iPhone in landscape until the explicit exit button is pressed.
    @MainActor static func enterLandscape() {
        rotationGeneration += 1
        let generation = rotationGeneration
        mask = isPad ? .all : .landscape
        refresh()
        if let scene = foregroundScene() {
            request(.landscapeRight, in: scene, generation: generation)
        } else {
            NSLog("[OrientationGate] no foreground UIWindowScene for landscape request")
        }
    }

    /// 退出横屏 button.
    @MainActor static func exitLandscape() {
        rotationGeneration += 1
        let generation = rotationGeneration
        if isPad {
            mask = .all
            refresh()
            return
        }
        // An explicit exit is a user override: return to portrait and keep it there.
        // Sensor rotation is re-enabled only after the next episode's aspect is known.
        mask = .portrait
        refresh()
        if let scene = foregroundScene() {
            request(.portrait, in: scene, generation: generation)
        } else {
            NSLog("[OrientationGate] no foreground UIWindowScene for portrait request")
        }
    }

    /// Called only when the player route itself is dismissed (not when its series identity changes).
    @MainActor static func endPlayerSession() {
        lockPortrait()
    }

    @MainActor static func lockPortrait() {
        rotationGeneration += 1
        let generation = rotationGeneration
        if isPad {
            mask = .all
            refresh()
            return
        }
        mask = .portrait
        refresh()
        if let scene = foregroundScene() {
            request(.portrait, in: scene, generation: generation)
        }
    }

    @MainActor private static func refresh() {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for win in scene.windows {
                win.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
        }
    }
}
