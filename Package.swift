// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tefter",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "tefter", targets: ["Tefter"])],
    dependencies: [.package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0")],
    targets: [.systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
              .systemLibrary(name: "CArgon2", pkgConfig: "libargon2"),
              .executableTarget(name: "Tefter", dependencies: ["CSQLite", "CArgon2", .product(name: "Hummingbird", package: "hummingbird")])]
)
