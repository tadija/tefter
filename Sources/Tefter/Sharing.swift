import Foundation
import Hummingbird

struct ShareGrant: ResponseCodable {
  let id: String
  let source: String
  let entity: String
  let target: String
  let allowExport: Bool
}
struct GrantList: ResponseCodable {
  let grants: [ShareGrant]
  var next: Int?
}
struct GrantInput: Decodable {
  let path: String
  let target: String
  let allowExport: Bool
}
struct ReferenceInput: Decodable { let grant: String }
struct SharedReference: ResponseCodable {
  var version = 1
  let id: String
  let source: String
  let entity: String
  let target: String
}
struct ReferenceView: ResponseCodable {
  let reference: SharedReference
  let available: Bool
  let document: Document?
  let allowExport: Bool
}
struct ReferenceList: ResponseCodable {
  let references: [ReferenceView]
  var next: Int?
}
struct SharedPreview: ResponseCodable {
  let reference: SharedReference
  let file: FileText
  let comments: ThreadFile
}

extension Identity {
  func requireOwner(_ space: String, user: String) throws {
    guard try access(space, user: user).role == "owner" else { throw HTTPError(.forbidden) }
  }

  func grantShare(_ space: String, input: GrantInput, request: Request) throws -> ShareGrant {
    let user = try session(request).user
    try requireOwner(space, user: user)
    guard input.target != space, UUID(uuidString: input.target) != nil,
      !(try db.rows("SELECT id FROM spaces WHERE id=?", [input.target])).isEmpty
    else { throw HTTPError(.badRequest) }
    let doc = try document(input.path, root: root(space, user: user), identify: true).document
    let grant = ShareGrant(
      id: UUID().uuidString, source: space, entity: doc.id!, target: input.target,
      allowExport: input.allowExport)
    try db.execute(
      "INSERT INTO shares VALUES(?,?,?,?,?)",
      [grant.id, space, grant.entity, input.target, input.allowExport ? "1" : "0"])
    try audit(user, "grant-share", grant.id)
    return grant
  }

  func shareRow(_ id: String) throws -> ShareGrant? {
    try db.rows("SELECT * FROM shares WHERE id=?", [id]).first.map {
      ShareGrant(
        id: $0["id"]!, source: $0["source"]!, entity: $0["entity"]!, target: $0["target"]!,
        allowExport: $0["copies"] == "1")
    }
  }

  func shares(_ space: String, request: Request) throws -> GrantList {
    try requireOwner(space, user: session(request).user)
    return GrantList(
      grants: try db.rows("SELECT id FROM shares WHERE source=? ORDER BY id", [space]).compactMap {
        try shareRow($0["id"]!)
      })
  }

  func revokeShare(_ space: String, id: String, request: Request) throws {
    let user = try session(request).user
    try requireOwner(space, user: user)
    try db.execute("DELETE FROM shares WHERE id=? AND source=?", [id, space])
    try audit(user, "revoke-share", id)
  }

  func referenceFiles(_ space: String) throws -> [SharedReference] {
    let dir = try metadata(spaceDirectory(space)).directory("references", create: true)
    return try dir.entries().filter { $0.hasSuffix(".json") }.map { name in
      let reference = try JSONDecoder().decode(SharedReference.self, from: dir.read(name))
      guard reference.version == 1, UUID(uuidString: reference.id) != nil,
        UUID(uuidString: reference.source) != nil, UUID(uuidString: reference.entity) != nil,
        reference.target == space, name == reference.id + ".json"
      else { throw HTTPError(.conflict) }
      return reference
    }
  }

  func acceptReference(_ space: String, grant: String, request: Request) throws -> SharedReference {
    let user = try session(request).user
    _ = try access(space, user: user)
    guard let share = try shareRow(grant), share.target == space else { throw HTTPError(.notFound) }
    let reference = SharedReference(
      id: share.id, source: share.source, entity: share.entity, target: space)
    try save(
      reference, to: metadata(spaceDirectory(space)).directory("references", create: true),
      name: reference.id + ".json")
    try audit(user, "accept-reference", grant)
    return reference
  }

