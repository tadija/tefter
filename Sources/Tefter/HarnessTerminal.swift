import Foundation
import Hummingbird
import HummingbirdWebSocket
import TermSpool

struct HarnessTerminalTicket: Sendable {
  let execution: String
  let space: String
  let csrf: String
  let expires: Date
}

struct TerminalTicketResponse: ResponseCodable { let ticket: String }
private struct TerminalSize: Decodable { let cols: Int; let rows: Int }

extension Identity {
  private func terminalLaunch(_ id: String, space: String, user: String) throws -> (ExecutionRecord, String, String) {
    let record = try execution(id, space: space, user: user)
    guard record.status != "finished", record.status != "running", !activeTerminals.contains(id) else {
      throw HTTPError(.conflict)
    }
    guard let policy = try db.rows("SELECT t.executable,h.credential_home FROM harness_terminals t JOIN harness_connections h ON h.id=t.connection WHERE t.connection=?", [record.connection]).first else {
      throw HTTPError(.forbidden)
    }
    return (record, policy["executable"]!, policy["credential_home"]!)
  }

  func terminalTicket(_ id: String, space: String, request: Request) throws -> TerminalTicketResponse {
    let login = try session(request)
    _ = try terminalLaunch(id, space: space, user: login.user)
    terminalTickets = terminalTickets.filter { $0.value.expires > Date() }
    guard terminalTickets.count < 64 else { throw HTTPError(.tooManyRequests) }
    let ticket = Self.token()
    terminalTickets[ticket] = HarnessTerminalTicket(execution: id, space: space, csrf: login.csrf, expires: Date().addingTimeInterval(30))
    return TerminalTicketResponse(ticket: ticket)
  }

  func checkTerminalTicket(_ token: String, id: String, space: String, request: Request) throws {
    try checkSocketOrigin(request)
    let login = try session(request)
    guard let ticket = terminalTickets[token], ticket.expires > Date(), ticket.csrf == login.csrf,
      ticket.execution == id, ticket.space == space else { throw HTTPError(.forbidden) }
  }

  func openTerminal(_ token: String, id: String, space: String, request: Request) throws -> (TerminalPTY, ExecutionRecord, String) {
    try checkTerminalTicket(token, id: id, space: space, request: request)
    terminalTickets.removeValue(forKey: token)
    let user = try session(request).user
    let (record, executable, homePath) = try terminalLaunch(id, space: space, user: user)
    guard runningExecutions < 4 else { throw HTTPError(.tooManyRequests) }
    let work = try Directory(root: home.path).directory("runtime").directory("harness-work", create: true)
    _ = try work.directory(id, create: true)
    let terminal = try TerminalPTY(executable: executable,
      workingDirectory: home.appendingPathComponent("runtime/harness-work/" + id).path,
      environment: ["PATH": "/usr/bin:/bin", "HOME": homePath, "CODEX_HOME": homePath, "TERM": "xterm-256color", "GIT_TERMINAL_PROMPT": "0"])
    try audit(user, "open-harness-terminal", id)
    activeTerminals.insert(id)
    runningExecutions += 1
    return (terminal, record, user)
  }

  func checkTerminalAccess(_ record: ExecutionRecord, request: Request) throws {
    let user = try session(request).user
    _ = try executionPolicy(record.connection, space: record.space, user: user)
    if let repo = record.repo { _ = try repoAccess(repo, space: record.space, user: user) }
  }

  func closeTerminal(_ pty: TerminalPTY, id: String, user: String) throws {
    pty.closeSession()
    activeTerminals.remove(id)
    runningExecutions -= 1
    try audit(user, "close-harness-terminal", id)
  }
}

func registerHarnessTerminalSocket(_ router: Router<BasicWebSocketRequestContext>, _ identity: Identity) {
  router.ws("/api/v1/spaces/:space/executions/:execution/terminal/:ticket") { request, context in
    try await identity.checkTerminalTicket(context.parameters.require("ticket"), id: context.parameters.require("execution"),
      space: context.parameters.require("space"), request: request)
    return .upgrade([.cacheControl: "no-store"])
  } onUpgrade: { inbound, outbound, context in
    let parameters = context.requestContext.parameters
    let request = context.request
    let (pty, record, user) = try await identity.openTerminal(parameters.require("ticket"), id: parameters.require("execution"),
      space: parameters.require("space"), request: request)
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        for try await packet in inbound.messages(maxSize: 65536) {
          try await identity.checkTerminalAccess(record, request: request)
          switch packet {
          case .binary(let bytes): try pty.input(Data(bytes.readableBytesView))
          case .text(let text):
            let size = try JSONDecoder().decode(TerminalSize.self, from: Data(text.utf8))
            try pty.resize(cols: size.cols, rows: size.rows)
          }
        }
      }
      group.addTask {
        while let bytes = await pty.readChunk() {
          try await identity.checkTerminalAccess(record, request: request)
          try await outbound.write(.binary(.init(bytes: bytes)))
        }
      }
      group.addTask {
        while !Task.isCancelled {
          try await Task.sleep(for: .seconds(1))
          try await identity.checkTerminalAccess(record, request: request)
        }
      }
      defer { group.cancelAll() }
      do {
        _ = try await group.next()
      } catch {
        try await identity.closeTerminal(pty, id: record.id, user: user)
        throw error
      }
      try await identity.closeTerminal(pty, id: record.id, user: user)
    }
  }
}
