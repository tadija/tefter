import Foundation
import Hummingbird

struct HarnessConnection: ResponseCodable {
  let id: String
  let name: String
  let adapter: String
  let capabilities: [String: Bool]
}
struct HarnessList: ResponseCodable { let harnesses: [HarnessConnection] }
struct HarnessInput: Decodable {
  let name: String
  let executable: String
  let credentialHome: String
  let allowAdHoc: Bool
}
struct ExecutionGrantInput: Decodable { let space: String; let user: String }
struct SessionInput: Decodable {
  let connection: String
  let message: String
  let task: String?
  let repo: String?
}
struct SessionMessageInput: Decodable { let message: String }
struct ConversationTurn: Codable { let role: String; let text: String; let created: String }
struct ExecutionRecord: ResponseCodable {
  var version = 1
  let id: String
  let space: String
  let connection: String
  let initiator: String
  let task: String?
  let repo: String?
  let created: String
  var updated: String
  var status: String
  var conversation: [ConversationTurn]
}
struct ExecutionList: ResponseCodable { let sessions: [ExecutionRecord]; var next: Int? }

extension Identity {
  static func timestamp() -> String { ISO8601DateFormatter().string(from: Date()) }
  func recoverExecutions() throws {
    let directory = try executionDirectory()
    for row in try db.rows("SELECT id FROM executions") {
      let id = row["id"]!
      var record = try JSONDecoder().decode(ExecutionRecord.self, from: directory.read(id + ".json"))
      if record.status == "running" {
        record.status = "interrupted"; record.updated = Self.timestamp()
        try save(record, to: directory, name: id + ".json")
      }
    }
  }

  static var codexCapabilities: [String: Bool] {
    ["start": true, "message": true, "status": true, "stream": false,
     "cancel": false, "resume": false, "tty": false]
  }

  func installHarness(_ input: HarnessInput, user: String) throws -> HarnessConnection {
    try requireAdmin(user)
    guard !input.name.isEmpty, input.name.count <= 200,
      input.executable.hasPrefix("/"), input.credentialHome.hasPrefix("/"),
      !input.executable.contains("\0"), !input.credentialHome.contains("\0"),
      FileManager.default.isExecutableFile(atPath: input.executable)
    else { throw HTTPError(.badRequest) }
    _ = try Directory(root: input.credentialHome)
    let id = UUID().uuidString
    try db.transaction {
      try db.execute("INSERT INTO harness_connections VALUES(?,?,?,?,?)",
        [id, input.name, input.executable, input.credentialHome, input.allowAdHoc ? "1" : "0"])
      try audit(user, "install-harness", id)
    }
    return HarnessConnection(id: id, name: input.name, adapter: "codex-exec-v1", capabilities: Self.codexCapabilities)
  }

  func harnessGrant(_ id: String, input: ExecutionGrantInput, remove: Bool, user: String) throws {
    try requireAdmin(user)
    _ = try access(input.space, user: input.user)
    guard !(try db.rows("SELECT id FROM harness_connections WHERE id=?", [id])).isEmpty else {
      throw HTTPError(.notFound)
    }
    try db.transaction {
      if remove { try db.execute("DELETE FROM execution_grants WHERE connection=? AND space=? AND user=?",
        [id, input.space, input.user]) }
      else { try db.execute("INSERT OR IGNORE INTO execution_grants VALUES(?,?,?)", [id, input.space, input.user]) }
      try audit(user, remove ? "revoke-execution" : "grant-execution", id + "/" + input.space + "/" + input.user)
    }
  }

  func executionPolicy(_ connection: String, space: String, user: String) throws -> [String: String] {
    _ = try access(space, user: user)
    guard !(try db.rows("SELECT connection FROM execution_grants WHERE connection=? AND space=? AND user=?",
      [connection, space, user])).isEmpty,
      let row = try db.rows("SELECT * FROM harness_connections WHERE id=?", [connection]).first
    else { throw HTTPError(.forbidden, message: "Separate execution authorization is required.") }
    return row
  }

