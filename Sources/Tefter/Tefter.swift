import Foundation
import Hummingbird

#if os(Linux)
  import Glibc
#else
  import Darwin
#endif

struct Health: ResponseCodable {
  let status: String
}

@main
enum Tefter {
  static func main() async throws {
    _ = umask(0o077)
    let env = ProcessInfo.processInfo.environment
    let files = FileManager.default
    let data =
      env["XDG_DATA_HOME"]
      ?? files.homeDirectoryForCurrentUser.appendingPathComponent(".local/share").path
    let home = URL(fileURLWithPath: env["TEFTER_HOME"] ?? data + "/tefter")
    for path in ["config", "content/spaces", "installation/organizations", "runtime", "secrets"] {
      try files.createDirectory(
        at: home.appendingPathComponent(path), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    }
    let lock = open(
      home.appendingPathComponent("runtime/instance.lock").path,
      O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
      throw ConfigurationError.instanceInUse
    }
    defer { close(lock) }
    let identity = try Identity(home: home)
    let args = Array(CommandLine.arguments.dropFirst())
    if !args.isEmpty {
      guard args.count == 2, ["bootstrap", "reset-password"].contains(args[0]) else {
        throw ConfigurationError.invalidCommand
      }
      let password: String
      if isatty(STDIN_FILENO) == 1 {
        guard let value = getpass("Password: ") else { throw ConfigurationError.invalidCommand }
        password = String(cString: value)
      } else {
        guard let value = readLine() else { throw ConfigurationError.invalidCommand }
        password = value
      }
      if args[0] == "bootstrap" {
        _ = try await identity.create(Credentials(email: args[1], password: password), by: nil)
      } else {
        try await identity.reset(email: args[1], password: password, actor: "offline")
      }
      return
    }
    let assets = env["TEFTER_WEB"] ?? "Web/dist"
    guard files.isReadableFile(atPath: assets + "/index.html"),
      let port = Int(env["TEFTER_PORT"] ?? "8080"), (1...65535).contains(port)
    else {
      throw ConfigurationError.invalidAssetsOrPort
    }
    let router = Router()
    router.add(middleware: PrivateResponseHeaders())
    router.add(middleware: ContentSecurityMiddleware())
    registerIdentity(router, identity)
    registerRecovery(router, identity)
    registerMemberships(router, identity)
    registerDocuments(router, identity)
    registerCollaboration(router, identity)
    router.get("/api/v1/health") { _, _ in Health(status: "ok") }
    router.get("/api/v1/ready") { _, _ in Health(status: "ready") }
    router.add(middleware: FileMiddleware(assets, searchForIndexHtml: true))
    let app = Application(
      router: router,
      configuration: .init(address: .hostname(env["TEFTER_HOST"] ?? "127.0.0.1", port: port)))
    let history = Task { await identity.checkpointLoop() }
    defer { history.cancel() }
    try await app.runService()
  }

  enum ConfigurationError: Error { case invalidAssetsOrPort, invalidCommand, instanceInUse }
}
