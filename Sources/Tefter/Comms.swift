import Crypto
import Foundation
import Hummingbird

struct Channel: Codable, Sendable {
  let id: String
  let name: String
}
struct ChannelFile: ResponseCodable {
  var version = 1
  var channels: [Channel] = []
}
struct Message: ResponseCodable, Sendable {
  let id: String
  let sequence: Int
  let author: String
  let authorKind: String
  let created: String
  let body: String
  let nonce: String
}
struct MessagePage: ResponseCodable {
  let messages: [Message]
  let cursor: Int
  let more: Bool
}
struct MessageInput: Decodable {
  let body: String
  let nonce: String
}
struct AgentInput: Decodable { let name: String }
struct AgentGrant: Decodable { let id: String }
struct AgentToken: ResponseCodable { let id: String; let token: String }
struct AgentList: ResponseCodable { let agents: [Named] }
struct CommsPrincipal { let id: String; let kind: String }

extension Identity {
  static func digest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  func spaceDirectory(_ space: String) throws -> Directory {
    guard UUID(uuidString: space) != nil,
      !(try db.rows("SELECT id FROM spaces WHERE id=?", [space])).isEmpty
    else { throw HTTPError(.notFound) }
    return try Directory(root: home.path).directory("content").directory("spaces").directory(space, create: true)
  }

  func commsPrincipal(_ space: String, request: Request) throws -> CommsPrincipal {
    if let header = request.headers[.authorization], header.hasPrefix("Bearer ") {
      let token = String(header.dropFirst(7))
      guard token.count == 64,
        let id = try db.rows("SELECT agents.id FROM agents JOIN agent_grants ON agents.id=agent_grants.id WHERE space=? AND digest=?", [space, Self.digest(token)]).first?["id"]
      else { throw HTTPError(.unauthorized) }
      return CommsPrincipal(id: id, kind: "agent")
    }
    let user = try session(request).user
    _ = try access(space, user: user)
    return CommsPrincipal(id: user, kind: "human")
  }

  func createAgent(_ name: String, request: Request) throws -> AgentToken {
    let user = try session(request).user
    try requireAdmin(user)
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 200 else { throw HTTPError(.badRequest) }
    let id = UUID().uuidString
    let token = Self.token()
    let dir = try Directory(root: home.path).directory("installation").directory("agents", create: true)
    try dir.write(id + ".md", data: Data(("# " + name + "\n\nAgent ID: " + id + "\n").utf8), replacing: false)
    try db.execute("INSERT INTO agents VALUES(?,?,?)", [id, name, Self.digest(token)])
    try audit(user, "create-agent", id)
    return AgentToken(id: id, token: token)
  }

  func agents(_ space: String, request: Request) throws -> AgentList {
    _ = try commsPrincipal(space, request: request)
    return AgentList(agents: try db.rows("SELECT agents.id,name FROM agents JOIN agent_grants ON agents.id=agent_grants.id WHERE space=? ORDER BY name,id", [space]).map { Named(id: $0["id"]!, name: $0["name"]!) })
  }

  func grantAgent(_ space: String, id: String, remove: Bool, request: Request) throws {
    let user = try session(request).user
    guard try access(space, user: user).role != "member" else { throw HTTPError(.forbidden) }
    guard !(try db.rows("SELECT id FROM agents WHERE id=?", [id])).isEmpty else { throw HTTPError(.notFound) }
    try db.execute(remove ? "DELETE FROM agent_grants WHERE space=? AND id=?" : "INSERT OR IGNORE INTO agent_grants VALUES(?,?)", [space, id])
    if !remove {
      let dir = try metadata(spaceDirectory(space)).directory("people", create: true)
      let source = try Directory(root: home.path).directory("installation").directory("agents")
      try dir.write(id + ".md", data: source.read(id + ".md"), replacing: true)
    }
    try audit(user, remove ? "revoke-agent" : "grant-agent", space + "/" + id)
  }

