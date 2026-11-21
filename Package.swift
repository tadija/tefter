// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tefter",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "tefter", targets: ["Tefter"])],
    dependencies: [.package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0")],
    targets: [.executableTarget(name: "Tefter", dependencies: [.product(name: "Hummingbird", package: "hummingbird")])]
)
