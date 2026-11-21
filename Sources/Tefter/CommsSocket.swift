import Foundation
import Hummingbird
import HummingbirdWebSocket

private struct SocketSend: Decodable {
  let body: String
  let nonce: String
  let csrf: String?
}

extension Identity {
  func checkSocketOrigin(_ request: Request) throws {
    // Cookie clients must prove a same-origin browser handshake. Bearer-only clients
    // may omit Origin; supplying an untrusted Origin is rejected for every client.
    if let origin = request.headers[.origin] {
      let allowed: String
      if let publicURL = settings["TEFTER_PUBLIC_URL"] {
        allowed = publicURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      } else {
        guard let host = request.head.authority else { throw HTTPError(.forbidden) }
        allowed = "http://" + host
      }
      guard origin == allowed else { throw HTTPError(.forbidden) }
    } else if request.headers[.authorization]?.hasPrefix("Bearer ") != true {
      throw HTTPError(.forbidden)
    }
  }

  func socketSend(_ space: String, channel: String, text: String, request: Request) throws {
    let input = try JSONDecoder().decode(SocketSend.self, from: Data(text.utf8))
    if request.headers[.authorization] == nil {
      guard input.csrf == (try session(request)).csrf else { throw HTTPError(.forbidden) }
    }
    _ = try send(space, channel: channel, input: MessageInput(body: input.body, nonce: input.nonce), request: request)
  }

  func openSocket(_ space: String, request: Request) throws -> String {
    let principal = try commsPrincipal(space, request: request)
    let key = principal.kind + ":" + principal.id
    guard socketCounts.values.reduce(0, +) < 64, socketCounts[key, default: 0] < 8 else { throw HTTPError(.tooManyRequests) }
    socketCounts[key, default: 0] += 1
    return key
  }
  func closeSocket(_ key: String) { socketCounts[key, default: 1] -= 1 }
}

func commsSocketRouter(_ identity: Identity) -> Router<BasicWebSocketRequestContext> {
  let router = Router(context: BasicWebSocketRequestContext.self)
  router.ws("/api/v1/spaces/:space/channels/:channel/live") { request, context in
    try await identity.checkSocketOrigin(request)
    guard let after = Int(request.uri.queryParameters.get("after") ?? "0") else { throw HTTPError(.badRequest) }
    _ = try await identity.history(context.parameters.require("space"), channel: context.parameters.require("channel"), after: after, request: request)
    return .upgrade([.cacheControl: "no-store"])
  } onUpgrade: { inbound, outbound, context in
    let request = context.request
    let space = try context.requestContext.parameters.require("space")
    let channel = try context.requestContext.parameters.require("channel")
    let key = try await identity.openSocket(space, request: request)
    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          for try await packet in inbound.messages(maxSize: 32768) {
            guard case .text(let text) = packet else { throw HTTPError(.badRequest) }
            try await identity.socketSend(space, channel: channel, text: text, request: request)
          }
        }
        group.addTask {
          var cursor = Int(request.uri.queryParameters.get("after") ?? "0") ?? 0
          while !Task.isCancelled {
            let page = try await identity.history(space, channel: channel, after: cursor, request: request)
            for message in page.messages {
              // Revalidate immediately before every outbound content event.
              _ = try await identity.commsPrincipal(space, request: request)
              try await outbound.write(.text(String(decoding: JSONEncoder().encode(message), as: UTF8.self)))
              cursor = message.sequence
            }
            if !page.more { try await Task.sleep(for: .milliseconds(250)) }
          }
        }
        _ = try await group.next()
        group.cancelAll()
      }
    } catch {
      await identity.closeSocket(key)
      throw error
    }
    await identity.closeSocket(key)
  }
  return router
}