  func channels(_ space: String, request: Request, name: String? = nil) throws -> ChannelFile {
    let principal = try commsPrincipal(space, request: request)
    let meta = try metadata(spaceDirectory(space))
    var file = try load(ChannelFile.self, from: meta, name: "channels.json", initial: ChannelFile())
    guard file.version == 1 else { throw HTTPError(.conflict) }
    let initial = file.channels.isEmpty
    if initial { file.channels.append(Channel(id: UUID().uuidString, name: "general")) }
    if let name {
      guard principal.kind == "human", name.range(of: "^[a-z0-9][a-z0-9_-]{0,63}$", options: .regularExpression) != nil, file.channels.count < 100 else { throw HTTPError(.badRequest) }
      guard !file.channels.contains(where: { $0.name == name }) else { throw HTTPError(.conflict) }
      file.channels.append(Channel(id: UUID().uuidString, name: name))
      try audit(principal.id, "create-channel", space)
    }
    if initial || name != nil { try save(file, to: meta, name: "channels.json") }
    return file
  }

  func retentionDays() throws -> Int {
    guard let days = Int(settings["TEFTER_COMMS_RETENTION_DAYS"] ?? "30"), (1...3650).contains(days) else {
      throw HTTPError(.internalServerError, message: "TEFTER_COMMS_RETENTION_DAYS must be between 1 and 3650.")
    }
    return days
  }

  // Prune on startup, periodically, and before every history read/send.
  func retainedMessages(_ space: String, channel: String) throws -> [Message] {
    guard UUID(uuidString: channel) != nil else { throw HTTPError(.badRequest) }
    let dir = try spaceDirectory(space).directory("comms", create: true).directory(channel, create: true)
    let cutoff = Date().addingTimeInterval(-Double(try retentionDays()) * 86400)
    var messages: [Message] = []
    for year in try dir.entries() {
      guard year.range(of: "^[0-9]{4}$", options: .regularExpression) != nil else { throw HTTPError(.conflict) }
      let yd = try dir.directory(year)
      for month in try yd.entries() {
        guard month.range(of: "^[0-9]{2}$", options: .regularExpression) != nil else { throw HTTPError(.conflict) }
        let md = try yd.directory(month)
        for day in try md.entries() {
          guard day.hasSuffix(".jsonl") else { throw HTTPError(.conflict) }
          let data = try md.read(day)
          let all = try data.split(separator: 10).map { try JSONDecoder().decode(Message.self, from: Data($0)) }
          let kept = all.filter { (ISO8601DateFormatter().date(from: $0.created) ?? .distantPast) > cutoff }
          if kept.count != all.count {
            if kept.isEmpty { try md.removeFile(day) }
            else { try md.write(day, data: try encodeMessages(kept), replacing: true) }
          }
          messages.append(contentsOf: kept)
        }
      }
    }
    return messages.sorted { $0.sequence < $1.sequence }
  }

  func encodeMessages(_ messages: [Message]) throws -> Data {
    var data = Data()
    for message in messages { data.append(try JSONEncoder().encode(message)); data.append(10) }
    return data
  }

  func history(_ space: String, channel: String, after: Int, request: Request) throws -> MessagePage {
    guard after >= 0 else { throw HTTPError(.badRequest) }
    guard try channels(space, request: request).channels.contains(where: { $0.id == channel }) else { throw HTTPError(.notFound) }
    let all = try retainedMessages(space, channel: channel).filter { $0.sequence > after }
    let page = Array(all.prefix(100))
    return MessagePage(messages: page, cursor: page.last?.sequence ?? after, more: all.count > page.count)
  }

