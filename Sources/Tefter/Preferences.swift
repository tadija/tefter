import Foundation
import Hummingbird

#if os(Linux)
  import Glibc
#else
  import Darwin
#endif

struct ViewSettings: ResponseCodable {
  var version = 1
  var revision = "initial"
  var defaults: [String: String] = [:]
  var saved: [String: String] = [:]
}

extension Identity {
  func views(_ space: String, request: Request, update: ViewSettings? = nil) throws -> ViewSettings
  {
    let user = try session(request).user
    let root = try root(space, user: user)
    let meta = try metadata(root)
    let current = try load(
      ViewSettings.self, from: meta, name: "views.json", initial: ViewSettings())
    guard current.version == 1 else { throw HTTPError(.conflict) }
    guard var update else { return current }
    guard update.revision == current.revision else { throw HTTPError(.conflict) }
    let modes = [
      "Files", "Kanban", "Tasks", "Backlog", "Sprints", "Releases", "URLs", "People", "Search",
    ]
    guard update.version == 1, update.defaults.count + update.saved.count <= 500,
      (Array(update.defaults.values) + Array(update.saved.values)).allSatisfy(modes.contains)
    else { throw HTTPError(.badRequest) }
    for dir in update.defaults.keys where !dir.isEmpty { _ = try Directory.components(dir) }
    update.revision = UUID().uuidString
    try save(update, to: meta, name: "views.json")
    try audit(user, "views", space)
    return update
  }

  func syncProfiles(_ space: String) throws {
    let root = try Directory(root: home.path).directory("content").directory("spaces").directory(
      space, create: true)
    let dir = try metadata(root).directory("people", create: true)
    let rows = try db.rows(
      "SELECT users.id,email FROM users JOIN members ON members.user=users.id WHERE space=?",
      [space])
    for row in rows {
      let name = row["id"]! + ".md"
      if try dir.info(name) == nil {
        try dir.write(
          name,
          data: Data(("# " + row["email"]! + "\n\nParticipant ID: " + row["id"]! + "\n").utf8),
          replacing: false)
      }
    }
  }
}
