// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TopShelf",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "TopShelf", targets: ["TopShelf"])],
    targets: [
        .executableTarget(name: "TopShelf"),
        .testTarget(name: "TopShelfTests", dependencies: ["TopShelf"])
    ]
)
