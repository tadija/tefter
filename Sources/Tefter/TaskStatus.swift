import Foundation
import Hummingbird
import Yams

struct StatusChange: Decodable {
  let path: String
  let revision: String
  let status: String
}

extension Identity {
  func setStatus(_ space: String, change: StatusChange, request: Request) throws {
    let user = try session(request).user
    let file = try document(change.path, root: root(space, user: user))
    guard file.document.revision == change.revision else { throw HTTPError(.conflict) }
    guard file.document.type == "task", ["todo", "in-progress", "done"].contains(change.status)
    else { throw HTTPError(.badRequest) }
    let newline = file.text.hasPrefix("---\r\n") ? "\r\n" : "\n"
    let parts = file.text.components(separatedBy: newline)
    guard let end = parts.indices.dropFirst().first(where: { parts[$0] == "---" }),
      var header = try compose(yaml: parts[1..<end].joined(separator: "\n"))
    else { throw HTTPError(.conflict) }
    header["status"] = Node(change.status)
    let yaml = try serialize(node: header, allowUnicode: true).trimmingCharacters(in: .newlines)
    let text = ["---", yaml.replacingOccurrences(of: "\n", with: newline)] + parts[end...]
    try mutate(
      space, user: user,
      change: FileChange(
        path: change.path, text: text.joined(separator: newline), revision: change.revision,
        destination: nil), action: "write")
    try audit(user, "task-status-" + change.status, space + "/" + (file.document.id ?? change.path))
  }
}
