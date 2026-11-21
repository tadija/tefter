import Foundation
import Hummingbird
import ZIPFoundation

#if os(Linux)
  import Glibc
#else
  import Darwin
#endif

extension Archive {
  fileprivate func add(_ path: String, _ data: Data) throws {
    try addEntry(
      with: path, type: path.hasSuffix("/") ? .directory : .file,
      uncompressedSize: Int64(data.count)
    ) { position, size in
      data.subdata(in: Int(position)..<Swift.min(data.count, Int(position) + size))
    }
  }

  fileprivate func add(_ path: String, from directory: Directory, name: String) throws {
    let (source, length) = try directory.openRegular(name)
    try addEntry(with: path, type: .file, uncompressedSize: length, bufferSize: 65536) {
      position, size in
      try source.seek(toOffset: UInt64(position))
      let bytes = try source.read(upToCount: size) ?? Data()
      guard bytes.count == Swift.min(Int64(size), length - position) else {
        throw HTTPError(.conflict, message: "File changed during export.")
      }
      return bytes
    }
  }
}

extension Identity {
  func export(_ space: String, folder: String?, request: Request) throws -> Response {
    let user = try session(request).user
    let root = try root(space, user: user)
    let tree = try scan(root)
    if let folder {
      _ = try Directory.components(folder)
      guard tree.directories.contains(folder) else { throw HTTPError(.notFound) }
    }
    func included(_ path: String) -> Bool {
      folder.map { path == $0 || path.hasPrefix($0 + "/") } ?? true
    }
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tefter-export-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: temporary) }
    let url = temporary.appendingPathComponent("space.zip")
    let zip = try Archive(url: url, accessMode: .create)
    for dir in tree.directories where included(dir) { try zip.add(dir + "/", Data()) }
    for prefix in [""] + tree.directories {
      let dir: Directory
      if prefix.isEmpty {
        dir = root
      } else {
        let (parent, name) = try root.parent(prefix)
        dir = try parent.directory(name)
      }
      for name in try dir.entries()
      where !name.lowercased().hasSuffix(".md") && !name.hasPrefix(".tefter-tmp-") {
        let path = prefix.isEmpty ? name : prefix + "/" + name
        if included(path), (try dir.info(name)?.st_mode ?? 0) & S_IFMT == S_IFREG {
          _ = try Directory.components(path)
          try zip.add(path, from: dir, name: name)
        }
      }
    }
    let meta = try metadata(root)
    var ids = Set<String>()
    var participants = Set(try people(space, user: user).people.map(\.id))
    for doc in tree.documents where included(doc.path) {
      let (dir, name) = try root.parent(doc.path)
      try zip.add(doc.path, from: dir, name: name)
      if let id = doc.id {
        ids.insert(id)
        let comments = try thread(id, root: root)
        participants.formUnion(comments.comments.map(\.author))
        if !comments.comments.isEmpty {
          try zip.add(".tefter/comments/" + id + ".json", JSONEncoder().encode(comments))
        }
      }
    }
    var manifest = try load(Manifest.self, from: meta, name: "entities.json", initial: Manifest())
    manifest.documents.removeAll { !ids.contains($0.id) }
    try zip.add(".tefter/entities.json", JSONEncoder().encode(manifest))
    if try meta.info("views.json") != nil {
      var settings = try load(
        ViewSettings.self, from: meta, name: "views.json", initial: ViewSettings())
      if folder != nil { settings.defaults = settings.defaults.filter { included($0.key) } }
      try zip.add(".tefter/views.json", JSONEncoder().encode(settings))
    }
    if folder == nil {
      let links = try integrationLinkFile(space)
      if !links.links.isEmpty { try zip.add(".tefter/integration-links.json", JSONEncoder().encode(links)) }
      for repo in try listRepos(space: space, user: user) {
        if repo.space == space {
          try zip.add(".tefter/repos/" + repo.id + ".json", JSONEncoder().encode(repo))
        } else {
          try zip.add(".tefter/repo-references/" + repo.id + ".json", JSONSerialization.data(withJSONObject: ["version":1, "id":repo.id, "scope":"installation"]))
        }
        let comments = try thread(repo.id, root: root)
        if !comments.comments.isEmpty {
          participants.formUnion(comments.comments.map(\.author))
          try zip.add(".tefter/comments/" + repo.id + ".json", JSONEncoder().encode(comments))
        }
      }
      let copyShared = request.uri.queryParameters.get("includeShared") == "true"
      for ref in try referenceFiles(space) {
        // A reference never embeds a cached title, snippet or copy of the source.
        try zip.add(".tefter/references/" + ref.id + ".json", JSONEncoder().encode(ref))
        if copyShared {
          let (grant, source, file) = try resolveReference(ref)
          guard grant.allowExport else { throw HTTPError(.forbidden, message: "The source owner has not permitted shared copies.") }
          let prefix = "shared-copies/" + ref.id + "/"
          try zip.add(prefix + "content.md", Data(file.text.utf8))
          try zip.add(prefix + "comments.json", JSONEncoder().encode(thread(ref.entity, root: source)))
          let authors = Set(try thread(ref.entity, root: source).comments.map(\.author))
          let people = try metadata(source).directory("people", create: true)
          for author in authors where UUID(uuidString: author) != nil {
            if try people.info(author + ".md") != nil {
              try zip.add(prefix + "people/" + author + ".md", people.read(author + ".md"))
            }
          }
          try zip.add(prefix + "ATTRIBUTION.json", JSONEncoder().encode(ref))
        }
      }
    }
    let profiles = try meta.directory("people")
    for id in participants.sorted() where UUID(uuidString: id) != nil {
      let name = id + ".md"
      if try profiles.info(name) != nil {
        try zip.add(".tefter/people/" + name, profiles.read(name))
      }
    }
    try zip.add(
      ".tefter/MANIFEST.txt",
      Data(
        ("Tefter space " + space + "\nFolder: " + (folder ?? "/")
          + "\nMarkdown is readable directly. Comment authors are identified by participant UUID.\n")
          .utf8))
    try audit(user, "export", space)
    let source = try FileHandle(forReadingFrom: url)
    let length = try source.seekToEnd()
    try source.seek(toOffset: 0)
    // The open descriptor survives unlink. Disconnecting releases it without leaving private exports on disk.
    let body = ResponseBody(contentLength: Int(length)) { writer in
      defer { try? source.close() }
      while let bytes = try source.read(upToCount: 65536), !bytes.isEmpty {
        try await writer.write(ByteBuffer(bytes: bytes))
      }
      try await writer.finish(nil)
    }
    return Response(
      status: .ok,
      headers: [
        .contentType: "application/zip", .contentDisposition: "attachment; filename=space.zip",
        .cacheControl: "no-store",
      ], body: body)
  }
}
