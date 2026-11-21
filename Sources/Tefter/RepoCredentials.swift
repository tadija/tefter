import Foundation
import Hummingbird

struct RepoCredentialInput: Decodable { let privateKey: String; let knownHosts: String }

extension Identity {
  func credentialDirectory(space: String, repo: String) throws -> Directory {
    guard UUID(uuidString: space) != nil, UUID(uuidString: repo) != nil else { throw HTTPError(.badRequest) }
    return try Directory(root: home.path).directory("secrets").directory("git", create: true)
      .directory(space, create: true).directory(repo, create: true)
  }

  func setRepoCredential(_ repo: String, space: String, input: RepoCredentialInput?, user: String) throws {
    try requireAdmin(user)
    let registration = try repoAccess(repo, space: space, user: user)
    let operationKey = space + "/" + repo
    try acquireGit(operationKey); defer { gitOperations.remove(operationKey) }
    if let input {
      guard registration.location.hasPrefix("ssh://"),
        input.privateKey.utf8.count <= 32_768, !input.privateKey.isEmpty,
        input.knownHosts.utf8.count <= 65_536, !input.knownHosts.isEmpty
      else { throw HTTPError(.badRequest, message: "SSH credentials require an ssh:// Repo and pinned known_hosts.") }
    }
    let directory = try credentialDirectory(space: space, repo: repo)
    if let input {
      // Publish the key last; no operation can observe a new key with unpinned hosts.
      try directory.write("known_hosts", data: Data(input.knownHosts.utf8), replacing: true)
      try directory.write("key", data: Data(input.privateKey.utf8), replacing: true)
    } else {
      for name in ["key", "known_hosts"] where try directory.info(name) != nil { try directory.removeFile(name) }
    }
    try audit(user, input == nil ? "remove-repo-credential" : "configure-repo-credential", space + "/" + repo)
  }

  func gitEnvironment(at path: String) throws -> [String: String] {
    var environment = ["PATH":"/usr/bin:/bin", "HOME":home.appendingPathComponent("runtime").path,
      "GIT_CONFIG_NOSYSTEM":"1", "GIT_CONFIG_GLOBAL":"/dev/null", "GIT_TERMINAL_PROMPT":"0"]
    let prefix = home.appendingPathComponent("repositories").path + "/"
    guard path.hasPrefix(prefix) else { return environment }
    let components = path.dropFirst(prefix.count).split(separator: "/")
    guard components.count >= 2 else { return environment }
    let space = String(components[0]), repo = String(components[1])
    let directory = try credentialDirectory(space: space, repo: repo)
    guard let key = try directory.info("key") else { return environment }
    guard key.st_mode & 0o077 == 0, let hosts = try directory.info("known_hosts"), hosts.st_mode & 0o077 == 0 else {
      throw HTTPError(.conflict, message: "SSH key and known_hosts must have mode 0600.")
    }
    _ = try directory.openRegular("key"); _ = try directory.openRegular("known_hosts")
    // Git's SSH command variable is shell-parsed: quote only server-generated paths.
    func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    let base = home.appendingPathComponent("secrets/git/" + space + "/" + repo).path
    environment["GIT_SSH_COMMAND"] = "/usr/bin/ssh -F /dev/null -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=" + quote(base + "/known_hosts") + " -i " + quote(base + "/key")
    environment["GIT_SSH_VARIANT"] = "ssh"
    return environment
  }
}

func registerRepoCredentials(_ router: Router<BasicRequestContext>, _ identity: Identity) {
  let api = router.group("/api/v1/spaces/:space/repos/:repo/credentials")
  api.put { request, context -> HTTPResponse.Status in
    let input = try await request.decode(as: RepoCredentialInput.self, context: context)
    try await identity.setRepoCredential(context.parameters.require("repo"), space: context.parameters.require("space"),
      input: input, user: identity.session(request).user)
    return .noContent
  }
  api.delete { request, context -> HTTPResponse.Status in
    try await identity.setRepoCredential(context.parameters.require("repo"), space: context.parameters.require("space"),
      input: nil, user: identity.session(request).user)
    return .noContent
  }
}
