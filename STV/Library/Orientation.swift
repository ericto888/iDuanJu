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

/// Portrait by default on iPhone; unlock all orientations on iPad and while the player is on screen.
final class OrientationGate: NSObject, UIApplicationDelegate {
    private static var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    static var mask: UIInterfaceOrientationMask = UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait
    private static var rotationGeneration = 0
    @MainActor private static var fullscreenSnapshot: (mask: UIInterfaceOrientationMask, orientation: UIInterfaceOrientation)?
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.isPad ? .all : Self.mask
    }

    /// Apply the playback policy without rotating the device: portrait videos lock portrait;
    /// landscape videos keep the orientation that was active when playback began.
    @MainActor static func applyVideoOrientation(isPortrait: Bool) {
        guard fullscreenSnapshot == nil else { return }
        rotationGeneration += 1
        if isPad { mask = .all; refresh(); return }
        if isPortrait {
            mask = .portrait
            activeScene?.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
        } else if let scene = activeScene {
            switch scene.interfaceOrientation {
            case .landscapeLeft, .landscapeRight: mask = .landscape
            case .portrait, .portraitUpsideDown: mask = .portrait
            default: break
            }
        }
        refresh()
    }

    /// End player/fullscreen orientation overrides and return control to the system.
    @MainActor static func unlock() {
        rotationGeneration += 1
        fullscreenSnapshot = nil
        mask = isPad ? .all : .portrait
        refresh()
    }

    /// Enter fullscreen only on explicit user action, remembering both the prior mask and orientation.
    @MainActor static func enterLandscape() {
        rotationGeneration += 1
        if fullscreenSnapshot == nil {
            fullscreenSnapshot = (mask, activeScene?.interfaceOrientation ?? .portrait)
        }
        mask = isPad ? .all : .landscape
        refresh()
        activeScene?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { _ in }
    }

    /// Exit fullscreen to portrait, then release the orientation lock so device rotation works again.
    @MainActor static func exitLandscape() {
        rotationGeneration += 1
        fullscreenSnapshot = nil
        mask = isPad ? .all : .allButUpsideDown
        refresh()
        activeScene?.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
    }

    @MainActor static func lockPortrait() {
        rotationGeneration += 1
        fullscreenSnapshot = nil
        if isPad {
            mask = .all
            refresh()
            return
        }
        mask = .portrait
        activeScene?.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
        refresh()
    }

    @MainActor private static var activeScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }
    @MainActor private static func refresh() {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for win in scene.windows {
                win.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
        }
    }
}
