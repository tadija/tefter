import CArgon2
import Crypto
import Foundation
import Hummingbird
import PreviewTransport

private struct ChangePassword: Decodable {
  let current: String
  let password: String
}
private struct Redeem: Decodable {
  let token: String
  let password: String
}
private struct Delivery: Decodable { let user: String }

extension Identity {
  static func emailValid(_ email: String) -> Bool {
    email.utf8.count <= 254
      && email.range(
        of: #"^[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9.-]+$"#, options: .regularExpression)
        != nil
      && !email.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }

  func changePassword(request: Request, current: String, password: String) throws {
    let user = try session(request).user
    guard current.utf8.count <= 1024,
      let row = try db.rows("SELECT password,email FROM users WHERE id=?", [user]).first,
      argon2id_verify(row["password"]!, current, current.utf8.count) == ARGON2_OK.rawValue
    else { throw HTTPError(.forbidden) }
    try reset(email: row["email"]!, password: password, actor: user)
  }

  func sendRecovery(_ target: String, request: Request) async throws {
    let actor = try session(request).user
    try requireAdmin(actor)
    let env = ProcessInfo.processInfo.environment
    guard let smtp = env["TEFTER_SMTP_URL"], let sender = env["TEFTER_SMTP_FROM"],
      Self.emailValid(sender),
      let origin = env["TEFTER_PUBLIC_URL"], URL(string: origin)?.scheme == "https"
    else {
      throw HTTPError(
        .serviceUnavailable, message: "Configure SMTP and the public HTTPS URL first.")
    }
    guard
      let recipient = try db.rows("SELECT email FROM users WHERE id=?", [target]).first?["email"],
      Self.emailValid(recipient)
    else { throw HTTPError(.notFound) }
    let token = Self.token()
    let digest = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    try db.execute(
      "INSERT OR REPLACE INTO recovery VALUES(?,?,unixepoch()+1800)", [target, digest])
    let message =
      "From: " + sender + "\r\nTo: " + recipient
      + "\r\nSubject: Set your Tefter password\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nOpen this link within 30 minutes to set your password.\r\n"
      + origin + "/#recover=" + token + "\r\n"
    let ok = await Task.detached {
      tefter_send_mail(
        smtp, env["TEFTER_SMTP_USER"] ?? "", env["TEFTER_SMTP_PASSWORD"] ?? "", sender, recipient,
        message)
    }.value
    guard ok == 1 else {
      try db.execute("DELETE FROM recovery WHERE digest=?", [digest])
      throw HTTPError(.badGateway, message: "Mail delivery failed.")
    }
    try audit(actor, "send-password-link", target)
  }

  func redeem(_ token: String, password: String) throws {
    let digest = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    guard token.count == 64,
      let row = try db.rows(
        "SELECT email,id FROM recovery JOIN users ON users.id=recovery.user WHERE digest=? AND expires>unixepoch()",
        [digest]
      ).first
    else { throw HTTPError(.forbidden) }
    try reset(email: row["email"]!, password: password, actor: row["id"]!)
  }
}

func registerRecovery(_ router: Router<BasicRequestContext>, _ identity: Identity) {
  let api = router.group("api/v1")
  api.post("password") { req, ctx -> HTTPResponse.Status in
    let input = try await req.decode(as: ChangePassword.self, context: ctx)
    try await identity.changePassword(
      request: req, current: input.current, password: input.password)
    return .noContent
  }
  api.post("recovery/send") { req, ctx -> HTTPResponse.Status in
    let input = try await req.decode(as: Delivery.self, context: ctx)
    try await identity.sendRecovery(input.user, request: req)
    return .noContent
  }
  api.post("recovery/redeem") { req, ctx -> HTTPResponse.Status in
    guard req.headers[.init("X-Tefter-Login")!] == "1" else { throw HTTPError(.forbidden) }
    let input = try await req.decode(as: Redeem.self, context: ctx)
    try await identity.redeem(input.token, password: input.password)
    return .noContent
  }
}
