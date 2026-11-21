import Foundation
import Hummingbird

struct Comment: Codable {
    let id: String
    let entity: String
    let author: String
    let parent: String?
    let created: String
    var updated: String
    var body: String
    var deleted: Bool
}
struct ThreadFile: ResponseCodable {
    var version = 1
    var revision = "initial"
    var comments: [Comment] = []
}
struct CommentChange: Decodable {
    let path: String
    let revision: String
    let id: String?
    let parent: String?
    let body: String?
}
struct Hit: ResponseCodable { let space: String; let path: String; let title: String; let type: String }
struct Results: ResponseCodable { let hits: [Hit] }
struct SearchInput: Decodable {
    let query: String
    let allSpaces: Bool?
    let type: String?
    let directory: String?
    let author: String?
    let since: String?
    let until: String?
    let offset: Int?
}

extension Identity {
    func thread(_ id: String?, root: Directory) throws -> ThreadFile {
        guard let id else { return ThreadFile() }
        let dir = try metadata(root).directory("comments",create: true)
        let thread = try load(ThreadFile.self,from: dir,name: id + ".json",initial: ThreadFile())
        guard thread.version == 1 else { throw HTTPError(.conflict) }
        return thread
    }

    func comments(_ space: String, path: String, request: Request) throws -> ThreadFile {
        let root = try root(space,user: session(request).user)
        return try thread(document(path,root: root).document.id,root: root)
    }

    func comment(_ space: String, change: CommentChange, request: Request) throws -> ThreadFile {
        let user = try session(request).user
        let root = try root(space,user: user)
        let doc = try document(change.path,root: root,identify: true).document
        guard let id = doc.id else { throw HTTPError(.conflict) }
        var thread = try thread(id,root: root)
        guard thread.revision == change.revision else { throw HTTPError(.conflict) }
        if let body = change.body, body.isEmpty || body.utf8.count > 65536 { throw HTTPError(.badRequest) }
        let now = ISO8601DateFormatter().string(from: Date())
        if let edit = change.id {
            guard let i = thread.comments.firstIndex(where: { $0.id == edit && !$0.deleted }) else { throw HTTPError(.notFound) }
            guard thread.comments[i].author == user else { throw HTTPError(.forbidden) }
            thread.comments[i].body = change.body ?? ""
            thread.comments[i].deleted = change.body == nil
            thread.comments[i].updated = now
        } else {
            guard let body = change.body else { throw HTTPError(.badRequest) }
            if let parent = change.parent, !thread.comments.contains(where: { $0.id == parent && $0.parent == nil && !$0.deleted }) { throw HTTPError(.badRequest) }
            thread.comments.append(.init(id: UUID().uuidString,entity: id,author: user,parent: change.parent,created: now,updated: now,body: body,deleted: false))
        }
        thread.revision = UUID().uuidString
        try save(thread,to: metadata(root).directory("comments",create: true),name: id + ".json")
        try audit(user,"comment",space + "/" + id)
        return thread
    }

    func rebuild(_ space: String, user: String) throws {
        let root = try root(space,user: user)
        let tree = try scan(root)
        try db.transaction {
            try db.execute("CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(space UNINDEXED,path,title,kind UNINDEXED,author UNINDEXED,date UNINDEXED,body)")
            try db.execute("DELETE FROM search WHERE space=?", [space])
            for doc in tree.documents {
                let (dir,name) = try root.parent(doc.path)
                let text = String(decoding: try dir.read(name),as: UTF8.self)
                let insert = "INSERT INTO search VALUES(?,?,?,?,?,?,?)"
                let changed = try dir.info(name).map { info -> String in
                    #if canImport(Darwin)
                    let seconds = info.st_mtimespec.tv_sec
                    #else
                    let seconds = info.st_mtim.tv_sec
                    #endif
                    return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(seconds)))
                } ?? ""
                try db.execute(insert,[space,doc.path,doc.title,doc.type,"",changed,text])
                for c in try thread(doc.id,root: root).comments where !c.deleted {
                    try db.execute(insert,[space,doc.path,doc.title,doc.type,c.author,c.created,c.body])
                }
            }
        }
    }

    func search(_ space: String, input: SearchInput, request: Request) throws -> Results {
        let user = try session(request).user
        _ = try access(space,user: user)
        let spaces = try input.allSpaces == true ? accessible(user).map(\.id) : [space]
        guard !input.query.isEmpty, input.query.utf8.count <= 500 else { throw HTTPError(.badRequest) }
        for id in spaces { try rebuild(id,user: user) }
        let slots = spaces.map { _ in "?" }.joined(separator: ",")
        var conditions = ["space IN (" + slots + ")", "search MATCH ?"]
        var args = spaces + ["\"" + input.query.replacingOccurrences(of: "\"",with: "\"\"") + "\""]
        for (field,value) in [("kind=?",input.type),("author=?",input.author),("date>=?",input.since),("date<=?",input.until)] {
            if let value, !value.isEmpty { conditions.append(field); args.append(value) }
        }
        if let dir = input.directory, !dir.isEmpty {
            _ = try Directory.components(dir)
            conditions.append("instr(path,?)=1"); args.append(dir + "/")
        }
        args.append(String(max(0,input.offset ?? 0)))
        let rows = try db.rows("SELECT DISTINCT space,path,title,kind FROM search WHERE " + conditions.joined(separator: " AND ") + " ORDER BY space,path LIMIT 100 OFFSET ?",args)
        return Results(hits: rows.map { Hit(space: $0["space"]!,path: $0["path"]!,title: $0["title"]!,type: $0["kind"]!) })
    }
}

func registerCollaboration(_ router: Router<BasicRequestContext>, _ identity: Identity) {
    let group = router.group("/api/v1/spaces/:space")
    group.get("export") { req,ctx in try await identity.export(ctx.parameters.require("space"),folder: req.uri.queryParameters.get("folder"),request: req) }
    group.get("comments") { req,ctx in try await identity.comments(ctx.parameters.require("space"),path: req.uri.queryParameters.require("path"),request: req) }
    group.post("comments") { req,ctx in
        let change = try await req.decode(as: CommentChange.self,context: ctx)
        return try await identity.comment(ctx.parameters.require("space"),change: change,request: req)
    }
    group.post("search") { req,ctx in
        let input = try await req.decode(as: SearchInput.self,context: ctx)
        return try await identity.search(ctx.parameters.require("space"),input: input,request: req)
    }
    group.post("rescan") { req,ctx -> HTTPResponse.Status in
        try await identity.rebuild(ctx.parameters.require("space"),user: identity.session(req).user)
        return .noContent
    }
}
