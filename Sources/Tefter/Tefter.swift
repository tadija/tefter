import Foundation
import Hummingbird

struct Health: ResponseCodable {
    let status: String
}

@main
enum Tefter {
    static func main() async throws {
        let env = ProcessInfo.processInfo.environment
        let files = FileManager.default
        let data = env["XDG_DATA_HOME"] ?? files.homeDirectoryForCurrentUser.appendingPathComponent(".local/share").path
        let home = URL(fileURLWithPath: env["TEFTER_HOME"] ?? data + "/tefter")
        for path in ["config", "content/spaces", "installation/organizations", "runtime", "secrets"] {
            try files.createDirectory(at: home.appendingPathComponent(path), withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
        }
        let assets = env["TEFTER_WEB"] ?? "Web/dist"
        guard files.isReadableFile(atPath: assets + "/index.html"),
              let port = Int(env["TEFTER_PORT"] ?? "8080"), (1...65535).contains(port) else {
            throw ConfigurationError.invalidAssetsOrPort
        }
        let router = Router()
        router.get("/api/v1/health") { _, _ in Health(status: "ok") }
        router.get("/api/v1/ready") { _, _ in Health(status: "ready") }
        router.add(middleware: FileMiddleware(assets, searchForIndexHtml: true))
        let app = Application(router: router, configuration: .init(address: .hostname(env["TEFTER_HOST"] ?? "127.0.0.1", port: port)))
        try await app.runService()
    }

    enum ConfigurationError: Error { case invalidAssetsOrPort }
}
