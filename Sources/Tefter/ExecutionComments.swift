import Foundation
import Hummingbird

extension Identity {
  func integrationComments(_ id: String, space: String, repo: Bool, request: Request,
    change: CommentChange? = nil) throws -> ThreadFile {
    let user = try session(request).user
    if repo { _ = try repoAccess(id, space: space, user: user) }
    else { _ = try execution(id, space: space, user: user) }
    let directory = try root(space, user: user)
    if let change {
      return try mutateThread(space, id: id, root: directory, change: change, user: user, request: request)
    }
    return try thread(id, root: directory).page(PageWindow(request))
  }
}

func registerExecutionComments(_ router: Router<BasicRequestContext>, _ identity: Identity) {
  let api = router.group("/api/v1/spaces/:space")
  for repo in [false, true] {
    let path: RouterPath = repo ? "repos/:repo/comments" : "executions/:execution/comments"
    api.get(path) { request, context in
      try await identity.integrationComments(context.parameters.require(repo ? "repo" : "execution"), space: context.parameters.require("space"),
        repo: repo, request: request)
    }
    api.post(path) { request, context in
      let input = try await request.decode(as: CommentChange.self, context: context)
      return try await identity.integrationComments(context.parameters.require(repo ? "repo" : "execution"), space: context.parameters.require("space"),
        repo: repo, request: request, change: input)
    }
  }
}
