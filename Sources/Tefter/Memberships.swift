import Hummingbird
import Foundation

struct Named: ResponseCodable { let id: String; let name: String }
struct OrgList: ResponseCodable { let organizations: [Named] }
struct People: ResponseCodable { let people: [Named] }
private struct NameInput: Decodable { let name: String }
private struct MemberInput: Decodable { let user: String; let role: String? }

extension Identity {
    func organizations(user: String) throws -> OrgList {
        OrgList(organizations: try db.rows("SELECT id,name FROM organizations JOIN org_members ON org=id WHERE user=? ORDER BY name,id", [user]).map { Named(id: $0["id"]!, name: $0["name"]!) })
    }

    func createOrg(_ name: String, user: String) throws -> Identifier {
        try requireAdmin(user)
        guard !name.isEmpty, name.count <= 200 else { throw HTTPError(.badRequest) }
        let id = UUID().uuidString
        return try db.transaction {
            try db.execute("INSERT INTO organizations VALUES(?,?)", [id,name])
            try db.execute("INSERT INTO org_members VALUES(?,?)", [id,user])
            try audit(user,"create-organization",id)
            return Identifier(id: id)
        }
    }

    func changeOrg(_ org: String, target: String, remove: Bool, user: String) throws {
        try requireAdmin(user)
        try db.transaction {
            if remove {
                try db.execute("DELETE FROM members WHERE user=? AND space IN (SELECT id FROM spaces WHERE org=?)", [target,org])
                try db.execute("DELETE FROM org_members WHERE org=? AND user=?", [org,target])
            } else {
                try db.execute("INSERT OR IGNORE INTO org_members VALUES(?,?)", [org,target])
            }
            try audit(user,remove ? "remove-org-member" : "add-org-member",org + "/" + target)
        }
    }

    func createSpace(_ org: String, name: String, user: String) throws -> Identifier {
        try requireAdmin(user)
        guard !name.isEmpty, name.count <= 200 else { throw HTTPError(.badRequest) }
        let id = UUID().uuidString
        return try db.transaction {
            guard !(try db.rows("SELECT user FROM org_members WHERE org=? AND user=?", [org,user])).isEmpty else { throw HTTPError(.forbidden) }
            try db.execute("INSERT INTO spaces(id,name,org) VALUES(?,?,?)", [id,name,org])
            try db.execute("INSERT INTO members VALUES(?,?,'owner')", [id,user])
            try audit(user,"create-space",id)
            return Identifier(id: id)
        }
    }

    func access(_ id: String, user: String) throws -> Space {
        guard let space = try accessible(user).first(where: { $0.id == id }) else { throw HTTPError(.notFound) }
        return space
    }

    func changeSpace(_ id: String, target: String, role: String?, user: String) throws {
        let space = try access(id,user: user)
        guard space.role != "member",
              let org = try db.rows("SELECT org FROM spaces WHERE id=?", [id]).first?["org"],
              !(try db.rows("SELECT user FROM org_members WHERE user=? AND org=?", [target,org])).isEmpty,
              try db.rows("SELECT role FROM members WHERE user=? AND space=?", [target,id]).first?["role"] != "owner" else { throw HTTPError(.forbidden) }
        try db.transaction {
            if let role {
                guard ["member","admin"].contains(role) else { throw HTTPError(.badRequest) }
                try db.execute("INSERT INTO members VALUES(?,?,?) ON CONFLICT(space,user) DO UPDATE SET role=excluded.role", [id,target,role])
            } else {
                try db.execute("DELETE FROM members WHERE space=? AND user=?", [id,target])
            }
            try audit(user,"change-space-member",id + "/" + target)
        }
    }

    func people(_ id: String, user: String) throws -> People {
        _ = try access(id,user: user)
        try syncProfiles(id)
        return People(people: try db.rows("SELECT users.id,email FROM users JOIN members ON members.user=users.id WHERE space=? ORDER BY email", [id]).map { Named(id: $0["id"]!, name: $0["email"]!) })
    }
}

func registerMemberships(_ router: Router<BasicRequestContext>, _ identity: Identity) {
    let api = router.group("/api/v1")
    api.get("organizations") { request, _ in try await identity.organizations(user: identity.session(request).user) }
    api.post("organizations") { request, context in
        let input = try await request.decode(as: NameInput.self, context: context)
        return try await identity.createOrg(input.name, user: identity.session(request).user)
    }
    for remove in [false,true] {
        let method: HTTPRequest.Method = remove ? .delete : .put
        api.on("organizations/:org/members", method: method) { request, context -> HTTPResponse.Status in
            let input = try await request.decode(as: MemberInput.self, context: context)
            try await identity.changeOrg(context.parameters.require("org"), target: input.user, remove: remove, user: identity.session(request).user)
            return .noContent
        }
        api.on("spaces/:space/members", method: method) { request, context -> HTTPResponse.Status in
            let input = try await request.decode(as: MemberInput.self, context: context)
            try await identity.changeSpace(context.parameters.require("space"), target: input.user, role: remove ? nil : input.role ?? "member", user: identity.session(request).user)
            return .noContent
        }
    }
    api.post("organizations/:org/spaces") { request, context in
        let input = try await request.decode(as: NameInput.self, context: context)
        return try await identity.createSpace(context.parameters.require("org"), name: input.name, user: identity.session(request).user)
    }
    api.get("spaces/:space/people") { request, context in
        try await identity.people(context.parameters.require("space"), user: identity.session(request).user)
    }
}
