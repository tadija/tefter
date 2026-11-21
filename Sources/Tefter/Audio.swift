import Foundation
import Hummingbird
import HummingbirdWebSocket

struct AudioParticipant: Codable, Sendable {
  let id: String
  let user: String
  var muted: Bool
}
struct AudioEvent: Codable, Sendable {
  let type: String
  var id: String?
  var participants: [AudioParticipant]?
  var from: String?
  var payload: String?
}
struct AudioAction: Decodable {
  let type: String
  let csrf: String
  let target: String?
  let payload: String?
  let muted: Bool?
}
struct AudioPeer {
  let space: String
  let channel: String
  let request: Request
  var participant: AudioParticipant
  var joined = false
  var queue: [AudioEvent] = []
  let created = Date()
  var window = Date()
  var sent = 0
}
struct AudioConfiguration: ResponseCodable {
  let iceServers: [AudioICEServer]
  var maximumParticipants = 6
}
struct AudioICEServer: Codable {
  let urls: [String]
  let username: String?
  let credential: String?
}

extension Identity {
  func audioAccess(_ space: String, channel: String, request: Request) throws -> Login {
    guard request.headers[.authorization] == nil else { throw HTTPError(.forbidden) }
    let login = try session(request)
    _ = try access(space, user: login.user)
    guard try channels(space, request: request).channels.contains(where: { $0.id == channel }) else {
      throw HTTPError(.notFound)
    }
    return login
  }

  func audioConfiguration(_ space: String, channel: String, request: Request) throws -> AudioConfiguration {
    _ = try audioAccess(space, channel: channel, request: request)
    let secrets = try Directory(root: home.path).directory("secrets")
    var servers: [AudioICEServer] = []
    if let info = try secrets.info("audio-ice.json") {
      guard info.st_mode & 0o077 == 0 else { throw HTTPError(.internalServerError, message: "Set mode 0600 on secrets/audio-ice.json.") }
      servers = try JSONDecoder().decode([AudioICEServer].self, from: secrets.read("audio-ice.json"))
      guard servers.count <= 8, servers.allSatisfy({ !$0.urls.isEmpty && $0.urls.count <= 8 && $0.urls.allSatisfy({
        $0.hasPrefix("stun:") || $0.hasPrefix("stuns:") || $0.hasPrefix("turn:") || $0.hasPrefix("turns:")
      }) }) else { throw HTTPError(.internalServerError, message: "Invalid audio ICE configuration.") }
    }
    return AudioConfiguration(iceServers: servers)
  }

  func openAudio(_ space: String, channel: String, request: Request) throws -> String {
    let login = try audioAccess(space, channel: channel, request: request)
    pruneAudio()
    guard audioPeers.count < 64,
      audioPeers.values.filter({ $0.participant.user == login.user }).count < 2,
      audioPeers.values.filter({ $0.space == space && $0.channel == channel }).count < 6 else {
      throw HTTPError(.tooManyRequests)
    }
    let id = UUID().uuidString
    audioPeers[id] = AudioPeer(space: space, channel: channel, request: request,
      participant: AudioParticipant(id: id, user: login.user, muted: false))
    return id
  }

  func closeAudio(_ id: String) { audioPeers.removeValue(forKey: id) }

  func pruneAudio() {
    for (id, peer) in audioPeers {
      if (!peer.joined && Date().timeIntervalSince(peer.created) > 10) ||
        (try? audioAccess(peer.space, channel: peer.channel, request: peer.request)) == nil {
        audioPeers.removeValue(forKey: id)
      }
    }
  }

  func audioAction(_ id: String, text: String) throws {
    pruneAudio()
    guard var peer = audioPeers[id] else { throw HTTPError(.forbidden) }
    let login = try audioAccess(peer.space, channel: peer.channel, request: peer.request)
    let action = try JSONDecoder().decode(AudioAction.self, from: Data(text.utf8))
    guard action.csrf == login.csrf else { throw HTTPError(.forbidden) }
    if Date().timeIntervalSince(peer.window) >= 1 { peer.window = Date(); peer.sent = 0 }
    peer.sent += 1
    guard peer.sent <= 80 else { throw HTTPError(.tooManyRequests) }
    switch action.type {
    case "join":
      guard !peer.joined else { throw HTTPError(.conflict) }
      peer.joined = true
      try audit(login.user, "join-audio", peer.space + "/" + peer.channel)
    case "mute":
      guard peer.joined, let muted = action.muted else { throw HTTPError(.badRequest) }
      peer.participant.muted = muted
    case "offer", "answer", "ice":
      guard peer.joined, let target = action.target, var recipient = audioPeers[target],
        recipient.joined, target != id, recipient.space == peer.space, recipient.channel == peer.channel,
        let payload = action.payload, payload.utf8.count <= 24_576,
        recipient.queue.count < 64 else { throw HTTPError(.badRequest) }
      recipient.queue.append(AudioEvent(type: action.type, from: id, payload: payload))
      audioPeers[target] = recipient
    default: throw HTTPError(.badRequest)
    }
    audioPeers[id] = peer
  }

  func audioEvents(_ id: String) throws -> [AudioEvent] {
    pruneAudio()
    guard var peer = audioPeers[id] else { throw HTTPError(.forbidden) }
    let roster = audioPeers.values.filter { $0.joined && $0.space == peer.space && $0.channel == peer.channel }
      .map(\.participant).sorted { $0.id < $1.id }
    let events = [AudioEvent(type: "participants", id: id, participants: roster)] + peer.queue
    peer.queue = []
    audioPeers[id] = peer
    return events
  }
}

func registerAudio(_ router: Router<BasicRequestContext>, _ identity: Identity) {
  router.get("/api/v1/spaces/:space/channels/:channel/audio") { request, context in
    try await identity.audioConfiguration(context.parameters.require("space"), channel: context.parameters.require("channel"), request: request)
  }
}

func registerAudioSocket(_ router: Router<BasicWebSocketRequestContext>, _ identity: Identity) {
  router.ws("/api/v1/spaces/:space/channels/:channel/audio/live") { request, context in
    try await identity.checkSocketOrigin(request)
    _ = try await identity.audioAccess(context.parameters.require("space"), channel: context.parameters.require("channel"), request: request)
    return .upgrade([.cacheControl: "no-store"])
  } onUpgrade: { inbound, outbound, context in
    let id = try await identity.openAudio(context.requestContext.parameters.require("space"),
      channel: context.requestContext.parameters.require("channel"), request: context.request)
    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          for try await packet in inbound.messages(maxSize: 32768) {
            guard case .text(let text) = packet else { throw HTTPError(.badRequest) }
            try await identity.audioAction(id, text: text)
          }
        }
        group.addTask {
          while !Task.isCancelled {
            for event in try await identity.audioEvents(id) {
              // Recheck immediately before each delivery, including queued SDP/ICE.
              _ = try await identity.audioAccess(context.requestContext.parameters.require("space"),
                channel: context.requestContext.parameters.require("channel"), request: context.request)
              try await outbound.write(.text(String(decoding: JSONEncoder().encode(event), as: UTF8.self)))
            }
            try await Task.sleep(for: .milliseconds(250))
          }
        }
        _ = try await group.next(); group.cancelAll()
      }
    } catch {
      await identity.closeAudio(id)
      throw error
    }
    await identity.closeAudio(id)
  }
}
