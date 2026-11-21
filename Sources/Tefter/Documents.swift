import Crypto
import Foundation
import Hummingbird
import Yams

#if os(Linux)
  import Glibc
#else
  import Darwin
#endif

struct Document: ResponseCodable {
  var path: String
  var revision: String
  var id: String?
  var type: String
  var title: String
  var status: String?
  var author: String?
  var assignee: String?
  var sprint: String?
  var release: String?
  var url: String?
  var description: String?
  var created: String?
  var published: String?
  var tags: [String]?
  var previewTitle: String?
  var image: String?
  var favicon: String?
}
struct Tree: ResponseCodable {
  var directories: [String]
  var documents: [Document]
  var next: Int?
}
struct FileText: ResponseCodable {
  let text: String
  let document: Document
}
struct FileChange: Decodable {
  let path: String
  let text: String?
  let revision: String?
  let destination: String?
}
struct Manifest: Codable {
  var version = 1
  struct Entry: Codable {
    var id: String
    var path: String
    var revision: String
  }
  var documents: [Entry] = []
}

extension Identity {
  func directoryRevision(_ space: String, path: String, request: Request) throws -> Identifier {
    let (dir, name) = try root(space, user: session(request).user).parent(path)
    return try Identifier(id: dirRevision(dir.directory(name)))
  }

  func tree(_ space: String, request: Request) throws -> Tree {
    let tree = try scan(root(space, user: session(request).user))
    let page = try PageWindow(request)
    return Tree(
      directories: page.slice(tree.directories), documents: page.slice(tree.documents),
      next: page.next(count: max(tree.directories.count, tree.documents.count)))
  }

  func identifyDocument(_ space: String, path: String, request: Request) throws -> FileText {
    let user = try session(request).user
    let file = try document(path, root: root(space, user: user), identify: true)
    try audit(user, "identify-document", space + "/" + file.document.id!)
    return file
  }

  func file(_ space: String, path: String, request: Request) throws -> FileText {
    try document(path, root: root(space, user: session(request).user))
  }

  func root(_ space: String, user: String) throws -> Directory {
    _ = try access(space, user: user)
    return try Directory(root: home.path).directory("content").directory("spaces").directory(
      space, create: true)
  }

  func metadata(_ root: Directory) throws -> Directory {
    try root.directory(".tefter", create: true)
  }

  func load<T: Decodable>(_ type: T.Type, from dir: Directory, name: String, initial: T) throws -> T
  {
    guard try dir.info(name) != nil else { return initial }
    return try JSONDecoder().decode(type, from: dir.read(name))
  }

  func save<T: Encodable>(_ value: T, to dir: Directory, name: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try dir.write(name, data: encoder.encode(value), replacing: true)
  }

