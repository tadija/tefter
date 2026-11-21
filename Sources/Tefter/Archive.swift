import Foundation
import Hummingbird

#if os(Linux)
  import Glibc
#else
  import Darwin
#endif

/// ZIP32, stored entries, UTF-8 names. Keep both entry size and archive size bounded.
private struct Zip {
  var data = Data()
  var central = Data()
  var count: UInt16 = 0
  static let crcTable = (0..<256).map { byte -> UInt32 in
    var n = UInt32(byte)
    for _ in 0..<8 { n = (n >> 1) ^ (n & 1 == 0 ? 0 : 0xedb8_8320) }
    return n
  }
  mutating func add(_ path: String, _ contents: Data) throws {
    let name = Data(path.utf8)
    guard count < 65534, name.count <= 65535,
      data.count + central.count + contents.count < 128 * 1024 * 1024
    else { throw HTTPError(.contentTooLarge) }
    let crc = ~contents.reduce(UInt32.max) {
      ($0 >> 8) ^ Self.crcTable[Int(($0 ^ UInt32($1)) & 255)]
    }
    var fields = Data()
    fields.le(UInt16(20))
    fields.le(UInt16(0x800))
    fields.le(UInt16(0))
    fields.le(UInt16(0))
    fields.le(UInt16(33))
    fields.le(crc)
    fields.le(UInt32(contents.count))
    fields.le(UInt32(contents.count))
    fields.le(UInt16(name.count))
    fields.le(UInt16(0))
    central.le(UInt32(0x0201_4b50))
    central.le(UInt16(20))
    central.append(fields)
    central.le(UInt16(0))
    central.le(UInt16(0))
    central.le(UInt16(0))
    central.le(UInt32(0))
    central.le(UInt32(data.count))
    central.append(name)
    data.le(UInt32(0x0403_4b50))
    data.append(fields)
    data.append(name)
    data.append(contents)
    count += 1
  }
  mutating func finish() -> Data {
    let offset = data.count
    data.append(central)
    data.le(UInt32(0x0605_4b50))
    data.le(UInt16(0))
    data.le(UInt16(0))
    data.le(count)
    data.le(count)
    data.le(UInt32(central.count))
    data.le(UInt32(offset))
    data.le(UInt16(0))
    return data
  }
}
extension Data {
  fileprivate mutating func le<T: FixedWidthInteger>(_ n: T) {
    Swift.withUnsafeBytes(of: n.littleEndian) { append(contentsOf: $0) }
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
    var zip = Zip()
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
          try zip.add(path, dir.read(name))
        }
      }
    }
    let meta = try metadata(root)
    var ids = Set<String>()
    for doc in tree.documents where included(doc.path) {
      let (dir, name) = try root.parent(doc.path)
      try zip.add(doc.path, dir.read(name))
      if let id = doc.id {
        ids.insert(id)
        let comments = try thread(id, root: root)
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
    if folder == nil, try meta.info("references") != nil {
      let references = try meta.directory("references")
      for name in try references.entries() where name.hasSuffix(".json") {
        try zip.add(".tefter/references/" + name, references.read(name))
      }
    }
    for person in try people(space, user: user).people {
      try zip.add(
        ".tefter/people/" + person.id + ".md", meta.directory("people").read(person.id + ".md"))
    }
    try zip.add(
      ".tefter/MANIFEST.txt",
      Data(
        ("Tefter space " + space + "\nFolder: " + (folder ?? "/")
          + "\nMarkdown is readable directly. Comment authors are identified by participant UUID.\n")
          .utf8))
    try audit(user, "export", space)
    return Response(
      status: .ok,
      headers: [
        .contentType: "application/zip", .contentDisposition: "attachment; filename=space.zip",
        .cacheControl: "no-store",
      ], body: .init(byteBuffer: ByteBuffer(bytes: zip.finish())))
  }
}
