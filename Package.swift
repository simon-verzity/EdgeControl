// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EdgeControl",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "EdgeControl", targets: ["EdgeControl"])],
    targets: [.executableTarget(name: "EdgeControl")]
)