  func resolveReference(_ reference: SharedReference) throws -> (ShareGrant, Directory, FileText) {
    guard let share = try shareRow(reference.id), share.source == reference.source,
      share.entity == reference.entity, share.target == reference.target
    else { throw HTTPError(.notFound, message: "Shared content is unavailable.") }
    let source = try spaceDirectory(share.source)
    guard let doc = try scan(source).documents.first(where: { $0.id == share.entity }) else {
      throw HTTPError(.notFound)
    }
    let file = try document(doc.path, root: source)
    guard file.document.id == share.entity else { throw HTTPError(.conflict) }
    return (share, source, file)
  }

  func references(_ space: String, request: Request) throws -> ReferenceList {
    _ = try access(space, user: session(request).user)
    return ReferenceList(
      references: try referenceFiles(space).map { ref in
        do {
          let (share, _, file) = try resolveReference(ref)
          return ReferenceView(
            reference: ref, available: true, document: file.document, allowExport: share.allowExport
          )
        } catch {
          return ReferenceView(reference: ref, available: false, document: nil, allowExport: false)
        }
      })
  }

  func sharedPreview(_ space: String, id: String, request: Request) throws -> SharedPreview {
    _ = try access(space, user: session(request).user)
    guard let ref = try referenceFiles(space).first(where: { $0.id == id }) else {
      throw HTTPError(.notFound)
    }
    let (_, root, file) = try resolveReference(ref)
    return SharedPreview(
      reference: ref, file: file,
      comments: try thread(ref.entity, root: root).page(PageWindow(request)))
  }

  func removeReference(_ space: String, id: String, request: Request) throws {
    let user = try session(request).user
    _ = try access(space, user: user)
    guard let ref = try referenceFiles(space).first(where: { $0.id == id }) else {
      throw HTTPError(.notFound)
    }
    try metadata(spaceDirectory(space)).directory("references").removeFile(ref.id + ".json")
    try audit(user, "remove-reference", id)
  }
}

func registerSharing(_ router: Router<BasicRequestContext>, _ identity: Identity) {
  let group = router.group("/api/v1/spaces/:space")
  group.get("shares") { req, ctx in
    let values = try await identity.shares(ctx.parameters.require("space"), request: req).grants
    let page = try PageWindow(req)
    return GrantList(grants: page.slice(values), next: page.next(count: values.count))
  }
  group.post("shares") { req, ctx in
    let input = try await req.decode(as: GrantInput.self, context: ctx)
    return try await identity.grantShare(
      ctx.parameters.require("space"), input: input, request: req)
  }
  group.delete("shares/:id") { req, ctx -> HTTPResponse.Status in
    try await identity.revokeShare(
      ctx.parameters.require("space"), id: ctx.parameters.require("id"), request: req)
    return .noContent
  }
  group.get("references") { req, ctx in
    let values = try await identity.references(ctx.parameters.require("space"), request: req)
      .references
    let page = try PageWindow(req)
    return ReferenceList(references: page.slice(values), next: page.next(count: values.count))
  }
  group.post("references") { req, ctx in
    let input = try await req.decode(as: ReferenceInput.self, context: ctx)
    return try await identity.acceptReference(
      ctx.parameters.require("space"), grant: input.grant, request: req)
  }
  group.get("references/:id") { req, ctx in
    try await identity.sharedPreview(
      ctx.parameters.require("space"), id: ctx.parameters.require("id"), request: req)
  }
  group.delete("references/:id") { req, ctx -> HTTPResponse.Status in
    try await identity.removeReference(
      ctx.parameters.require("space"), id: ctx.parameters.require("id"), request: req)
    return .noContent
  }
}