  func send(_ space: String, channel: String, input: MessageInput, request: Request) throws -> Message {
    let principal = try commsPrincipal(space, request: request)
    guard try channels(space, request: request).channels.contains(where: { $0.id == channel }) else { throw HTTPError(.notFound) }
    guard !input.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, input.body.utf8.count <= 16384, UUID(uuidString: input.nonce) != nil else { throw HTTPError(.badRequest) }
    let all = try retainedMessages(space, channel: channel)
    if let previous = all.first(where: { $0.author == principal.id && $0.nonce == input.nonce }) {
      guard previous.body == input.body else { throw HTTPError(.conflict) }
      return previous
    }
    let recent = all.filter { $0.author == principal.id && (ISO8601DateFormatter().date(from: $0.created) ?? .distantPast) > Date().addingTimeInterval(-10) }
    guard recent.count < 20 else { throw HTTPError(.tooManyRequests) }
    try db.execute("INSERT OR IGNORE INTO channel_cursors VALUES(?,?,0)", [space, channel])
    try db.execute("UPDATE channel_cursors SET sequence=max(sequence,?)+1 WHERE space=? AND channel=?", [String(all.last?.sequence ?? 0), space, channel])
    let sequence = Int(try db.rows("SELECT sequence FROM channel_cursors WHERE space=? AND channel=?", [space, channel]).first!["sequence"]!)!
    let now = Date()
    let message = Message(id: UUID().uuidString, sequence: sequence, author: principal.id, authorKind: principal.kind, created: ISO8601DateFormatter().string(from: now), body: input.body, nonce: input.nonce)
    let date = String(message.created.prefix(10))
    let parts = date.split(separator: "-").map(String.init)
    let dir = try spaceDirectory(space).directory("comms", create: true).directory(channel, create: true).directory(parts[0], create: true).directory(parts[1], create: true)
    let name = date + ".jsonl"
    var data = try dir.info(name) == nil ? Data() : dir.read(name)
    data.append(try encodeMessages([message]))
    try dir.write(name, data: data, replacing: true)
    return message
  }

  func purgeComms() throws {
    _ = try retentionDays()
    for row in try db.rows("SELECT id FROM spaces") {
      let space = row["id"]!
      let meta = try metadata(spaceDirectory(space))
      let file = try load(ChannelFile.self, from: meta, name: "channels.json", initial: ChannelFile())
      for channel in file.channels { _ = try retainedMessages(space, channel: channel.id) }
    }
  }
}

func registerComms(_ router: Router<BasicRequestContext>, _ identity: Identity) {
  router.post("/api/v1/agents") { req, ctx in
    let input = try await req.decode(as: AgentInput.self, context: ctx)
    return try await identity.createAgent(input.name, request: req)
  }
  let group = router.group("/api/v1/spaces/:space")
  group.get("agents") { req, ctx in try await identity.agents(ctx.parameters.require("space"), request: req) }
  for remove in [false, true] {
    group.on("agents", method: remove ? .delete : .put) { req, ctx -> HTTPResponse.Status in
      let input = try await req.decode(as: AgentGrant.self, context: ctx)
      try await identity.grantAgent(ctx.parameters.require("space"), id: input.id, remove: remove, request: req)
      return .noContent
    }
  }
  group.get("channels") { req, ctx in try await identity.channels(ctx.parameters.require("space"), request: req) }
  group.post("channels") { req, ctx in
    let input = try await req.decode(as: AgentInput.self, context: ctx)
    return try await identity.channels(ctx.parameters.require("space"), request: req, name: input.name)
  }
  group.get("channels/:channel/messages") { req, ctx in
    guard let after = Int(req.uri.queryParameters.get("after") ?? "0") else { throw HTTPError(.badRequest) }
    return try await identity.history(ctx.parameters.require("space"), channel: ctx.parameters.require("channel"), after: after, request: req)
  }
  group.post("channels/:channel/messages") { req, ctx in
    let input = try await req.decode(as: MessageInput.self, context: ctx)
    return try await identity.send(ctx.parameters.require("space"), channel: ctx.parameters.require("channel"), input: input, request: req)
  }
}
