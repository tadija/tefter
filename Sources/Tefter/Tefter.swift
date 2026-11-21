import Foundation
import Hummingbird
import HummingbirdWebSocket

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
  static func main() async {
    do { try await run() } catch {
      let message: String
      switch error {
      case ConfigurationError.invalidCommand:
        message = "Usage: tefter [bootstrap EMAIL | reset-password EMAIL]"
      case ConfigurationError.instanceInUse:
        message = "The instance is locked. Stop the server before running an offline command."
      case ConfigurationError.invalidAssetsOrPort:
        message = "Check TEFTER_PORT and the compiled TEFTER_WEB directory."
      case let error as HTTPError: message = error.body ?? error.status.reasonPhrase
      default:
        message = "Startup or operation failed (" + String(describing: type(of: error)) + ")."
      }
      FileHandle.standardError.write(Data(("tefter: " + message + "\n").utf8))
      exit(EXIT_FAILURE)
    }
  }

  static func run() async throws {
    _ = umask(0o077)
    signal(SIGPIPE, SIG_IGN)
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
    let settings = try InstallationConfig.load(home: home, environment: env)
    let identity = try Identity(home: home, settings: settings)
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
    let assets = settings["TEFTER_WEB"] ?? "Web/dist"
    let publicPath = URL(fileURLWithPath: assets).standardizedFileURL.resolvingSymlinksInPath().path
    let privatePath = home.standardizedFileURL.resolvingSymlinksInPath().path
    let protectedDirectories = ["content", "config", "runtime", "installation", "secrets", "repositories", "plugins"].map {
      privatePath + "/" + $0
    }
    guard publicPath != "/", publicPath != privatePath, !privatePath.hasPrefix(publicPath + "/"),
      !protectedDirectories.contains(where: { publicPath == $0 || publicPath.hasPrefix($0 + "/") }),
      files.isReadableFile(atPath: assets + "/index.html"),
      let port = Int(settings["TEFTER_PORT"] ?? "2909"), (1...65535).contains(port)
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
    registerComms(router, identity)
    registerAudio(router, identity)
    registerSharing(router, identity)
    registerRepos(router, identity)
    registerHarnesses(router, identity)
    registerRepoGit(router, identity)
    registerPlugins(router, identity)
    registerExecutionComments(router, identity)
    registerRepoCredentials(router, identity)
    registerIntegrationLinks(router, identity)
    try await identity.recoverExecutions()
    try await identity.purgeComms()
    router.get("/api/v1/health") { _, _ in Health(status: "ok") }
    router.get("/api/v1/ready") { _, _ in Health(status: "ready") }
    router.add(middleware: FileMiddleware(assets, searchForIndexHtml: true))
    let app = Application(
      router: router,
      server: .http1WebSocketUpgrade(
        webSocketRouter: commsSocketRouter(identity),
        configuration: .init(
          ws: .init(maxFrameSize: 32768, closeTimeout: .seconds(2), validateUTF8: true))),
      configuration: .init(address: .hostname(settings["TEFTER_HOST"] ?? "127.0.0.1", port: port)))
    let history = Task { await identity.checkpointLoop() }
    do { try await app.runService() } catch {
      history.cancel()
      await history.value
      throw error
    }
    history.cancel()
    await history.value
  }

  enum ConfigurationError: Error { case invalidAssetsOrPort, invalidCommand, instanceInUse }
}
