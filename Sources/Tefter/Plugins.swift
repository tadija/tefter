import Foundation
import Hummingbird

struct PluginManifest: ResponseCodable {
  let version: Int
  let id: String
  let name: String
  let executable: String
  let arguments: [String]
  let commands: [String]
  let hooks: [String]
  let timeoutSeconds: Int
}
struct PluginInstall: Decodable {
  let version: Int
  let name: String
  let executable: String
  let arguments: [String]
  let commands: [String]
  let hooks: [String]
  let timeoutSeconds: Int
}
struct PluginInvocation: Decodable {
  let version: Int
  let point: String
  let name: String
  let text: String
}
struct PluginRequest: Encodable {
  let version: Int
  let id: String
  let point: String
  let name: String
  let text: String
}
struct PluginResponse: ResponseCodable {
  let version: Int
  let id: String
  let ok: Bool
  let text: String
}
struct PluginList: ResponseCodable { let plugins: [PluginManifest]; var next: Int? }
struct PluginRunResult: ResponseCodable {
  let id: String
  let outcome: String
  let exitCode: Int32
  let response: PluginResponse?
}

extension Identity {
  func pluginDirectory() throws -> Directory {
    try Directory(root: home.path).directory("plugins", create: true)
  }

  func installPlugin(_ input: PluginInstall, user: String) throws -> PluginManifest {
    try requireAdmin(user)
    let names = input.commands + input.hooks
    guard input.version == 1, !input.name.isEmpty, input.name.count <= 200,
      input.executable.hasPrefix("/"), !input.executable.contains("\0"),
      FileManager.default.isExecutableFile(atPath: input.executable),
      input.arguments.count <= 20, input.arguments.allSatisfy({ $0.utf8.count <= 2048 && !$0.contains("\0") }),
      !names.isEmpty, names.count <= 32,
      names.allSatisfy({ !$0.isEmpty && $0.count <= 64 && $0.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) }),
      (1...120).contains(input.timeoutSeconds)
    else { throw HTTPError(.badRequest) }
    let id = UUID().uuidString
    let manifest = PluginManifest(version: 1, id: id, name: input.name,
      executable: input.executable, arguments: input.arguments, commands: input.commands,
      hooks: input.hooks, timeoutSeconds: input.timeoutSeconds)
    try save(manifest, to: pluginDirectory().directory(id, create: true), name: "manifest.json")
    try audit(user, "install-plugin", id)
    return manifest
  }

  func plugin(_ id: String) throws -> PluginManifest {
    guard UUID(uuidString: id) != nil else { throw HTTPError(.badRequest) }
    let manifest = try JSONDecoder().decode(PluginManifest.self,
      from: pluginDirectory().directory(id).read("manifest.json"))
    guard manifest.version == 1, manifest.id == id else { throw HTTPError(.conflict) }
    return manifest
  }

  func plugins(user: String) throws -> [PluginManifest] {
    try requireAdmin(user)
    return try pluginDirectory().entries().filter { UUID(uuidString: $0) != nil }.map { try plugin($0) }
  }

  func invokePlugin(_ id: String, input: PluginInvocation, user: String) async throws -> PluginRunResult {
    try requireAdmin(user)
    let manifest = try plugin(id)
    guard input.version == 1, input.text.utf8.count <= 16_384,
      (input.point == "command" && manifest.commands.contains(input.name)) ||
      (input.point == "hook" && manifest.hooks.contains(input.name)) else { throw HTTPError(.badRequest) }
    guard runningPlugins < 4 else { throw HTTPError(.tooManyRequests) }
    runningPlugins += 1; defer { runningPlugins -= 1 }
    let requestID = UUID().uuidString
    let data = try JSONEncoder().encode(PluginRequest(version: 1, id: requestID,
      point: input.point, name: input.name, text: input.text)) + Data([10])
    try audit(user, "invoke-plugin", id + "/" + requestID)
    let result = await Subprocess.run(executable: manifest.executable, arguments: manifest.arguments,
      environment: ["PATH":"/usr/bin:/bin", "HOME":home.appendingPathComponent("plugins/" + id).path],
      directory: home.appendingPathComponent("plugins/" + id).path, input: data,
      timeout: manifest.timeoutSeconds, maximum: 65_536)
    var outcome = result.outcome
    var response: PluginResponse?
    if outcome == "completed" {
      if let decoded = try? JSONDecoder().decode(PluginResponse.self, from: result.output),
        decoded.version == 1, decoded.id == requestID {
        response = decoded
        if !decoded.ok { outcome = "plugin-error" }
      } else { outcome = "invalid-response" }
    }
    try audit(user, "plugin-" + outcome, id + "/" + requestID + "/exit-" + String(result.exitCode))
    try requireAdmin(user)
    return PluginRunResult(id: requestID, outcome: outcome, exitCode: result.exitCode, response: response)
  }
}

func registerPlugins(_ router: Router<BasicRequestContext>, _ identity: Identity) {
  let api = router.group("/api/v1/plugins")
  api.get { request, _ in
    let values = try await identity.plugins(user: identity.session(request).user)
    let page = try PageWindow(request)
    return PluginList(plugins: page.slice(values), next: page.next(count: values.count))
  }
  api.post { request, context in
    let input = try await request.decode(as: PluginInstall.self, context: context)
    return try await identity.installPlugin(input, user: identity.session(request).user)
  }
  api.post(":plugin/invoke") { request, context in
    let input = try await request.decode(as: PluginInvocation.self, context: context)
    return try await identity.invokePlugin(context.parameters.require("plugin"), input: input,
      user: identity.session(request).user)
  }
}
