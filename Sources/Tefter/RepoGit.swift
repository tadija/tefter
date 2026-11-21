import Foundation
import Hummingbird

struct GitOverview: ResponseCodable {
  let available: Bool
  let branch: String?
  let head: String?
  let status: String?
  let commits: String?
}
struct GitReview: ResponseCodable { let head: String; let base: String; let diff: String }
struct GitApproval: Decodable { let approve: Bool; let head: String; let base: String }

extension Identity {
  func checkoutPath(_ space: String, repo: String) throws -> String {
    guard UUID(uuidString: space) != nil, UUID(uuidString: repo) != nil else { throw HTTPError(.badRequest) }
    return home.appendingPathComponent("repositories/" + space + "/" + repo + "/checkout").path
  }

  func gitRun(_ arguments: [String], at path: String) async throws -> String {
    _ = try Directory(root: path)
    let result = await Subprocess.run(executable: "/usr/bin/git", arguments: [
      "--no-optional-locks", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false",
      "-c", "credential.helper=", "-c", "protocol.ext.allow=never", "-c", "protocol.allow=never",
      "-c", "protocol.file.allow=always", "-c", "protocol.https.allow=always", "-c", "protocol.ssh.allow=always",
      "-c", "user.name=Tefter", "-c", "user.email=workspace@localhost"
    ] + arguments, environment: ["PATH":"/usr/bin:/bin", "HOME":home.appendingPathComponent("runtime").path,
      "GIT_CONFIG_NOSYSTEM":"1", "GIT_CONFIG_GLOBAL":"/dev/null", "GIT_TERMINAL_PROMPT":"0"],
      directory: path, input: Data(), timeout: 30)
    guard result.outcome == "completed" else {
      throw HTTPError(.conflict, message: "Git operation " + result.outcome + "; inspect the operator-managed checkout.")
    }
    return String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .newlines)
  }

  func acquireGit(_ key: String) throws {
    guard gitOperations.insert(key).inserted else { throw HTTPError(.conflict, message: "Repo operation in progress.") }
  }

  func cloneRepo(_ repo: String, space: String, user: String) async throws -> GitOverview {
    try requireAdmin(user)
    let registration = try repoAccess(repo, space: space, user: user)
    let key = space + "/" + repo
    try acquireGit(key); defer { gitOperations.remove(key) }
    let base = try Directory(root: home.path).directory("repositories", create: true)
      .directory(space, create: true).directory(repo, create: true)
    guard try base.info("checkout") == nil else { throw HTTPError(.conflict) }
    try audit(user, "clone-repo", key)
    _ = try await gitRun(["clone", "--no-local", "--", registration.location, "checkout"],
      at: home.appendingPathComponent("repositories/" + key).path)
    _ = try repoAccess(repo, space: space, user: user)
    return try await gitOverview(repo, space: space, user: user)
  }

  func gitOverview(_ repo: String, space: String, user: String) async throws -> GitOverview {
    _ = try repoAccess(repo, space: space, user: user)
    let path = try checkoutPath(space, repo: repo)
    guard FileManager.default.fileExists(atPath: path) else {
      return GitOverview(available: false, branch: nil, head: nil, status: nil, commits: nil)
    }
    _ = try Directory(root: path)
    let branch = try await gitRun(["branch", "--show-current"], at: path)
    let head = try await gitRun(["rev-parse", "HEAD"], at: path)
    let status = try await gitRun(["status", "--porcelain=v1", "--untracked-files=no", "--ignore-submodules=all"], at: path)
    let commits = try await gitRun(["log", "-10", "--format=%h %s"], at: path)
    _ = try repoAccess(repo, space: space, user: user)
    return GitOverview(available: true, branch: branch, head: head, status: status, commits: commits)
  }

  func executionRepo(_ id: String, space: String, user: String) throws -> (ExecutionRecord, String, String) {
    let record = try execution(id, space: space, user: user)
    guard let repo = record.repo else { throw HTTPError(.badRequest, message: "Session has no Repo link.") }
    _ = try repoAccess(repo, space: space, user: user)
    return (record, repo, try checkoutPath(space, repo: repo))
  }

  func createWorktree(_ id: String, space: String, user: String) async throws -> Identifier {
    let (_, repo, path) = try executionRepo(id, space: space, user: user)
    let key = space + "/" + repo
    try acquireGit(key); defer { gitOperations.remove(key) }
    let destination = home.appendingPathComponent("repositories/" + key + "/session-" + id).path
    try audit(user, "create-worktree", id)
    _ = try await gitRun(["worktree", "add", "-b", "tefter/" + id, "--", destination, "HEAD"], at: path)
    _ = try executionRepo(id, space: space, user: user)
    return Identifier(id: "tefter/" + id)
  }

  func reviewExecution(_ id: String, space: String, user: String) async throws -> GitReview {
    let (_, _, path) = try executionRepo(id, space: space, user: user)
    let head = try await gitRun(["rev-parse", "refs/heads/tefter/" + id], at: path)
    let base = try await gitRun(["rev-parse", "HEAD"], at: path)
    let diff = try await gitRun(["diff", "--no-ext-diff", "--no-textconv", "--ignore-submodules=all", base + "..." + head, "--"], at: path)
    _ = try executionRepo(id, space: space, user: user)
    return GitReview(head: head, base: base, diff: diff)
  }

  func approveGit(_ id: String, space: String, input: GitApproval, push: Bool, user: String) async throws -> GitReview {
    try requireOwner(space, user: user)
    guard input.approve else { throw HTTPError(.badRequest, message: "Explicit approval is required.") }
    let (_, repo, path) = try executionRepo(id, space: space, user: user)
    let key = space + "/" + repo
    try acquireGit(key); defer { gitOperations.remove(key) }
    let current = try await reviewExecution(id, space: space, user: user)
    guard current.head == input.head, current.base == input.base else {
      throw HTTPError(.conflict, message: "Reviewed commits changed. Review again before approval.")
    }
    _ = try executionRepo(id, space: space, user: user)
    try requireOwner(space, user: user)
    try audit(user, push ? "approve-push" : "approve-merge", id + "/" + current.head)
    if push {
      // Push only this reviewed session branch, never the checkout's default branch.
      _ = try await gitRun(["push", "--porcelain", "origin", current.head + ":refs/heads/tefter/" + id], at: path)
    } else {
      _ = try await gitRun(["merge", "--ff-only", "--no-edit", current.head], at: path)
    }
    _ = try executionRepo(id, space: space, user: user)
    return try await reviewExecution(id, space: space, user: user)
  }
}

func registerRepoGit(_ router: Router<BasicRequestContext>, _ identity: Identity) {
  let api = router.group("/api/v1/spaces/:space")
  api.get("repos/:repo/status") { request, context in
    try await identity.gitOverview(context.parameters.require("repo"), space: context.parameters.require("space"), user: identity.session(request).user)
  }
  api.post("repos/:repo/checkout") { request, context in
    try await identity.cloneRepo(context.parameters.require("repo"), space: context.parameters.require("space"), user: identity.session(request).user)
  }
  api.post("executions/:execution/worktree") { request, context in
    try await identity.createWorktree(context.parameters.require("execution"), space: context.parameters.require("space"), user: identity.session(request).user)
  }
  api.get("executions/:execution/review") { request, context in
    try await identity.reviewExecution(context.parameters.require("execution"), space: context.parameters.require("space"), user: identity.session(request).user)
  }
  for push in [false, true] {
    api.post(push ? "executions/:execution/push" : "executions/:execution/merge") { request, context in
      let input = try await request.decode(as: GitApproval.self, context: context)
      return try await identity.approveGit(context.parameters.require("execution"), space: context.parameters.require("space"), input: input,
        push: push, user: identity.session(request).user)
    }
  }
}