  func harnesses(_ space: String, user: String) throws -> HarnessList {
    _ = try access(space, user: user)
    return HarnessList(harnesses: try db.rows("SELECT id,name FROM harness_connections WHERE id IN (SELECT connection FROM execution_grants WHERE space=? AND user=?) ORDER BY id", [space, user]).map {
      HarnessConnection(id: $0["id"]!, name: $0["name"]!, adapter: "codex-exec-v1", capabilities: Self.codexCapabilities)
    })
  }

  func executionDirectory() throws -> Directory {
    try Directory(root: home.path).directory("runtime").directory("sessions", create: true)
  }

  func execution(_ id: String, space: String, user: String) throws -> ExecutionRecord {
    guard UUID(uuidString: id) != nil,
      let row = try db.rows("SELECT connection FROM executions WHERE id=? AND space=?", [id, space]).first
    else { throw HTTPError(.notFound) }
    _ = try executionPolicy(row["connection"]!, space: space, user: user)
    let record = try JSONDecoder().decode(ExecutionRecord.self, from: executionDirectory().read(id + ".json"))
    guard record.version == 1, record.id == id, record.space == space,
      record.connection == row["connection"] else { throw HTTPError(.conflict) }
    if let repo = record.repo { _ = try repoAccess(repo, space: space, user: user) }
    return record
  }

  func executionList(_ space: String, user: String) throws -> [ExecutionRecord] {
    _ = try access(space, user: user)
    return try db.rows("SELECT id FROM executions WHERE space=? AND connection IN (SELECT connection FROM execution_grants WHERE space=? AND user=?) ORDER BY id", [space, space, user]).map {
      try execution($0["id"]!, space: space, user: user)
    }
  }

  func startExecution(_ space: String, input: SessionInput, user: String) async throws -> ExecutionRecord {
    let policy = try executionPolicy(input.connection, space: space, user: user)
    guard input.task != nil || input.repo != nil || policy["adhoc"] == "1" else {
      throw HTTPError(.forbidden, message: "This connection does not permit ad-hoc sessions.")
    }
    if let repo = input.repo { _ = try repoAccess(repo, space: space, user: user) }
    if let task = input.task {
      guard try scan(root(space, user: user)).documents.contains(where: { $0.id == task && $0.type == "task" }) else {
        throw HTTPError(.notFound)
      }
    }
    let id = UUID().uuidString, now = Self.timestamp()
    let record = ExecutionRecord(id: id, space: space, connection: input.connection, initiator: user,
      task: input.task, repo: input.repo, created: now, updated: now, status: "ready", conversation: [])
    try validateSessionMessage(input.message)
    try save(record, to: executionDirectory(), name: id + ".json")
    try db.transaction {
      try db.execute("INSERT INTO executions VALUES(?,?,?)", [id, space, input.connection])
      try audit(user, "start-execution", id)
    }
    return try await messageExecution(id, space: space, message: input.message, user: user)
  }

  func validateSessionMessage(_ message: String) throws {
    guard !message.isEmpty, message.utf8.count <= 16_384 else { throw HTTPError(.badRequest) }
  }

