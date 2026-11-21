import Hummingbird

struct PageWindow {
  let offset: Int
  let limit: Int

  init(_ request: Request) throws {
    let parameters = request.uri.queryParameters
    guard let offset = Int(parameters.get("offset") ?? "0"), offset >= 0,
      let limit = Int(parameters.get("limit") ?? "100"), (1...500).contains(limit)
    else { throw HTTPError(.badRequest, message: "Invalid pagination parameters.") }
    self.offset = offset
    self.limit = limit
  }

  func slice<T>(_ values: [T]) -> [T] {
    Array(values.dropFirst(min(offset, values.count)).prefix(limit))
  }
  func next(count: Int) -> Int? { offset < count && count - offset > limit ? offset + limit : nil }
}

struct PrivateResponseHeaders: RouterMiddleware {
  func handle(
    _ request: Request, context: BasicRequestContext,
    next: (Request, BasicRequestContext) async throws -> Response
  ) async throws -> Response {
    var response: Response
    do { response = try await next(request, context) } catch var error as HTTPError
      where request.uri.path.hasPrefix("/api/")
    {
      if error.body == nil { error.body = error.status.reasonPhrase }
      response = try error.response(from: request, context: context)
    }
    if request.uri.path.hasPrefix("/api/") { response.headers[.cacheControl] = "private, no-store" }
    response.headers[.init("Referrer-Policy")!] = "no-referrer"
    return response
  }
}
