import Crypto
import Foundation
import Hummingbird
import Yams

struct Document: ResponseCodable {
    var path: String
    var revision: String
    var id: String?
    var type: String
    var title: String
    var status: String?
    var assignee: String?
    var sprint: String?
    var release: String?
    var url: String?
}
struct Tree: ResponseCodable { var directories: [String]; var documents: [Document] }
struct FileText: ResponseCodable { let text: String; let document: Document }
struct FileChange: Decodable { let path: String; let text: String?; let revision: String?; let destination: String? }
struct Manifest: Codable {
    var version = 1
    struct Entry: Codable { var id: String; var path: String; var revision: String }
    var documents: [Entry] = []
}

extension Identity {
    func tree(_ space: String, request: Request) throws -> Tree {
        try scan(root(space,user: session(request).user))
    }

    func file(_ space: String, path: String, request: Request) throws -> FileText {
        try document(path,root: root(space,user: session(request).user))
    }

    func root(_ space: String, user: String) throws -> Directory {
        _ = try access(space,user: user)
        return try Directory(root: home.path).directory("content").directory("spaces").directory(space,create: true)
    }

    func metadata(_ root: Directory) throws -> Directory { try root.directory(".tefter",create: true) }

    func load<T: Decodable>(_ type: T.Type, from dir: Directory, name: String, initial: T) throws -> T {
        guard try dir.info(name) != nil else { return initial }
        return try JSONDecoder().decode(type,from: dir.read(name))
    }

    func save<T: Encodable>(_ value: T, to dir: Directory, name: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
        try dir.write(name,data: encoder.encode(value),replacing: true)
    }

    func describe(_ path: String, data: Data) throws -> FileText {
        guard let text = String(data: data,encoding: .utf8) else { throw HTTPError(.unprocessableContent) }
        let rev = SHA256.hash(data: data).map { String(format:"%02x",$0) }.joined()
        var doc = Document(path: path, revision: rev, type: "doc", title: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
        let normalized = text.replacingOccurrences(of: "\r\n",with: "\n")
        if normalized.hasPrefix("---\n"), let end = normalized.dropFirst(4).range(of: "\n---\n"),
           let fields = try? Yams.load(yaml: String(normalized[normalized.index(normalized.startIndex,offsetBy: 4)..<end.lowerBound])) as? [String: Any],
           let kind = fields["type"] as? String, ["task","sprint","release","url"].contains(kind) {
            guard let id = fields["id"] as? String, UUID(uuidString: id) != nil else {
                throw HTTPError(.conflict,message: "Typed file requires a UUID at " + path)
            }
            doc.id = id.lowercased()
            doc.type = kind
            doc.title = fields["title"] as? String ?? doc.title
            doc.status = fields["status"] as? String
            doc.assignee = fields["assignee"] as? String
            doc.sprint = fields["sprint"] as? String
            doc.release = fields["release"] as? String
            doc.url = fields["url"] as? String
            if kind == "task", !["todo","in-progress","done"].contains(doc.status ?? "") { throw HTTPError(.unprocessableContent) }
            if kind == "url", !["https","http"].contains(URL(string: doc.url ?? "")?.scheme?.lowercased() ?? "") { throw HTTPError(.unprocessableContent) }
        }
        return FileText(text: text,document: doc)
    }

    func scan(_ root: Directory) throws -> Tree {
        var tree = Tree(directories: [],documents: [])
        func visit(_ dir: Directory, prefix: String) throws {
            for name in try dir.entries() where ![".tefter",".git"].contains(name.lowercased()) && !name.hasPrefix(".tefter-tmp-") {
                let path = prefix + name
                _ = try Directory.components(path)
                guard let info = try dir.info(name) else { continue }
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    tree.directories.append(path)
                    try visit(dir.directory(name),prefix: path + "/")
                case S_IFREG:
                    if name.lowercased().hasSuffix(".md") { tree.documents.append(try describe(path,data: dir.read(name)).document) }
                default: throw HTTPError(.conflict,message: "Unsupported filesystem object at " + path)
                }
            }
        }
        try visit(root,prefix: "")
        let meta = try metadata(root)
        var manifest = try load(Manifest.self,from: meta,name: "entities.json",initial: Manifest())
        guard manifest.version == 1 else { throw HTTPError(.conflict) }
        var changed = false
        var ids = Set<String>()
        for i in manifest.documents.indices {
            let item = manifest.documents[i]
            let indexes = tree.documents.indices.filter { tree.documents[$0].path == item.path }
            let matches = indexes.isEmpty ? tree.documents.indices.filter { tree.documents[$0].revision == item.revision && tree.documents[$0].type == "doc" } : indexes
            guard matches.count <= 1 else { throw HTTPError(.conflict,message: "Ambiguous move for " + item.path) }
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
            if let id = doc.id, !ids.insert(id).inserted { throw HTTPError(.conflict,message: "Duplicate ID at " + doc.path) }
        }
        if changed { try save(manifest,to: meta,name: "entities.json") }
        return tree
    }

