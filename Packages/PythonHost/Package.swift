// swift-tools-version:5.9
// Runtime loader for an optional embedded CPython (see README.md). Links nothing: Python.framework is opened with dlopen.
import PackageDescription

let package = Package(
    name: "PythonHost",
    platforms: [.iOS(.v16), .macOS(.v14)],
    products: [.library(name: "CPythonHost", targets: ["CPythonHost"])],
    targets: [
        .target(name: "CPythonHost", path: "Sources/CPythonHost", publicHeadersPath: "include")
    ]
)
