// swift-tools-version:5.9
// Vendored quickjs-ng v0.10.1 (MIT, https://github.com/quickjs-ng/quickjs, commit 3c9afc9) + i短剧 plugin sandbox shim.
import PackageDescription

let package = Package(
    name: "QuickJS",
    platforms: [.iOS(.v16), .macOS(.v14)],
    products: [.library(name: "CQuickJS", targets: ["CQuickJS"])],
    targets: [
        .target(
            name: "CQuickJS",
            path: "Sources/CQuickJS",
            sources: ["quickjs.c", "libregexp.c", "libunicode.c", "cutils.c", "xsum.c", "idj_sandbox.c"],
            publicHeadersPath: "include",
            // NDEBUG: a script stopped in the middle may leak a few objects; that must not abort the app when its runtime closes.
            cSettings: [.define("_GNU_SOURCE"), .define("NDEBUG"), .headerSearchPath(".")]
        )
    ]
)
