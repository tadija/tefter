import Foundation
import Hummingbird

/// Optional installation-local configuration, with service environment overrides.
struct InstallationConfig: Decodable {
  let version: Int
  let settings: [String: String]

  static func load(home: URL, environment: [String: String]) throws -> [String: String] {
    let root = try Directory(root: home.path)
    let config = try root.directory("config")
    var values = [String: String]()
    if try config.info("server.json") != nil {
      let file = try JSONDecoder().decode(Self.self, from: config.read("server.json"))
      let keys: Set<String> = [
        "TEFTER_COMMS_RETENTION_DAYS", "TEFTER_HOST", "TEFTER_PORT", "TEFTER_WEB", "TEFTER_PUBLIC_URL",
        "TEFTER_SMTP_URL", "TEFTER_SMTP_FROM", "TEFTER_SMTP_USER", "TEFTER_SMTP_CA_FILE",
      ]
      guard file.version == 1, Set(file.settings.keys).isSubset(of: keys) else {
        throw HTTPError(
          .internalServerError, message: "Unsupported config/server.json version or field.")
      }
      values = file.settings
    }
    let secrets = try root.directory("secrets")
    if let info = try secrets.info("smtp-password") {
      guard info.st_mode & 0o077 == 0 else {
        throw HTTPError(.internalServerError, message: "Set mode 0600 on secrets/smtp-password.")
      }
      values["TEFTER_SMTP_PASSWORD"] = String(
        decoding: try secrets.read("smtp-password"), as: UTF8.self
      )
      .trimmingCharacters(in: .newlines)
    }
    return values.merging(environment.filter { $0.key.hasPrefix("TEFTER_") }) { _, override in
      override
    }
  }
}