  func describe(_ path: String, data: Data) throws -> FileText {
    guard let text = String(data: data, encoding: .utf8) else {
      throw HTTPError(.unprocessableContent)
    }
    let rev = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    var doc = Document(
      path: path, revision: rev, type: "doc",
      title: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n") + "\n"
    if normalized.hasPrefix("---\n"), let end = normalized.dropFirst(4).range(of: "\n---\n"),
      let fields = try? Yams.compose(
        yaml: String(
          normalized[normalized.index(normalized.startIndex, offsetBy: 4)..<end.lowerBound]))
    {
      doc.author = fields["author"]?.scalar?.string
      guard let kind = fields["type"]?.scalar?.string,
        ["task", "sprint", "release", "url"].contains(kind)
      else {
        return FileText(text: text, document: doc)
      }
      let names = fields.mapping?.compactMap { $0.key.scalar?.string } ?? []
      guard Set(names).count == names.count else {
        throw HTTPError(.unprocessableContent, message: "Duplicate front matter field in " + path)
      }
      for field in ["sprint", "release", "assignee"]
      where fields[field] != nil && fields[field]?.scalar == nil {
        throw HTTPError(.unprocessableContent, message: field + " accepts one ID in " + path)
      }
      guard let id = fields["id"]?.scalar?.string, UUID(uuidString: id) != nil else {
        throw HTTPError(.conflict, message: "Typed file requires a UUID at " + path)
      }
      doc.id = id.lowercased()
      doc.type = kind
      doc.title = fields["title"]?.scalar?.string ?? doc.title
      doc.status = fields["status"]?.scalar?.string
      doc.assignee = fields["assignee"]?.scalar?.string
      doc.sprint = fields["sprint"]?.scalar?.string.lowercased()
      doc.release = fields["release"]?.scalar?.string.lowercased()
      doc.description = fields["description"]?.scalar?.string
      doc.previewTitle = fields["previewTitle"]?.scalar?.string
      doc.created = fields["created"]?.scalar?.string
      doc.published = fields["published"]?.scalar?.string
      doc.tags = fields["tags"]?.sequence?.compactMap { $0.scalar?.string }
      doc.image = fields["image"]?.scalar?.string
      doc.favicon = fields["favicon"]?.scalar?.string
      doc.url = fields["url"]?.scalar?.string
      if kind == "task", !["todo", "in-progress", "done"].contains(doc.status ?? "") {
        throw HTTPError(.unprocessableContent)
      }
      if kind == "url" {
        guard let url = URL(string: doc.url ?? ""),
          ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
          url.host?.isEmpty == false, url.user == nil, url.password == nil
        else {
          throw HTTPError(
            .unprocessableContent,
            message: "Use an HTTP or HTTPS URL with a hostname and no credentials.")
        }
      }
    }
    return FileText(text: text, document: doc)
  }

  func scan(_ root: Directory) throws -> Tree {
    try recoverRelocation(root)
    var tree = Tree(directories: [], documents: [])
    func visit(_ dir: Directory, prefix: String) throws {
      for name in try dir.entries()
      where ![".tefter", ".git"].contains(name.lowercased()) && !(prefix.isEmpty && name.lowercased() == "comms") && !name.hasPrefix(".tefter-tmp-") {
        let path = prefix + name
        _ = try Directory.components(path)
        guard let info = try dir.info(name) else { continue }
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
          tree.directories.append(path)
          try visit(dir.directory(name), prefix: path + "/")
        case S_IFREG:
          if name.lowercased().hasSuffix(".md") {
            tree.documents.append(try describe(path, data: dir.read(name)).document)
          }
        default: throw HTTPError(.conflict, message: "Unsupported filesystem object at " + path)
        }
      }
    }
    try visit(root, prefix: "")
    let meta = try metadata(root)
    var manifest = try load(Manifest.self, from: meta, name: "entities.json", initial: Manifest())
    guard manifest.version == 1 else { throw HTTPError(.conflict) }
    guard Set(manifest.documents.map(\.id)).count == manifest.documents.count,
      Set(manifest.documents.map(\.path)).count == manifest.documents.count
    else { throw HTTPError(.conflict) }
    for entry in manifest.documents {
      guard UUID(uuidString: entry.id) != nil, entry.revision.count == 64 else {
        throw HTTPError(.conflict)
      }
      _ = try Directory.components(entry.path)
    }
    var changed = false
    var ids = Set<String>()
    for i in manifest.documents.indices {
      let item = manifest.documents[i]
      let indexes = tree.documents.indices.filter { tree.documents[$0].path == item.path }
      let matches =
        indexes.isEmpty
        ? tree.documents.indices.filter {
          tree.documents[$0].revision == item.revision && tree.documents[$0].type == "doc"
        } : indexes
      guard matches.count <= 1 else {
        throw HTTPError(.conflict, message: "Ambiguous move for " + item.path)
      }
      if let j = matches.first {
        guard tree.documents[j].id == nil else { throw HTTPError(.conflict) }
        tree.documents[j].id = item.id
        if item.path != tree.documents[j].path || item.revision != tree.documents[j].revision {
          manifest.documents[i].path = tree.documents[j].path
          manifest.documents[i].revision = tree.documents[j].revision
          changed = true
        }
      }
    }
    for doc in tree.documents {
      if let id = doc.id, !ids.insert(id).inserted {
        throw HTTPError(.conflict, message: "Duplicate ID at " + doc.path)
      }
    }
    if changed { try save(manifest, to: meta, name: "entities.json") }
    return tree
  }

  func document(_ path: String, root: Directory, identify: Bool = false) throws -> FileText {
    let (dir, name) = try root.parent(path)
    guard name.lowercased().hasSuffix(".md") else { throw HTTPError(.badRequest) }
    guard var doc = try scan(root).documents.first(where: { $0.path == path }) else {
      throw HTTPError(.notFound)
    }
    let result = try describe(path, data: dir.read(name))
    guard result.document.revision == doc.revision else { throw HTTPError(.conflict) }
    if identify && doc.id == nil {
      let meta = try metadata(root)
      var manifest = try load(Manifest.self, from: meta, name: "entities.json", initial: Manifest())
      let id = UUID().uuidString.lowercased()
      manifest.documents.append(.init(id: id, path: path, revision: doc.revision))
      try save(manifest, to: meta, name: "entities.json")
      doc.id = id
    }
    return FileText(text: result.text, document: doc)
  }

