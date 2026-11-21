import Foundation
import Hummingbird
import PreviewTransport

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// Traverse each component through a pinned directory descriptor.
final class Directory {
  let fd: Int32
  private init(fd: Int32) { self.fd = fd }

  init(root: String) throws {
    fd = open(root, O_DIRECTORY | O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw Self.failure() }
  }

  deinit { close(fd) }

  static func failure() -> HTTPError {
    switch errno {
    case ENOENT: HTTPError(.notFound)
    case EEXIST, ENOTEMPTY: HTTPError(.conflict)
    case ELOOP, ENOTDIR, EINVAL: HTTPError(.badRequest)
    default: HTTPError(.internalServerError)
    }
  }

  static func components(_ path: String, internalPath: Bool = false) throws -> [String] {
    let parts = path.components(separatedBy: "/")
    guard path.utf8.count <= 4096, parts.count <= 64,
      parts.allSatisfy({
        !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && $0.utf8.count <= 255
          && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
          && !$0.hasPrefix(".tefter-tmp-") && $0.lowercased() != ".git"
          && (internalPath || $0.lowercased() != ".tefter")
      })
    else { throw HTTPError(.badRequest, message: "Invalid relative path.") }
    return parts
  }

  static func singleName(_ name: String) throws {
    guard name != ".", name != "..", !name.isEmpty, !name.contains("/"), !name.contains("\\"),
      !name.contains("\0")
    else { throw HTTPError(.badRequest) }
  }

  func directory(_ name: String, create: Bool = false) throws -> Directory {
    try Self.singleName(name)
    if create {
      if mkdirat(fd, name, 0o700) == 0 {
        try sync()
      } else if errno != EEXIST {
        throw Self.failure()
      }
    }
    let child = openat(fd, name, O_DIRECTORY | O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard child >= 0 else { throw Self.failure() }
    return Directory(fd: child)
  }

  func parent(_ path: String, internalPath: Bool = false) throws -> (Directory, String) {
    let parts = try Self.components(path, internalPath: internalPath)
    var dir = self
    for part in parts.dropLast() { dir = try dir.directory(part) }
    return (dir, parts.last!)
  }

  func sync() throws {
    guard fsync(fd) == 0 else { throw Self.failure() }
  }

  func info(_ name: String) throws -> stat? {
    try Self.singleName(name)
    var info = stat()
    if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) < 0 {
      if errno == ENOENT { return nil }
      throw Self.failure()
    }
    return info
  }

  func openRegular(_ name: String) throws -> (FileHandle, Int64) {
    try Self.singleName(name)
    let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard file >= 0 else { throw Self.failure() }
    let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
    var info = stat()
    guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
      throw HTTPError(.badRequest)
    }
    return (handle, Int64(info.st_size))
  }

  func read(_ name: String) throws -> Data {
    let (handle, size) = try openRegular(name)
    guard size <= 16 * 1024 * 1024 else { throw HTTPError(.contentTooLarge) }
    let data = try handle.read(upToCount: 16 * 1024 * 1024 + 1) ?? Data()
    guard data.count <= 16 * 1024 * 1024 else { throw HTTPError(.contentTooLarge) }
    return data
  }

  func write(_ name: String, data: Data, replacing: Bool) throws {
    try Self.singleName(name)
    guard data.count <= 16 * 1024 * 1024 else { throw HTTPError(.contentTooLarge) }
    let tmp = ".tefter-tmp-" + UUID().uuidString
    let file = openat(fd, tmp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard file >= 0 else { throw Self.failure() }
    defer { unlinkat(fd, tmp, 0) }
    let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
    try handle.write(contentsOf: data)
    try handle.synchronize()
    try handle.close()
    if replacing {
      guard renameat(fd, tmp, fd, name) == 0 else { throw Self.failure() }
    } else {
      guard tefter_rename_exclusive(fd, tmp, fd, name) == 0 else { throw Self.failure() }
    }
    try sync()
  }

  func entries() throws -> [String] {
    let copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard copy >= 0 else { throw Self.failure() }
    guard let stream = fdopendir(copy) else {
      close(copy)
      throw Self.failure()
    }
    defer { closedir(stream) }
    var names = [String]()
    while true {
      errno = 0
      guard let entry = readdir(stream) else {
        if errno != 0 { throw Self.failure() }
        return names.sorted()
      }
      let name = withUnsafeBytes(of: &entry.pointee.d_name) { bytes in
        String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
      }
      if name != "." && name != ".." { names.append(name) }
    }
  }
}
