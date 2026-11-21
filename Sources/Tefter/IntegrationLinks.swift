import Foundation
import Hummingbird

struct IntegrationLink: Codable {
  let id: String
  let source: String
  let kind: String
  let target: String
}
struct IntegrationLinkFile: Codable {
  var version = 1
  var revision = "initial"
  var links: [IntegrationLink] = []
}
struct IntegrationLinkView: ResponseCodable {
  let link: IntegrationLink
  let available: Bool
  let title: String?
}
struct IntegrationLinkList: ResponseCodable {
  let revision: String
  let links: [IntegrationLinkView]
  var next: Int?
}
struct IntegrationLinkChange: Decodable {
  let path: String
  let revision: String
  let kind: String?
  let target: String?
  let remove: String?
}

extension Identity {
  func integrationLinkFile(_ space: String) throws -> IntegrationLinkFile {
    let file = try load(IntegrationLinkFile.self, from: metadata(spaceDirectory(space)),
      name: "integration-links.json", initial: IntegrationLinkFile())
    guard file.version == 1 else { throw HTTPError(.conflict) }
    return file
  }

  func integrationTitle(_ kind: String, target: String, space: String, user: String) throws -> String {
    if kind == "repo" { return try repoAccess(target, space: space, user: user).name }
    guard kind == "session" else { throw HTTPError(.badRequest) }
    let session = try execution(target, space: space, user: user)
    return "Session " + session.id + " · " + session.status
  }

  func integrationLinks(_ space: String, path: String, request: Request,
    change: IntegrationLinkChange? = nil) throws -> IntegrationLinkList {
    let user = try session(request).user
    let directory = try root(space, user: user)
    let doc = try document(path, root: directory, identify: change != nil).document
    var file = try integrationLinkFile(space)
    if let change {
      guard let source = doc.id, change.revision == file.revision else { throw HTTPError(.conflict) }
      if let remove = change.remove {
        guard file.links.contains(where: { $0.id == remove && $0.source == source }) else { throw HTTPError(.notFound) }
        file.links.removeAll { $0.id == remove }
      } else {
        guard let kind = change.kind, let target = change.target, UUID(uuidString: target) != nil,
          file.links.count < 10_000 else { throw HTTPError(.badRequest) }
        _ = try integrationTitle(kind, target: target, space: space, user: user)
        file.links.append(IntegrationLink(id: UUID().uuidString, source: source, kind: kind, target: target))
      }
      file.revision = UUID().uuidString
      try save(file, to: metadata(directory), name: "integration-links.json")
      try audit(user, "change-integration-link", space + "/" + source)
    }
    let links = file.links.filter { $0.source == doc.id }
    let page = try PageWindow(request)
    return IntegrationLinkList(revision: file.revision, links: page.slice(links).map {
      let title = try? integrationTitle($0.kind, target: $0.target, space: space, user: user)
      return IntegrationLinkView(link: $0, available: title != nil, title: title)
    }, next: page.next(count: links.count))
  }
}

func registerIntegrationLinks(_ router: Router<BasicRequestContext>, _ identity: Identity) {
  let api = router.group("/api/v1/spaces/:space/integration-links")
  api.get { request, context in
    try await identity.integrationLinks(context.parameters.require("space"), path: request.uri.queryParameters.require("path"), request: request)
  }
  api.post { request, context in
    let change = try await request.decode(as: IntegrationLinkChange.self, context: context)
    return try await identity.integrationLinks(context.parameters.require("space"), path: change.path, request: request, change: change)
  }
}