  func messageExecution(_ id: String, space: String, message: String, user: String) async throws -> ExecutionRecord {
    try validateSessionMessage(message)
    var record = try execution(id, space: space, user: user)
    guard record.status != "running", record.status != "finished", record.conversation.count < 100,
      record.conversation.reduce(0, { $0 + $1.text.utf8.count }) < 8 * 1024 * 1024 else {
      throw HTTPError(.conflict)
    }
    let policy = try executionPolicy(record.connection, space: space, user: user)
    guard runningExecutions < 4 else { throw HTTPError(.tooManyRequests) }
    record.conversation.append(ConversationTurn(role: "user", text: message, created: Self.timestamp()))
    record.status = "running"; record.updated = Self.timestamp()
    try save(record, to: executionDirectory(), name: id + ".json")
    try audit(user, "message-execution", id)
    runningExecutions += 1
    defer { runningExecutions -= 1 }
    let work = try Directory(root: home.path).directory("runtime").directory("harness-work", create: true)
    _ = try work.directory(id, create: true)
    let prompt = "Continue this conversation. Reply to the final user message.\n" + record.conversation.map { $0.role + ": " + $0.text }.joined(separator: "\n\n")
    let result = await Subprocess.run(executable: policy["executable"]!, arguments: [
      "exec", "--ignore-user-config", "--ignore-rules", "--ephemeral", "--skip-git-repo-check",
      "--sandbox", "read-only", "--color", "never", "--json", "-"],
      environment: ["PATH": "/usr/bin:/bin", "HOME": policy["credential_home"]!,
        "CODEX_HOME": policy["credential_home"]!, "GIT_TERMINAL_PROMPT": "0"],
      directory: home.appendingPathComponent("runtime/harness-work/" + id).path,
      input: Data(prompt.utf8), timeout: 120)
    var replies = [String]()
    if result.outcome == "completed" {
      for line in result.output.split(separator: 10) {
        guard let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
          event["type"] as? String == "item.completed", let item = event["item"] as? [String: Any],
          item["type"] as? String == "agent_message", let text = item["text"] as? String else { continue }
        replies.append(text)
      }
    }
    record.status = result.outcome == "completed" && replies.isEmpty ? "failed" : result.outcome
    if !replies.isEmpty {
      record.conversation.append(ConversationTurn(role: "assistant", text: replies.joined(separator: "\n"), created: Self.timestamp()))
    }
    record.updated = Self.timestamp()
    try save(record, to: executionDirectory(), name: id + ".json")
    try audit(user, "execution-" + record.status, id)
    // A revoked caller cannot receive output, even if execution was already underway.
    _ = try executionPolicy(record.connection, space: space, user: user)
    if let repo = record.repo { _ = try repoAccess(repo, space: space, user: user) }
    return record
  }

  func finishExecution(_ id: String, space: String, user: String) throws -> ExecutionRecord {
    var record = try execution(id, space: space, user: user)
    guard record.status != "running" else { throw HTTPError(.conflict) }
    record.status = "finished"; record.updated = Self.timestamp()
    try save(record, to: executionDirectory(), name: id + ".json")
    try audit(user, "finish-execution", id)
    return record
  }
}

func registerHarnesses(_ router: Router<BasicRequestContext>, _ identity: Identity) {
  let api = router.group("/api/v1")
  api.post("harnesses") { request, context in
    let input = try await request.decode(as: HarnessInput.self, context: context)
    return try await identity.installHarness(input, user: identity.session(request).user)
  }
  for remove in [false, true] {
    api.on("harnesses/:connection/grants", method: remove ? .delete : .put) { request, context -> HTTPResponse.Status in
      let input = try await request.decode(as: ExecutionGrantInput.self, context: context)
      try await identity.harnessGrant(context.parameters.require("connection"), input: input,
        remove: remove, user: identity.session(request).user)
      return .noContent
    }
  }
  api.get("spaces/:space/harnesses") { request, context in
    try await identity.harnesses(context.parameters.require("space"), user: identity.session(request).user)
  }
  api.get("spaces/:space/executions") { request, context in
    let page = try PageWindow(request)
    let values = try await identity.executionList(context.parameters.require("space"), user: identity.session(request).user)
    return ExecutionList(sessions: page.slice(values), next: page.next(count: values.count))
  }
  api.post("spaces/:space/executions") { request, context in
    let input = try await request.decode(as: SessionInput.self, context: context)
    return try await identity.startExecution(context.parameters.require("space"), input: input,
      user: identity.session(request).user)
  }
  api.get("spaces/:space/executions/:execution") { request, context in
    try await identity.execution(context.parameters.require("execution"), space: context.parameters.require("space"),
      user: identity.session(request).user)
  }
  api.post("spaces/:space/executions/:execution/messages") { request, context in
    let input = try await request.decode(as: SessionMessageInput.self, context: context)
    return try await identity.messageExecution(context.parameters.require("execution"), space: context.parameters.require("space"),
      message: input.message, user: identity.session(request).user)
  }
  api.post("spaces/:space/executions/:execution/finish") { request, context in
    try await identity.finishExecution(context.parameters.require("execution"), space: context.parameters.require("space"),
      user: identity.session(request).user)
  }
}
