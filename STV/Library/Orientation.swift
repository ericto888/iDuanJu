import SwiftUI
import UIKit

/// Portrait by default on iPhone; unlock all orientations on iPad and while the player is on screen.
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

    @MainActor static func unlock() {
        rotationGeneration += 1
        mask = isPad ? .all : .allButUpsideDown
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
        // Constrain during the portrait transition, then restore sensor rotation after it settles.
        mask = .portrait
        refresh()
        if let scene = foregroundScene() {
            request(.portrait, in: scene, generation: generation)
        } else {
            NSLog("[OrientationGate] no foreground UIWindowScene for portrait request")
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 650_000_000)
            if generation == rotationGeneration { mask = .allButUpsideDown; refresh() }
        }
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
