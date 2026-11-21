import Foundation
import Hummingbird
import PreviewTransport
import SwiftSoup

#if os(Linux)
  import Glibc
#else
  import Darwin
#endif

struct LinkPreview: ResponseCodable {
  var title: String?
  var description: String?
  var image: String?
  var favicon: String?
  var published: String?
}

/// Restrict outstanding transfers and release the workspace actor while fetching.
actor PreviewWorker {
  private var active = 0
  func fetch(_ address: String) async throws -> LinkPreview {
    guard active < 4 else { throw HTTPError(.tooManyRequests) }
    guard let url = URL(string: address),
      ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
      url.host != nil, url.user == nil, url.password == nil, address.utf8.count <= 8192
    else { throw HTTPError(.badRequest) }
    active += 1
    defer { active -= 1 }
    return try await Task.detached(priority: .utility) {
      var raw: UnsafeMutablePointer<CChar>?
      var length = 0
      var effective: UnsafeMutablePointer<CChar>?
      guard tefter_fetch(address, 0, &raw, &length, &effective) == 1, let raw else {
        throw HTTPError(.unprocessableContent, message: "Preview unavailable.")
      }
      defer {
        free(raw)
        free(effective)
      }
      let finalURL = effective.flatMap { URL(string: String(cString: $0)) } ?? url
      let html = String(decoding: UnsafeRawBufferPointer(start: raw, count: length), as: UTF8.self)
      let document = try SwiftSoup.parse(html, address)
      func value(_ selector: String, _ attribute: String) throws -> String? {
        guard let el = try document.select(selector).first() else { return nil }
        let text = try el.attr(attribute)
        return text.isEmpty ? nil : String(text.prefix(2048))
      }
      func link(_ value: String?) -> String? {
        guard let value, let url = URL(string: value, relativeTo: finalURL)?.absoluteURL,
          ["http", "https"].contains(url.scheme ?? ""), url.user == nil, url.password == nil
        else { return nil }
        return url.absoluteString
      }
      return try LinkPreview(
        title: value("meta[property=og:title]", "content") ?? String(document.title().prefix(512)),
        description: value("meta[name=description]", "content")
          ?? value("meta[property=og:description]", "content"),
        image: link(value("meta[property=og:image]", "content")),
        favicon: link(value("link[rel~=icon]", "href")),
        published: value("meta[property=article:published_time]", "content"))
    }.value
  }
  func image(_ address: String) async throws -> Response {
    guard active < 4 else { throw HTTPError(.tooManyRequests) }
    active += 1
    defer { active -= 1 }
    return try await Task.detached(priority: .utility) {
      var raw: UnsafeMutablePointer<CChar>?
      var effective: UnsafeMutablePointer<CChar>?
      var count = 0
      guard tefter_fetch(address, 1, &raw, &count, &effective) == 1, let raw else {
        throw HTTPError(.notFound)
      }
      defer {
        free(raw)
        free(effective)
      }
      let data = Data(bytes: raw, count: count)
      let type: String
      if data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) {
        type = "image/png"
      } else if data.starts(with: [255, 216, 255]) {
        type = "image/jpeg"
      } else if data.starts(with: Data("GIF89a".utf8)) || data.starts(with: Data("GIF87a".utf8)) {
        type = "image/gif"
      } else if data.starts(with: [0, 0, 1, 0]) {
        type = "image/x-icon"
      } else if data.starts(with: Data("RIFF".utf8))
        && data.dropFirst(8).starts(with: Data("WEBP".utf8))
      {
        type = "image/webp"
      } else {
        throw HTTPError(.unsupportedMediaType)
      }
      return Response(
        status: .ok,
        headers: [
          .contentType: type, .cacheControl: "private, no-store",
          .init("X-Content-Type-Options")!: "nosniff",
        ], body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }.value
  }

}

extension Identity {
  func enrich(_ doc: Document, space: String, user: String) async throws -> LinkPreview {
    guard let address = doc.url else { throw HTTPError(.badRequest) }
    let preview = try await previews.fetch(address)
    let root = try root(space, user: user)
    let existing = try document(doc.path, root: root)
    guard existing.document.revision == doc.revision else { throw HTTPError(.conflict) }
    var lines = existing.text.components(separatedBy: "\n")
    guard
      let end = lines.indices.dropFirst().first(where: {
        lines[$0].trimmingCharacters(in: .whitespacesAndNewlines) == "---"
      })
    else { throw HTTPError(.conflict) }
    let header = lines[1..<end]
    var added = [String]()
    for (key, value) in [
      ("previewTitle", preview.title), ("description", preview.description),
      ("image", preview.image), ("favicon", preview.favicon), ("published", preview.published),
    ] {
      if let value, !value.isEmpty,
        !header.contains(where: {
          $0.hasPrefix(key + ":") && ![key + ": ", key + ":", key + ": \"\""].contains($0)
        })
      {
        // Replace an explicitly empty value without introducing duplicate YAML keys.
        if let i = lines[1..<end].firstIndex(where: { $0.hasPrefix(key + ":") }) {
          lines[i] = key + ": " + String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
          continue
        }
        added.append(key + ": " + String(decoding: try JSONEncoder().encode(value), as: UTF8.self))
      }
    }
    if !added.isEmpty || lines.joined(separator: "\n") != existing.text {
      lines.insert(contentsOf: added, at: end)
      let (dir, name) = try root.parent(doc.path)
      try dir.write(name, data: Data(lines.joined(separator: "\n").utf8), replacing: true)
      indexedSpaces.remove(space)
      try audit(user, "preview", space + "/" + doc.path)
    }
    return preview
  }

  func image(_ space: String, path: String, kind: String, request: Request) async throws -> Response
  {
    let user = try session(request).user
    let doc = try document(path, root: root(space, user: user)).document
    guard let address = kind == "favicon" ? doc.favicon : doc.image, doc.type == "url" else {
      throw HTTPError(.notFound)
    }
    let response = try await previews.image(address)
    _ = try access(space, user: session(request).user)
    return response
  }

  func preview(_ space: String, path: String, request: Request) async throws -> LinkPreview {
    let user = try session(request).user
    let doc = try document(path, root: root(space, user: user)).document
    return try await enrich(doc, space: space, user: user)
  }
}