    func document(_ path: String, root: Directory, identify: Bool = false) throws -> FileText {
        let (dir,name) = try root.parent(path)
        guard name.lowercased().hasSuffix(".md") else { throw HTTPError(.badRequest) }
        guard var doc = try scan(root).documents.first(where: { $0.path == path }) else { throw HTTPError(.notFound) }
        let result = try describe(path,data: dir.read(name))
        guard result.document.revision == doc.revision else { throw HTTPError(.conflict) }
        if identify && doc.id == nil {
            let meta = try metadata(root)
            var manifest = try load(Manifest.self,from: meta,name: "entities.json",initial: Manifest())
            let id = UUID().uuidString.lowercased()
            manifest.documents.append(.init(id: id,path: path,revision: doc.revision))
            try save(manifest,to: meta,name: "entities.json")
            doc.id = id
        }
        return FileText(text: result.text,document: doc)
    }

    func mutate(_ space: String, user: String, change: FileChange, action: String) throws {
        let root = try root(space,user: user)
        let (dir,name) = try root.parent(change.path)
        if action == "directory" {
            guard mkdirat(dir.fd,name,0o700) == 0 else { throw Directory.failure() }
            try dir.sync()
        } else {
            guard name.lowercased().hasSuffix(".md") else { throw HTTPError(.badRequest) }
            let tree = try scan(root)
            let old = tree.documents.first { $0.path == change.path }
            guard change.revision == old?.revision else { throw HTTPError(.conflict,message: "The file has changed.") }
            switch action {
            case "write":
                guard let text = change.text else { throw HTTPError(.badRequest) }
                let data = Data(text.utf8)
                let doc = try describe(change.path,data: data).document
                if old?.type != nil && old?.type != doc.type { throw HTTPError(.conflict) }
                if old?.type != "doc", let previous = old?.id, previous != doc.id { throw HTTPError(.conflict) }
                if let id = doc.id, tree.documents.contains(where: { $0.path != change.path && $0.id == id }) { throw HTTPError(.conflict) }
                for (reference,kind) in [(doc.sprint,"sprint"),(doc.release,"release")] {
                    if let reference, !tree.documents.contains(where: { $0.id == reference && $0.type == kind }) { throw HTTPError(.unprocessableContent) }
                }
                if let assignee = doc.assignee, !(try people(space,user: user).people.contains { $0.id == assignee }) { throw HTTPError(.unprocessableContent) }
                try dir.write(name,data: data,replacing: old != nil)
                if doc.type == "url", doc.url != old?.url {
                    Task { _ = try? await enrich(doc,space:space,user:user) }
                }
            case "move":
                guard old != nil, let dest = change.destination, dest.lowercased().hasSuffix(".md") else { throw HTTPError(.badRequest) }
                let (target,newName) = try root.parent(dest)
                guard try target.info(newName) == nil else { throw HTTPError(.conflict) }
                guard renameat(dir.fd,name,target.fd,newName) == 0 else { throw Directory.failure() }
                try target.sync()
                try dir.sync()
            case "delete":
                guard old != nil else { throw HTTPError(.notFound) }
                guard unlinkat(dir.fd,name,0) == 0 else { throw Directory.failure() }
                try dir.sync()
                if old?.type == "doc", let id = old?.id {
                    let meta = try metadata(root)
                    var manifest = try load(Manifest.self,from: meta,name: "entities.json",initial: Manifest())
                    manifest.documents.removeAll { $0.id == id }
                    try save(manifest,to: meta,name: "entities.json")
                }
            default: throw HTTPError(.badRequest)
            }
        }
        try audit(user,action,space + "/" + change.path)
    }
}

func registerDocuments(_ router: Router<BasicRequestContext>, _ identity: Identity) {
    let group = router.group("/api/v1/spaces/:space")
    group.post("preview") { req,ctx in try await identity.preview(ctx.parameters.require("space"),path:req.uri.queryParameters.require("path"),request:req) }
    group.get("tree") { req,ctx in try await identity.tree(ctx.parameters.require("space"),request: req) }
    group.get("file") { req,ctx in
        try await identity.file(ctx.parameters.require("space"),path: req.uri.queryParameters.require("path"),request: req)
    }
    for action in ["directory","write","delete","move"] {
        group.post(RouterPath(action)) { req,ctx -> HTTPResponse.Status in
            let change = try await req.decode(as: FileChange.self,context: ctx)
            try await identity.mutate(ctx.parameters.require("space"),user: identity.session(req).user,change: change,action: action)
            return .noContent
        }
    }
}
