import Foundation
import Network
import os

/// Listens on 127.0.0.1 for the browser's redirect to /auth/callback. Each connection is read and answered on its
/// own, so a browser's idle spare connection holds nothing up. One listener serves one sign-in: `stop` ends it.
public final class LoopbackListener {
    private let queue = DispatchQueue(label: "com.smidley.vynscope.loopback")
    private var listener: NWListener?
    private var port: UInt16 = 0
    /// The targets of the requests to the callback path, each yielded once its page has gone out.
    private let targets: AsyncStream<String>
    private let caught: AsyncStream<String>.Continuation
    /// Every connection accepted, so that `stop` can close those still open.
    private let connections = OSAllocatedUnfairLock(initialState: [NWConnection]())

    public init() {
        (targets, caught) = AsyncStream.makeStream(of: String.self)
    }

    /// Starts listening on an ephemeral port; the redirect URL `http://127.0.0.1:<port>/auth/callback`.
    public func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let (states, stateChanged) = AsyncStream.makeStream(of: NWListener.State.self)
        let (queue, caught, connections) = (queue, caught, connections)
        listener.stateUpdateHandler = { stateChanged.yield($0) }
        listener.newConnectionHandler = { connection in
            connections.withLock { $0.append(connection) }
            connection.start(queue: queue)
            LoopbackListener.read(connection, head: Data(), caught: caught)
        }
        self.listener = listener
        listener.start(queue: queue)
        for await state in states {
            switch state {
            case .ready:
                port = listener.port?.rawValue ?? 0
                return URL(string: "http://127.0.0.1:\(port)\(ChatGPT.callbackPath)")!
            case .waiting(let error), .failed(let error):
                stop()
                throw error
            case .cancelled:
                throw CancellationError()
            default:
                continue
            }
        }
        stop()
        throw CancellationError()
    }

    /// The first request to the callback path, as a URL with its query; answers it with a page saying the owner can
    /// close it, which claims nothing, since nothing is checked yet. Throws `CancellationError` when cancelled.
    public func callback() async throws -> URL {
        var iterator = targets.makeAsyncIterator()
        // nil when the awaiting task is cancelled or `stop` ended the wait.
        guard let target = await iterator.next() else {
            stop()
            throw CancellationError()
        }
        // `answer` accepted the target only if it makes a URL after this host.
        return URL(string: "http://127.0.0.1:\(port)\(target)")!
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        caught.finish()
        for connection in connections.withLock({ $0 }) { connection.cancel() }
    }

    /// Reads `connection` up to the end of the request head, then answers it; a connection that closes or sends more
    /// than 16 KB first is closed unanswered.
    nonisolated private static func read(
        _ connection: NWConnection, head: Data, caught: AsyncStream<String>.Continuation
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
            let head = head + (data ?? Data())
            if let end = head.range(of: Data("\r\n\r\n".utf8)) {
                answer(connection, head: head[..<end.lowerBound], caught: caught)
            } else if isComplete || error != nil || head.count > 16_384 {
                connection.cancel()
            } else {
                read(connection, head: head, caught: caught)
            }
        }
    }

    /// The callback path gets the page, and its target goes to `caught` once the page is out; any other gets 404.
    nonisolated private static func answer(
        _ connection: NWConnection, head: Data, caught: AsyncStream<String>.Continuation
    ) {
        let requestLine = String(decoding: head.prefix { $0 != UInt8(ascii: "\r") }, as: UTF8.self)
            .split(separator: " ")
        let target = requestLine.count == 3 ? String(requestLine[1]) : ""
        let isCallback = target.hasPrefix("/") && URL(string: "http://127.0.0.1\(target)")?.path == ChatGPT.callbackPath
        let page = isCallback
            ? response(
                "200 OK", "<html><body><p>You can close this page and return to Vynscope.</p></body></html>")
            : response("404 Not Found", "")
        connection.send(content: page, contentContext: .finalMessage, completion: .contentProcessed { _ in
            connection.cancel()
            if isCallback { caught.yield(target) }
        })
    }

    nonisolated private static func response(_ status: String, _ body: String) -> Data {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        return Data((head + body).utf8)
    }
}
