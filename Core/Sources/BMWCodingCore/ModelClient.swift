import Foundation

/// A client the mechanic runs a turn on: the conversation's messages in the provider's own wire shape.
public protocol ModelClient: AnyObject {
    /// Runs one owner message, which `messages` already ends with, to its answer through the mechanic's tool loop,
    /// giving `onUpdate` the stream and `onUsage` the usage of each request as it completes. `messages` takes the
    /// turn's messages only when this returns; when it throws, it is left as it was.
    func run(
        messages: inout [JSON], system: [JSON], tools: [JSON], model: String, effort: String,
        runTool: (ToolCall) async throws -> ToolResult, onUpdate: (StreamUpdate) -> Void, onUsage: (Usage) -> Void
    ) async throws -> Turn
}

/// What one plain HTTP exchange answered, for the sign-in endpoints and the model list.
public struct HTTPReply: Equatable, Sendable {
    public var status: Int
    /// By lower-cased header name.
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// The seam to plain HTTP: one request, answered whole.
public protocol HTTPTransport: AnyObject {
    func send(_ request: URLRequest) async throws -> HTTPReply
}

/// `HTTPTransport` over `URLSession.shared`; a `URLError` is thrown as it is.
public final class URLSessionHTTPTransport: HTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> HTTPReply {
        let (body, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (name, value) in http?.allHeaderFields ?? [:] { headers["\(name)".lowercased()] = "\(value)" }
        return HTTPReply(status: http?.statusCode ?? 0, headers: headers, body: body)
    }
}
