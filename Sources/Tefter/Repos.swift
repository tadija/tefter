import Foundation
import Hummingbird

struct RepoRegistration: ResponseCodable {
  var version = 1
  let id: String
  let space: String?
  let name: String
  let location: String
  let description: String
}
struct RepoInput: Decodable {
  let space: String?
  let name: String
  let location: String
  let description: String?
}
struct RepoList: ResponseCodable {
  let repos: [RepoRegistration]
  var next: Int?
}
struct RepoGrantInput: Decodable { let space: String }

extension Identity {
  func repoDirectory(_ space: String?) throws -> Directory {
    if let space { return try metadata(spaceDirectory(space)).directory("repos", create: true) }
    return try Directory(root: home.path).directory("installation").directory("repos", create: true)
  }

  func repoRecord(_ id: String) throws -> RepoRegistration {
    guard UUID(uuidString: id) != nil,
      let row = try db.rows("SELECT space FROM repo_ownership WHERE id=?", [id]).first
    else { throw HTTPError(.notFound) }
    let value = try JSONDecoder().decode(
      RepoRegistration.self, from: repoDirectory(row["space"]).read(id + ".json"))
    guard value.version == 1, value.id == id, value.space == row["space"] else {
      throw HTTPError(.conflict, message: "Repo registration requires reconciliation.")
    }
    return value
  }

  func repoAccess(_ id: String, space: String, user: String) throws -> RepoRegistration {
    _ = try access(space, user: user)
    let repo = try repoRecord(id)
    let granted = try !db.rows("SELECT repo FROM repo_grants WHERE repo=? AND space=?", [id, space]).isEmpty
    guard repo.space == space || (repo.space == nil && granted)
    else { throw HTTPError(.notFound) }
    return repo
  }

  func registerRepo(_ input: RepoInput, user: String) throws -> RepoRegistration {
    if let space = input.space {
      guard try access(space, user: user).role != "member" else { throw HTTPError(.forbidden) }
    } else { try requireAdmin(user) }
    guard !input.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      input.name.utf8.count <= 200, input.location.utf8.count <= 2048,
      (input.description ?? "").utf8.count <= 4096,
      !input.location.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      !input.location.hasPrefix("-"), !input.location.isEmpty
    else { throw HTTPError(.badRequest) }
    // Registration metadata must never carry embedded passwords/tokens.
    if let url = URLComponents(string: input.location), url.scheme != nil {
      guard ["https", "ssh", "file"].contains(url.scheme!), url.password == nil,
        url.query == nil, url.fragment == nil,
        url.scheme != "https" || url.user == nil
      else { throw HTTPError(.badRequest, message: "Use a credential-free Git location.") }
    } else {
      guard input.location.hasPrefix("/") else {
        throw HTTPError(.badRequest, message: "Use an absolute local path or https/ssh URL.")
      }
    }
    let value = RepoRegistration(id: UUID().uuidString, space: input.space, name: input.name,
      location: input.location, description: input.description ?? "")
    let directory = try repoDirectory(input.space)
    try save(value, to: directory, name: value.id + ".json")
    do {
      try db.transaction {
        if let space = input.space {
          try db.execute("INSERT INTO repo_ownership(id,space) VALUES(?,?)", [value.id, space])
        } else { try db.execute("INSERT INTO repo_ownership(id) VALUES(?)", [value.id]) }
        try audit(user, "register-repo", value.id)
      }
    } catch {
      try? directory.removeFile(value.id + ".json")
      throw error
    }
    return value
  }

  func listRepos(space: String?, user: String) throws -> [RepoRegistration] {
    if let space {
      _ = try access(space, user: user)
      return try db.rows("SELECT id FROM repo_ownership WHERE space=? OR (space IS NULL AND id IN (SELECT repo FROM repo_grants WHERE space=?)) ORDER BY id", [space, space]).map {
        try repoAccess($0["id"]!, space: space, user: user)
      }
    }
    try requireAdmin(user)
    return try db.rows("SELECT id FROM repo_ownership WHERE space IS NULL ORDER BY id").map {
      try repoRecord($0["id"]!)
    }
  }

  func repoGrant(_ id: String, space: String, remove: Bool, user: String) throws {
    try requireAdmin(user)
    guard try repoRecord(id).space == nil else { throw HTTPError(.forbidden) }
    guard !(try db.rows("SELECT id FROM spaces WHERE id=?", [space])).isEmpty else {
      throw HTTPError(.notFound)
    }
    try db.transaction {
      if remove { try db.execute("DELETE FROM repo_grants WHERE repo=? AND space=?", [id, space]) }
      else { try db.execute("INSERT OR IGNORE INTO repo_grants VALUES(?,?)", [id, space]) }
      try audit(user, remove ? "revoke-repo" : "grant-repo", id + "/" + space)
    }
  }
}

func registerRepos(_ router: Router<BasicRequestContext>, _ identity: Identity) {
  let api = router.group("/api/v1")
  api.post("repos") { request, context in
    let input = try await request.decode(as: RepoInput.self, context: context)
    return try await identity.registerRepo(input, user: identity.session(request).user)
  }
  api.get("repos") { request, _ in
    let page = try PageWindow(request)
    let values = try await identity.listRepos(space: request.uri.queryParameters.get("space"),
      user: identity.session(request).user)
    return RepoList(repos: page.slice(values), next: page.next(count: values.count))
  }
  api.get("spaces/:space/repos/:repo") { request, context in
    try await identity.repoAccess(context.parameters.require("repo"),
      space: context.parameters.require("space"), user: identity.session(request).user)
  }
  for remove in [false, true] {
    api.on("repos/:repo/grants", method: remove ? .delete : .put) { request, context -> HTTPResponse.Status in
      let input = try await request.decode(as: RepoGrantInput.self, context: context)
      try await identity.repoGrant(context.parameters.require("repo"), space: input.space,
        remove: remove, user: identity.session(request).user)
      return .noContent
    }
  }
}
