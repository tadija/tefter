import Crypto
import Foundation
import Hummingbird
import PreviewTransport

#if os(Linux)
  import Glibc
#else
  import Darwin
#endif

struct Relocation: Codable {
  let version: Int
  let path: String
  let destination: String?
  let revision: String
  let directory: Bool
}

extension Identity {
  func dirRevision(_ directory: Directory) throws -> String {
    var digest = SHA256()
    func visit(_ dir: Directory, prefix: String) throws {
      for name in try dir.entries() {
        let path = prefix + name
        _ = try Directory.components(path)
        guard let info = try dir.info(name) else { throw HTTPError(.conflict) }
        digest.update(data: Data(path.utf8))
        digest.update(data: Data([0]))
        switch info.st_mode & S_IFMT {
        case S_IFDIR: try visit(dir.directory(name), prefix: path + "/")
        case S_IFREG: digest.update(data: Data(SHA256.hash(data: try dir.read(name))))
        default: throw HTTPError(.conflict)
        }
      }
    }
    try visit(directory, prefix: "")
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
  }

  func relocate(_ root: Directory, change: FileChange, directory: Bool, move: Bool) throws {
    guard let revision = change.revision else { throw HTTPError(.conflict) }
    let (dir, name) = try root.parent(change.path)
    let current =
      try directory
      ? dirRevision(dir.directory(name))
      : describe(change.path, data: dir.read(name)).document.revision
    guard current == revision else { throw HTTPError(.conflict) }
    let destination = move ? change.destination : nil
    if move {
      guard let destination, directory || destination.lowercased().hasSuffix(".md"),
        !destination.hasPrefix(change.path + "/")
      else { throw HTTPError(.badRequest) }
      let (next, last) = try root.parent(destination)
      guard try next.info(last) == nil else { throw HTTPError(.conflict) }
    } else if directory, !(try dir.directory(name).entries()).isEmpty {
      throw HTTPError(.conflict, message: "Empty the directory before deleting it.")
    }
    let journal = Relocation(
      version: 1, path: change.path, destination: destination, revision: revision,
      directory: directory)
    let meta = try metadata(root)
    try save(journal, to: meta, name: "relocation.json")
    do {
      if let destination {
        let (next, last) = try root.parent(destination)
        guard tefter_rename_exclusive(dir.fd, name, next.fd, last) == 0 else {
          throw Directory.failure()
        }
        try next.sync()
      } else {
        guard unlinkat(dir.fd, name, directory ? AT_REMOVEDIR : 0) == 0 else {
          throw Directory.failure()
        }
      }
      try dir.sync()
    } catch {
      try recoverRelocation(root)
      throw error
    }
    try recoverRelocation(root)
  }

  func recoverRelocation(_ root: Directory) throws {
    let meta = try metadata(root)
    guard try meta.info("relocation.json") != nil else { return }
    let journal = try JSONDecoder().decode(Relocation.self, from: meta.read("relocation.json"))
    guard journal.version == 1 else { throw HTTPError(.conflict) }
    let (dir, name) = try root.parent(journal.path)
    if try dir.info(name) == nil {
      if let destination = journal.destination {
        let (next, last) = try root.parent(destination)
        let rev =
          try journal.directory
          ? dirRevision(next.directory(last))
          : describe(destination, data: next.read(last)).document.revision
        guard rev == journal.revision else {
          throw HTTPError(.conflict, message: "Resolve interrupted move before rescanning.")
        }
      }
      var manifest = try load(Manifest.self, from: meta, name: "entities.json", initial: Manifest())
      manifest.documents = manifest.documents.compactMap { entry in
        guard
          entry.path == journal.path
            || (journal.directory && entry.path.hasPrefix(journal.path + "/"))
        else { return entry }
        guard let destination = journal.destination else { return nil }
        var moved = entry
        moved.path = destination + String(entry.path.dropFirst(journal.path.count))
        return moved
      }
      try save(manifest, to: meta, name: "entities.json")
    }
    guard unlinkat(meta.fd, "relocation.json", 0) == 0 else { throw Directory.failure() }
    try meta.sync()
  }
}
