import Foundation
import Hummingbird

extension Identity {
  /// Rebuild a private Git work tree solely from validated durable workspace files.
  func checkpoint(_ space: String) async throws {
    guard UUID(uuidString: space) != nil else { throw HTTPError(.internalServerError) }
    let root = try Directory(root: home.path).directory("content").directory("spaces").directory(
      space, create: true)
    try syncProfiles(space)
    let tree = try scan(root)
    let fm = FileManager.default
    let privateDir = home.appendingPathComponent("runtime/history")
    try fm.createDirectory(
      at: privateDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let repo = privateDir.appendingPathComponent(space + ".git")
    let snapshot = privateDir.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(
      at: snapshot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: snapshot) }
    func copy(_ path: String) throws {
      let (dir, name) = try root.parent(path, internalPath: true)
      let dest = snapshot.appendingPathComponent(path)
      try fm.createDirectory(
        at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
      try dir.read(name).write(to: dest)
    }
    for doc in tree.documents {
      try copy(doc.path)
      if let id = doc.id {
        let meta = try metadata(root)
        if try meta.info("comments") != nil,
          try meta.directory("comments").info(id + ".json") != nil
        {
          try copy(".tefter/comments/" + id + ".json")
        }
      }
    }
    let meta = try metadata(root)
    for name in ["entities.json", "views.json"] where try meta.info(name) != nil {
      try copy(".tefter/" + name)
    }
    for name in ["people", "references", "repos"] where try meta.info(name) != nil {
      let dir = try meta.directory(name)
      for file in try dir.entries() where file.hasSuffix(name == "people" ? ".md" : ".json") {
        try copy(".tefter/" + name + "/" + file)
      }
    }
    try await Task.detached(priority: .utility) { [privateDir, repo, snapshot] in
      func git(_ args: [String], allowed: [Int32] = [0]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.environment = [
          "PATH": "/usr/bin:/bin", "HOME": privateDir.path, "GIT_CONFIG_NOSYSTEM": "1",
          "GIT_CONFIG_GLOBAL": "/dev/null",
        ]
        process.arguments =
          [
            "-c", "core.hooksPath=/dev/null", "-c", "user.name=Tefter", "-c",
            "user.email=workspace@localhost", "--git-dir=" + repo.path,
            "--work-tree=" + snapshot.path,
          ] + args
        process.currentDirectoryURL = snapshot
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard allowed.contains(process.terminationStatus) else {
          throw HTTPError(.internalServerError, message: "Private checkpoint failed.")
        }
        return process.terminationStatus
      }
      if !FileManager.default.fileExists(atPath: repo.path) { _ = try git(["init", "--quiet"]) }
      _ = try git(["add", "--all", "--", "."])
      if try git(["diff", "--cached", "--quiet", "--exit-code"], allowed: [0, 1]) == 1 {
        _ = try git(["commit", "--quiet", "-m", "Workspace checkpoint"])
      }
    }.value
  }

  func checkpointLoop() async {
    while !Task.isCancelled {
      do {
        try purgeComms()
        for row in try db.rows("SELECT id FROM spaces") {
          guard !Task.isCancelled else { return }
          if let space = row["id"] {
            do { try await checkpoint(space) } catch {
              FileHandle.standardError.write(
                Data(("Checkpoint failed for " + space + "; retrying next interval.\n").utf8))
            }
          }
        }
      } catch {
        FileHandle.standardError.write(
          Data("Workspace checkpoint failed; retrying next interval.\n".utf8))
      }
      do { try await Task.sleep(for: .seconds(30)) } catch { return }
    }
  }
}
