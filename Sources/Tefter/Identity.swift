import CArgon2
import Foundation
import Hummingbird

#if os(Linux)
  import Glibc
#else
  import Darwin
#endif

struct Credentials: Decodable {
  let email: String
  let password: String
}

struct Login: ResponseCodable {
  let user: String
  let csrf: String
}

struct Space: ResponseCodable {
  let id: String
  let name: String
  let role: String
}

actor Identity {
  var audioPeers: [String: AudioPeer] = [:]
  var gitOperations = Set<String>()
  var runningExecutions = 0
  var socketCounts: [String: Int] = [:]
  var indexedSpaces = Set<String>()
  let previews = PreviewWorker()
  let settings: [String: String]
  let db: Database
  let home: URL
  private let dummyHash: String

  init(home: URL, settings: [String: String]) throws {
    self.settings = settings
    self.home = home
    self.db = try Database(path: home.appendingPathComponent("runtime/tefter.sqlite").path)
    self.dummyHash = try Self.hash(Self.token())
    let schema = try db.rows("PRAGMA user_version").first?["user_version"]
    guard schema == "0" || schema == "1" || schema == "2" || schema == "3" else {
      throw HTTPError(.conflict, message: "Unsupported operational schema version.")
    }
    for sql in [
      "CREATE TABLE IF NOT EXISTS users(id TEXT PRIMARY KEY,email TEXT UNIQUE NOT NULL,password TEXT NOT NULL,admin INTEGER NOT NULL DEFAULT 0)",
      "CREATE TABLE IF NOT EXISTS organizations(id TEXT PRIMARY KEY,name TEXT NOT NULL)",
      "CREATE TABLE IF NOT EXISTS org_members(org TEXT REFERENCES organizations,user TEXT REFERENCES users,PRIMARY KEY(org,user))",
      "CREATE TABLE IF NOT EXISTS spaces(id TEXT PRIMARY KEY,name TEXT NOT NULL,person TEXT REFERENCES users,org TEXT REFERENCES organizations,CHECK ((person IS NULL) != (org IS NULL)))",
      "CREATE TABLE IF NOT EXISTS members(space TEXT REFERENCES spaces,user TEXT REFERENCES users,role TEXT NOT NULL CHECK(role IN ('owner','admin','member')),PRIMARY KEY(space,user))",
      "CREATE TABLE IF NOT EXISTS sessions(token TEXT PRIMARY KEY,user TEXT NOT NULL REFERENCES users,csrf TEXT NOT NULL,expires INTEGER NOT NULL)",
      "CREATE TABLE IF NOT EXISTS attempts(email TEXT PRIMARY KEY,count INTEGER NOT NULL,start INTEGER NOT NULL)",
      "CREATE TABLE IF NOT EXISTS recovery(user TEXT PRIMARY KEY REFERENCES users,digest TEXT UNIQUE NOT NULL,expires INTEGER NOT NULL)",
      "CREATE TABLE IF NOT EXISTS audit(time INTEGER NOT NULL DEFAULT (unixepoch()),actor TEXT NOT NULL,event TEXT NOT NULL,target TEXT NOT NULL)",
    ] { try db.execute(sql) }
    try db.execute("CREATE TABLE IF NOT EXISTS agents(id TEXT PRIMARY KEY,name TEXT NOT NULL,digest TEXT UNIQUE NOT NULL)")
    try db.execute("CREATE TABLE IF NOT EXISTS agent_grants(space TEXT REFERENCES spaces,id TEXT REFERENCES agents,PRIMARY KEY(space,id))")
    try db.execute("CREATE TABLE IF NOT EXISTS channel_cursors(space TEXT REFERENCES spaces,channel TEXT,sequence INTEGER NOT NULL,PRIMARY KEY(space,channel))")
    try db.execute("CREATE TABLE IF NOT EXISTS shares(id TEXT PRIMARY KEY,source TEXT REFERENCES spaces,entity TEXT NOT NULL,target TEXT REFERENCES spaces,copies INTEGER NOT NULL)")
    try db.execute("CREATE TABLE IF NOT EXISTS repo_ownership(id TEXT PRIMARY KEY,space TEXT REFERENCES spaces)")
    try db.execute("CREATE TABLE IF NOT EXISTS repo_grants(repo TEXT REFERENCES repo_ownership,space TEXT REFERENCES spaces,PRIMARY KEY(repo,space))")
    try db.execute("CREATE TABLE IF NOT EXISTS harness_connections(id TEXT PRIMARY KEY,name TEXT NOT NULL,executable TEXT NOT NULL,credential_home TEXT NOT NULL,adhoc INTEGER NOT NULL)")
    try db.execute("CREATE TABLE IF NOT EXISTS execution_grants(connection TEXT REFERENCES harness_connections,space TEXT REFERENCES spaces,user TEXT REFERENCES users,PRIMARY KEY(connection,space,user))")
    try db.execute("CREATE TABLE IF NOT EXISTS executions(id TEXT PRIMARY KEY,space TEXT REFERENCES spaces,connection TEXT REFERENCES harness_connections)")
    try db.execute("PRAGMA user_version=3")
  }

  static func token() -> String {
    var rng = SystemRandomNumberGenerator()
    return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &rng))
    }.joined()
  }

  static func hash(_ password: String) throws -> String {
    guard password.utf8.count >= 12, password.utf8.count <= 1024, !password.contains("\0") else {
      throw HTTPError(.badRequest, message: "Use a password between 12 and 1024 UTF-8 bytes.")
    }
    let salt = Array(UUID().uuidString.utf8)
    var out = [CChar](repeating: 0, count: 256)
    let code = argon2id_hash_encoded(
      3, 65536, 1, password, password.utf8.count, salt, salt.count, 32, &out, out.count)
    guard code == ARGON2_OK.rawValue else { throw HTTPError(.internalServerError) }
    return String(
      decoding: out.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  func audit(_ actor: String, _ event: String, _ target: String) throws {
    try db.execute("INSERT INTO audit(actor,event,target) VALUES(?,?,?)", [actor, event, target])
  }

  func create(_ credentials: Credentials, by actor: String?) throws -> String {
    if let actor {
      try requireAdmin(actor)
    } else if !(try db.rows("SELECT id FROM users LIMIT 1")).isEmpty {
      throw HTTPError(.conflict)
    }
    let email = credentials.email.lowercased()
    guard Self.emailValid(email) else { throw HTTPError(.badRequest) }
    let password = try Self.hash(credentials.password)
    let id = UUID().uuidString
    let space = UUID().uuidString
    return try db.transaction {
      guard try db.rows("SELECT id FROM users WHERE email=?", [email]).isEmpty else {
        throw HTTPError(.conflict)
      }
      try db.execute(
        "INSERT INTO users VALUES(?,?,?,?)", [id, email, password, actor == nil ? "1" : "0"])
      try db.execute("INSERT INTO spaces(id,name,person) VALUES(?,'Personal',?)", [space, id])
      try db.execute("INSERT INTO members VALUES(?,?,'owner')", [space, id])
      try audit(actor ?? "offline", "create-user", id)
      return id
    }
  }

  func requireAdmin(_ user: String) throws {
    guard !(try db.rows("SELECT id FROM users WHERE id=? AND admin=1", [user])).isEmpty else {
      throw HTTPError(.forbidden)
    }
  }

  func login(_ credentials: Credentials) throws -> (String, Login) {
    let email = credentials.email.lowercased()
    guard email.utf8.count <= 254, credentials.password.utf8.count <= 1024 else {
      throw HTTPError(.unauthorized)
    }
    try db.execute("DELETE FROM attempts WHERE start < unixepoch()-900")
    if let count = try db.rows("SELECT count FROM attempts WHERE email=?", [email]).first?["count"],
      Int(count) ?? 0 >= 8
    {
      throw HTTPError(.tooManyRequests)
    }
    let record = try db.rows("SELECT id,password FROM users WHERE email=?", [email]).first
    guard
      argon2id_verify(
        record?["password"] ?? dummyHash, credentials.password, credentials.password.utf8.count)
        == ARGON2_OK.rawValue,
      let id = record?["id"]
    else {
      try db.execute(
        "INSERT INTO attempts VALUES(?,1,unixepoch()) ON CONFLICT(email) DO UPDATE SET count=count+1",
        [email])
      throw HTTPError(.unauthorized)
    }
    let token = Self.token()
    let login = Login(user: id, csrf: Self.token())
    try db.transaction {
      try db.execute("DELETE FROM attempts WHERE email=?", [email])
      try db.execute("DELETE FROM sessions WHERE expires<=unixepoch()")
      try db.execute(
        "INSERT INTO sessions VALUES(?,?,?,unixepoch()+43200)", [token, id, login.csrf])
      try audit(id, "login", id)
    }
    return (token, login)
  }

  func session(_ request: Request) throws -> Login {
    guard let token = request.cookies["tefter"]?.value,
      let row = try db.rows(
        "SELECT user,csrf FROM sessions WHERE token=? AND expires>unixepoch()", [String(token)]
      ).first,
      let user = row["user"], let csrf = row["csrf"]
    else { throw HTTPError(.unauthorized) }
    if request.method != .get && request.headers[.init("X-CSRF-Token")!] != csrf {
      throw HTTPError(.forbidden)
    }
    return Login(user: user, csrf: csrf)
  }

  func reset(email: String, password: String, actor: String) throws {
    let hash = try Self.hash(password)
    guard
      let user = try db.rows("SELECT id FROM users WHERE email=?", [email.lowercased()]).first?[
        "id"]
    else { throw HTTPError(.notFound) }
    try db.transaction {
      try db.execute("UPDATE users SET password=? WHERE id=?", [hash, user])
      try db.execute("DELETE FROM sessions WHERE user=?", [user])
      try db.execute("DELETE FROM recovery WHERE user=?", [user])
      try db.execute("DELETE FROM attempts WHERE email=?", [email.lowercased()])
      try audit(actor, "reset-password", user)
    }
  }

  func accessible(_ user: String) throws -> [Space] {
    try db.rows(
      """
      SELECT spaces.id,name,role FROM spaces JOIN members ON members.space=spaces.id
      WHERE members.user=? AND (person=? OR EXISTS(SELECT 1 FROM org_members WHERE org_members.org=spaces.org AND org_members.user=?))
      ORDER BY name,spaces.id
      """, [user, user, user]
    ).map { Space(id: $0["id"]!, name: $0["name"]!, role: $0["role"]!) }
  }
}
