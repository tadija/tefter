// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Tefter",
  platforms: [.macOS(.v14)],
  products: [.executable(name: "tefter", targets: ["Tefter"])],
  dependencies: [
    .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.8.1"),
    .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.8.0"),
    .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    .package(url: "https://github.com/jpsim/Yams.git", from: "6.0.0"),
    .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"6.0.0"),
  ],
  targets: [
    .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
    .systemLibrary(name: "CArgon2", pkgConfig: "libargon2"),
    .target(name: "PreviewTransport", linkerSettings: [.linkedLibrary("curl")]),
    .executableTarget(
      name: "Tefter",
      dependencies: [
        "CSQLite", "CArgon2", "Yams", "SwiftSoup", "PreviewTransport", "ZIPFoundation",
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "Hummingbird", package: "hummingbird"),
        .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
      ], plugins: ["BuildVersion"]),
    .plugin(name: "BuildVersion", capability: .buildTool()),
    .testTarget(name: "StorageTests", dependencies: ["Tefter"], path: "Tests/StorageTests"),
  ]
)
