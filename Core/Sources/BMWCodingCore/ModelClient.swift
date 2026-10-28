import Foundation

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
