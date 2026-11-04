import Foundation

/// One response of the Responses API, as a stream put it together.
public struct ResponsesMessage: Equatable, Sendable {
    public var id: String
    public var model: String
    /// The output items as the response's last event carried them, to be sent back as they are in the next request's
    /// `input`; a function call whose arguments are not a JSON object has `{}` instead. Before that event, the items
    /// the stream has started or finished, in order.
    public var output: [JSON]
    /// `completed` or `incomplete`; empty until the stream ends.
    public var status: String
    /// Why an `incomplete` response stopped short, as in `max_output_tokens`; `nil` otherwise.
    public var incompleteReason: String?
    public var usage: Usage
}

public enum OpenAIError: Error, Equatable {
    /// The API refused or failed the request. `status` is the HTTP status, or `nil` for a failure inside a stream that
    /// had begun with 200; `code`, `message` and `param` are the API's own, as in `server_error`.
    case api(status: Int?, code: String, message: String, param: String?)
    /// The ChatGPT plan takes no request now: its usage limit is reached (`subscription_sharing_usage_limit_exceeded`)
    /// or its usage could not be checked (`subscription_sharing_usage_unavailable`). `usage` is what the failed
    /// response used, zero when it said nothing.
    case planLimit(code: String, message: String, usage: Usage)
    /// The access token was refused.
    case unauthorized
    /// A function call whose arguments arrived as text that is not a JSON object; the text.
    case badToolInput(String)
    /// The request got no answer, or the answer broke off: what the system says went wrong.
    case network(String)

    /// The codes of `.planLimit`, wherever the API gives them: an error body, `response.failed` or an `error` event.
    public static let planLimitCodes: Set<String> = [
        "subscription_sharing_usage_limit_exceeded", "subscription_sharing_usage_unavailable",
    ]
}

/// Puts the events of one Responses stream together into the response they describe, item by item.
public struct ResponsesAssembler {
    private var id = ""
    private var model = ""
    private var status = ""
    private var incompleteReason: String?
    private var usage = Usage.zero
    /// The output items that have started or finished, by the `output_index` the stream gives them.
    private var items: [Int: JSON] = [:]
    /// The output of the response's last event, which replaces `items`; `nil` until then.
    private var output: [JSON]?
    /// The arguments text of the first function call whose arguments are not a JSON object, which read as `{}`.
    private var badArguments: String?

    public init() {}

    /// Applies the next event of the stream, by the `type` its data names. A `response.output_text.delta` returns
    /// `.text`, a `response.output_item.done` the finished item as a `.block`, and `response.completed` or
    /// `response.incomplete`, which carry the usage and, when they list it, the whole output (else the streamed items stand), `.finished`; any other event returns `nil`,
    /// an event this does not know among them. A function call whose arguments are not a JSON object reads as
    /// `{}`, and `response.completed` then throws `OpenAIError.badToolInput` with the first such text;
    /// `response.incomplete` does not, its limit cut that text off. `response.failed` and an `error` throw `.planLimit`
    /// for the plan's codes (`OpenAIError.planLimitCodes`), with the usage `response.failed` carries and none from an
    /// `error`, and `.api(status: nil, ...)` for any other.
    public mutating func apply(_ event: SSEEvent) throws -> StreamUpdate? {
        // ponytail: data that is not JSON reads as nothing, as in `StreamAssembler`.
        let body = (try? JSON.parse(Data(event.data.utf8))) ?? .null
        switch body["type"]?.string {
        case "response.output_text.delta":
            return .text(body["delta"]?.string ?? "")
        case "response.output_item.added":
            if let index = body["output_index"]?.int, let item = body["item"] { items[index] = item }
        case "response.output_item.done":
            guard let index = body["output_index"]?.int, let item = body["item"] else { return nil }
            let finished = readable(item)
            items[index] = finished
            return .block(finished)
        case "response.completed", "response.incomplete":
            let response = body["response"]
            id = response?["id"]?.string ?? ""
            model = response?["model"]?.string ?? ""
            status = response?["status"]?.string ?? ""
            incompleteReason = response?["incomplete_details"]?["reason"]?.string
            // The response's own output list when the event carries one; otherwise what the stream delivered, item
            // by item (a ChatGPT-plan stream has ended with no list, which must not lose the answer).
            let streamed = items.sorted { $0.key < $1.key }.map(\.value)
            let listed = response?["output"]?.array?.map { readable($0) }
            let output = listed.map { $0.isEmpty ? streamed : $0 } ?? streamed
            self.output = output
            usage = Usage(response?["usage"] ?? .null)
            usage.webSearchRequests = output.filter { $0["type"]?.string == "web_search_call" }.count
            if let text = badArguments, status == "completed" { throw OpenAIError.badToolInput(text) }
            return .finished
        case "response.failed":
            let response = body["response"], error = response?["error"]
            let code = error?["code"]?.string ?? "error", message = error?["message"]?.string ?? ""
            if OpenAIError.planLimitCodes.contains(code) {
                throw OpenAIError.planLimit(code: code, message: message, usage: Usage(response?["usage"] ?? .null))
            }
            throw OpenAIError.api(status: nil, code: code, message: message, param: nil)
        case "error":
            let code = body["code"]?.string ?? "error", message = body["message"]?.string ?? event.data
            if OpenAIError.planLimitCodes.contains(code) {
                throw OpenAIError.planLimit(code: code, message: message, usage: .zero)
            }
            throw OpenAIError.api(status: nil, code: code, message: message, param: body["param"]?.string)
        default:
            break  // created, in progress, the part, annotation, argument, search and reasoning events, and new ones
        }
        return nil
    }

    /// The response as far as the events applied have built it, finished or not.
    public func message() -> ResponsesMessage {
        ResponsesMessage(
            id: id, model: model, output: output ?? items.sorted { $0.key < $1.key }.map(\.value), status: status,
            incompleteReason: incompleteReason, usage: usage)
    }

    /// `item`, a function call's arguments that are not a JSON object made `{}` and the first such text kept.
    private mutating func readable(_ item: JSON) -> JSON {
        guard item["type"]?.string == "function_call", case .object(var call) = item else { return item }
        let text = call["arguments"]?.string ?? ""
        guard (try? JSON.parse(Data(text.utf8)))?.object == nil else { return item }
        call["arguments"] = .string("{}")
        badArguments = badArguments ?? text
        return .object(call)
    }
}

/// The models a signed-in account may use, as `GET /v1/models` lists them: the entries under `models` (the key a
/// ChatGPT sign-in's answer uses) or `data` (an API key's), only those whose `visibility` is `list` when any entry
/// carries that key, in the server's order, each as the `slug` (or `id`) to send as `model` and the `display_name`
/// to show. `nil` when the body holds neither array.
public enum ModelList {
    public static func parse(_ body: JSON) -> [(id: String, name: String)]? {
        guard let entries = body["models"]?.array ?? body["data"]?.array else { return nil }
        let listed = entries.contains { $0["visibility"] != nil }
            ? entries.filter { $0["visibility"]?.string == "list" } : entries
        return listed.compactMap { entry in
            guard let id = entry["slug"]?.string ?? entry["id"]?.string else { return nil }
            return (id, entry["display_name"]?.string ?? entry["id"]?.string ?? id)
        }
    }
}
