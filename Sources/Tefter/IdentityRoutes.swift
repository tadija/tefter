import Foundation
import Hummingbird

struct Identifier: ResponseCodable { let id: String }
struct Spaces: ResponseCodable { let spaces: [Space] }

func registerIdentity(_ router: Router<BasicRequestContext>, _ identity: Identity) {
    let api = router.group("/api/v1")
    api.post("login") { request, context -> Response in
        guard request.headers[.init("X-Tefter-Login")!] == "1" else { throw HTTPError(.forbidden) }
        let credentials = try await request.decode(as: Credentials.self, context: context)
        let (token, login) = try await identity.login(credentials)
        var response = try login.response(from: request, context: context)
        response.headers[.cacheControl] = "no-store"
        response.headers[.setCookie] = "tefter=\(token); Path=/; Max-Age=43200; Secure; HttpOnly; SameSite=Strict"
        return response
    }
    api.get("session") { request, _ in try await identity.session(request) }
    api.post("logout") { request, _ -> Response in
        try await identity.logout(request)
        return Response(status: .noContent, headers: [.setCookie: "tefter=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Strict"])
    }
    api.post("users") { request, context in
        let session = try await identity.session(request)
        let credentials = try await request.decode(as: Credentials.self, context: context)
        return try await Identifier(id: identity.create(credentials, by: session.user))
    }
    api.get("spaces") { request, _ in
        try await Spaces(spaces: identity.accessible(identity.session(request).user))
    }
}

extension Identity {
    func logout(_ request: Request) throws {
        let login = try session(request)
        try db.transaction {
            try db.execute("DELETE FROM sessions WHERE token=?", [String(request.cookies["tefter"]!.value)])
            try audit(login.user,"logout",login.user)
        }
    }
}