  func mutate(_ space: String, user: String, change: FileChange, action: String) throws {
    let root = try root(space, user: user)
    let (dir, name) = try root.parent(change.path)
    try recoverRelocation(root)
    if action == "move-directory" || action == "delete-directory" {
      try relocate(root, change: change, directory: true, move: action == "move-directory")
    } else if action == "directory" {
      guard mkdirat(dir.fd, name, 0o700) == 0 else { throw Directory.failure() }
      try dir.sync()
    } else {
      guard name.lowercased().hasSuffix(".md") else { throw HTTPError(.badRequest) }
      let tree = try scan(root)
      let old = tree.documents.first { $0.path == change.path }
      guard change.revision == old?.revision else {
        throw HTTPError(.conflict, message: "The file has changed.")
      }
      switch action {
      case "write":
        guard let text = change.text else { throw HTTPError(.badRequest) }
        var data = Data(text.utf8)
        var doc = try describe(change.path, data: data).document
        if doc.type == "url", doc.created == nil,
          let opening = text.range(
            of: text.hasPrefix("---\r\n") ? "---\r\n" : "---\n", options: .anchored)
        {
          var dated = text
          let newline = text.hasPrefix("---\r\n") ? "\r\n" : "\n"
          let created = old?.created ?? ISO8601DateFormatter().string(from: Date())
          dated.insert(
            contentsOf: "created: "
              + String(decoding: try JSONEncoder().encode(created), as: UTF8.self) + newline,
            at: opening.upperBound)
          data = Data(dated.utf8)
          doc = try describe(change.path, data: data).document
        }
        if old?.type != nil && old?.type != doc.type { throw HTTPError(.conflict) }
        if old?.type != "doc", let previous = old?.id, previous != doc.id {
          throw HTTPError(.conflict)
        }
        if let id = doc.id,
          tree.documents.contains(where: { $0.path != change.path && $0.id == id })
        {
          throw HTTPError(.conflict)
        }
        for (reference, kind) in [(doc.sprint, "sprint"), (doc.release, "release")] {
          if let reference,
            !tree.documents.contains(where: { $0.id == reference && $0.type == kind })
          {
            throw HTTPError(.unprocessableContent)
          }
        }
        if let assignee = doc.assignee,
          !(try people(space, user: user).people.contains { $0.id == assignee })
        {
          throw HTTPError(.unprocessableContent)
        }
        try dir.write(name, data: data, replacing: old != nil)
        if doc.type == "url", doc.url != old?.url {
          Task { _ = try? await enrich(doc, space: space, user: user) }
        }
      case "move", "delete":
        guard old != nil else { throw HTTPError(.notFound) }
        try relocate(root, change: change, directory: false, move: action == "move")
      default: throw HTTPError(.badRequest)
      }
    }
    indexedSpaces.remove(space)
    try audit(user, action, space + "/" + change.path)
  }
}

func registerDocuments(_ router: Router<BasicRequestContext>, _ identity: Identity) {
  let group = router.group("/api/v1/spaces/:space")
  group.get("preview-image") { req, ctx in
    try await identity.image(
      ctx.parameters.require("space"), path: req.uri.queryParameters.require("path"),
      kind: req.uri.queryParameters.require("kind"), request: req)
  }
  group.post("identify") { req, ctx in
    let input = try await req.decode(as: FileChange.self, context: ctx)
    return try await identity.identifyDocument(ctx.parameters.require("space"), path: input.path, request: req)
  }
  group.post("task-status") { req, ctx -> HTTPResponse.Status in
    let input = try await req.decode(as: StatusChange.self, context: ctx)
    try await identity.setStatus(ctx.parameters.require("space"), change: input, request: req)
    return .noContent
  }
  group.post("preview") { req, ctx in
    try await identity.preview(
      ctx.parameters.require("space"), path: req.uri.queryParameters.require("path"), request: req)
  }
  group.get("directory-revision") { req, ctx in
    try await identity.directoryRevision(
      ctx.parameters.require("space"), path: req.uri.queryParameters.require("path"), request: req)
  }
  group.get("tree") { req, ctx in
    try await identity.tree(ctx.parameters.require("space"), request: req)
  }
  group.get("file") { req, ctx in
    try await identity.file(
      ctx.parameters.require("space"), path: req.uri.queryParameters.require("path"), request: req)
  }
  for action in ["directory", "write", "delete", "move", "move-directory", "delete-directory"] {
    group.post(RouterPath(action)) { req, ctx -> HTTPResponse.Status in
      let change = try await req.decode(as: FileChange.self, context: ctx)
      try await identity.mutate(
        ctx.parameters.require("space"), user: identity.session(req).user, change: change,
        action: action)
      return .noContent
    }
  }
}
