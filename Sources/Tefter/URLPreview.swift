import Foundation
import Hummingbird
import PreviewTransport
import SwiftSoup

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
        guard let url = URL(string: address), ["https","http"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil, address.utf8.count <= 8192 else { throw HTTPError(.badRequest) }
        active += 1
        defer { active -= 1 }
        return try await Task.detached(priority: .utility) {
            var raw: UnsafeMutablePointer<CChar>?
            var length = 0
            guard tefter_fetch_html(address,&raw,&length) == 1, let raw else { throw HTTPError(.unprocessableContent,message: "Preview unavailable.") }
            defer { free(raw) }
            let html = String(decoding: UnsafeRawBufferPointer(start: raw,count: length),as: UTF8.self)
            let document = try SwiftSoup.parse(html,address)
            func value(_ selector: String, _ attribute: String) throws -> String? {
                guard let el = try document.select(selector).first() else { return nil }
                let text = try el.attr(attribute)
                return text.isEmpty ? nil : String(text.prefix(2048))
            }
            func link(_ value: String?) -> String? {
                guard let value, let url = URL(string: value,relativeTo: url)?.absoluteURL,
                      ["http","https"].contains(url.scheme ?? ""), url.user == nil, url.password == nil else { return nil }
                return url.absoluteString
            }
            return try LinkPreview(title: value("meta[property=og:title]","content") ?? String(document.title().prefix(512)),
                                   description: value("meta[name=description]","content") ?? value("meta[property=og:description]","content"),
                                   image: link(value("meta[property=og:image]","content")), favicon: link(value("link[rel~=icon]","href")),
                                   published: value("meta[property=article:published_time]","content"))
        }.value
    }
}

extension Identity {
    func enrich(_ doc: Document, space: String, user: String) async throws -> LinkPreview {
        guard let address = doc.url else { throw HTTPError(.badRequest) }
        let preview = try await previews.fetch(address)
        let root = try root(space,user: user)
        let existing = try document(doc.path,root: root)
        guard existing.document.revision == doc.revision else { throw HTTPError(.conflict) }
        var lines = existing.text.components(separatedBy:"\n")
        guard let end = lines.indices.dropFirst().first(where:{lines[$0].trimmingCharacters(in:.whitespacesAndNewlines) == "---"}) else { throw HTTPError(.conflict) }
        let header = lines[1..<end]
        var added = [String]()
        for (key,value) in [("previewTitle",preview.title),("description",preview.description),("image",preview.image),("favicon",preview.favicon),("published",preview.published)] {
            if let value, !value.isEmpty, !header.contains(where: {$0.hasPrefix(key + ":")}) {
                added.append(key + ": " + String(decoding:try JSONEncoder().encode(value),as:UTF8.self))
            }
        }
        if !added.isEmpty {
            lines.insert(contentsOf:added,at:end)
            let (dir,name) = try root.parent(doc.path)
            try dir.write(name,data:Data(lines.joined(separator:"\n").utf8),replacing:true)
            try audit(user,"preview",space + "/" + doc.path)
        }
        return preview
    }

    func preview(_ space: String, path: String, request: Request) async throws -> LinkPreview {
        let user = try session(request).user
        let doc = try document(path,root: root(space,user:user)).document
        return try await enrich(doc,space:space,user:user)
    }
}
