import BMWCodingCore
import SwiftUI

/// The conversation with the mechanic: the running total, every message with the reads, sources and usage of each
/// turn, the turn in progress, Try again when the last question got no answer or the usage-limit message in its place,
/// the ChatGPT plan caption, and the input bar.
struct ChatView: View {
    @Environment(AIFlow.self) private var ai
    private static let end = "end"

    var body: some View {
        VStack(spacing: 0) {
            ChatTotal()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ChatHistory()
                        LiveTurn()
                        Color.clear.frame(height: 1).id(Self.end)
                    }
                    .padding()
                }
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .onChange(of: ai.conversation?.messages.count) { proxy.scrollTo(Self.end, anchor: .bottom) }
                .onChange(of: ai.streaming) { proxy.scrollTo(Self.end, anchor: .bottom) }
                .onChange(of: ai.activity) { proxy.scrollTo(Self.end, anchor: .bottom) }
            }
            if ai.planLimited {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Usage limit reached. Review your plan or this app's limit in ChatGPT settings.")
                    HStack {
                        Link("Manage usage", destination: ChatGPTBrowser.usagePage)
                            .buttonStyle(.borderedProminent)
                        Button("Try again") { ai.retry() }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
            } else {
                if let error = ai.error {
                    Text(error)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                }
                if ai.canRetry {
                    Button("Try again") { ai.retry() }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                }
            }
            if ai.settings.provider == .openai, ai.chatGPT != nil {
                HStack(spacing: 0) {
                    Text("Using ChatGPT plan · ")
                        .foregroundStyle(.secondary)
                    Link("Manage usage", destination: ChatGPTBrowser.usagePage)
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top])
            }
            ChatInput()
        }
    }
}

/// What the conversation has cost so far: `Total $0.0149 · 3 turns`, the dollars of its Anthropic turns, or
/// `Total on your ChatGPT plan · 3 turns` when every turn ran on the plan.
struct ChatTotal: View {
    @Environment(AIFlow.self) private var ai

    var body: some View {
        let turns = ai.conversation?.turns ?? []
        let onPlan = ai.conversation?.provider == .openai && !turns.contains { $0.provider == .anthropic }
        (onPlan
            ? Text("Total on your ChatGPT plan · ^[\(turns.count) turn](inflect: true)")
            : Text("Total \(dollars(ai.totalCost)) · ^[\(turns.count) turn](inflect: true)"))
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
    }
}

/// Every message of the conversation as the chat shows it, with the usage line of each turn.
struct ChatHistory: View {
    @Environment(Flow.self) private var flow
    @Environment(AIFlow.self) private var ai

    var body: some View {
        if let conversation = ai.conversation {
            // Only for naming the modules in the activity lines.
            let car = flow.adapter.map {
                MechanicCar(vin: conversation.vin, nickname: "", adapter: $0, modules: flow.modules, latestBackup: nil)
            }
            ForEach(rows(of: conversation, car: car)) { row in
                switch row.kind {
                case .owner(let text): Bubble(text: text, owner: true)
                case .mechanic(let text): Bubble(text: text, owner: false)
                case .chips(let questions): SuggestedQuestions(questions: questions)
                case .activity(let line, let link): ActivityLine(line: line, link: link)
                case .failed(let error):
                    Text("Failed: " + error)
                        .font(.caption)
                        .foregroundStyle(.red)
                case .notice(let text):
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.orange)
                case .sources(let sources): SourceList(sources: sources)
                case .usage(let turn, let cost): UsageLine(turn: turn, cost: cost)
                }
            }
        }
    }

    /// The rows for `conversation`, from what `Transcript.items` shows of its messages: the owner's messages but the
    /// first, the fixed question of the health check; the mechanic's text, a bubble for each run, its reads and
    /// lookups and the pages it cites; the chips under its last answer. Under each owner message, for each of its
    /// turns, the line saying it ran without web search, and for one that stopped or failed, the reads its lost
    /// messages held and why it failed; a usage line for every turn, the last turn's after its last message.
    private func rows(of conversation: Conversation, car: MechanicCar?) -> [ChatRow] {
        let messages = conversation.messages
        let provider = conversation.provider
        let items = Transcript.items(in: messages, provider: provider)
        // The chips come off the conversation's last text, when it is in its last answer.
        let lastAnswer = messages.lastIndex { $0["role"]?.string == "assistant" }
        let lastText = items.lastIndex { if case .mechanic = $0.kind { true } else { false } }
        // The turns that ran each owner message, as indices into `turns`, which keep their ids stable: several when
        // a turn failed or was stopped before any text and Try again ran the message again.
        let turnsOf = Dictionary(grouping: conversation.turns.indices) { conversation.turns[$0].messageIndex }
        // The last of them ends at the message before the next owner message, so a question that got no answer is
        // not counted into the turn before it; the turns before it left no message.
        var ends: [Int: Int] = [:]
        for (owner, turns) in turnsOf {
            let next = messages.indices.first {
                $0 > owner && Mechanic.isOwnerMessage(messages[$0], provider: provider)
            }
            ends[(next ?? messages.count) - 1] = turns.last
        }
        var rows: [ChatRow] = []
        func usageLine(_ turn: Int) {
            let record = conversation.turns[turn]
            let cost = ai.settings.prices.cost(of: record.usage, model: record.model)
            rows.append(ChatRow(id: "turn\(turn).usage", kind: .usage(record, cost: cost)))
        }
        var next = items.startIndex  // the items come in the order of their messages
        for index in messages.indices {
            var chips: ChatRow?
            while next < items.endIndex, items[next].messageIndex == index {
                let id = "\(index).\(items[next].place)"
                switch items[next].kind {
                case .owner(let text):
                    if index > 0 { rows.append(ChatRow(id: id, kind: .owner(text))) }
                case .mechanic(var text):
                    if next == lastText, index == lastAnswer {
                        let questions: [String]
                        (text, questions) = Chips.split(text)
                        if !questions.isEmpty { chips = ChatRow(id: id + ".chips", kind: .chips(questions)) }
                    }
                    if !text.isEmpty { rows.append(ChatRow(id: id, kind: .mechanic(text))) }
                case .toolCall(let call, let result):
                    var line = "…"
                    if result?.content == ClaudeClient.roundCapResult {
                        line = "Not run: tool limit reached"
                    } else if let car, let result {
                        line = Mechanic.activityLine(for: call, result: result, car: car)
                    }
                    rows.append(ChatRow(id: id, kind: .activity(line, link: nil)))
                case .webSearch(let query):
                    rows.append(ChatRow(id: id, kind: .activity(AIFlow.searchLine(query), link: nil)))
                case .webFetch(let url):
                    rows.append(ChatRow(id: id, kind: .activity(AIFlow.fetchLine(url), link: webURL(url))))
                case .fallback:
                    rows.append(ChatRow(id: id, kind: .activity("Answered by a fallback model", link: nil)))
                case .sources(let sources):
                    rows.append(ChatRow(id: id + ".sources", kind: .sources(sources)))
                }
                next += 1
            }
            if let chips { rows.append(chips) }  // after the pages the answer cites
            if Mechanic.isOwnerMessage(messages[index], provider: provider) {
                for turn in turnsOf[index] ?? [] {
                    let record = conversation.turns[turn]
                    if record.webSearchDropped {
                        let line = "Web search isn't available on \(record.model) with your plan; "
                            + "answering from the car's data only"
                        rows.append(ChatRow(id: "turn\(turn).noWeb", kind: .notice(line)))
                    }
                    // An answered turn's reads are in its messages; a stopped or failed one's were not kept.
                    if record.stopped || record.error != nil {
                        for (number, line) in record.activity.enumerated() {
                            rows.append(ChatRow(id: "turn\(turn).\(number)", kind: .activity(line, link: nil)))
                        }
                    }
                    if let error = record.error { rows.append(ChatRow(id: "turn\(turn).failed", kind: .failed(error))) }
                    if turn != turnsOf[index]?.last { usageLine(turn) }
                }
            }
            if let turn = ends[index] { usageLine(turn) }
        }
        return rows
    }
}

/// One row of the chat. Its id is the message and the block it comes from, so it stays put as the conversation grows.
struct ChatRow: Identifiable {
    enum Kind {
        case owner(String)
        case mechanic(String)
        case chips([String])
        case activity(String, link: URL?)
        /// Why a turn failed.
        case failed(String)
        /// What a turn ran without, under its question.
        case notice(String)
        case sources([Sources.Source])
        case usage(TurnRecord, cost: Double?)
    }

    let id: String
    let kind: Kind
}

/// The turn in progress: its reads and lookups so far, then its text as it streams, or Thinking… until the first
/// text arrives.
struct LiveTurn: View {
    @Environment(AIFlow.self) private var ai

    var body: some View {
        if ai.phase == .answering {
            ForEach(Array(ai.activity.enumerated()), id: \.offset) { _, line in
                ActivityLine(line: line, link: nil)
            }
            if ai.streaming.isEmpty {
                ProgressView("Thinking…")
            } else {
                Bubble(text: ai.streaming, owner: false)
            }
        }
    }
}

/// A message: the owner's on the right, the mechanic's on the left, with its inline markdown rendered.
struct Bubble: View {
    let text: String
    let owner: Bool

    var body: some View {
        Text(.init(text))
            .textSelection(.enabled)
            .padding(10)
            .background(
                owner ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.15), in: .rect(cornerRadius: 12))
            .padding(owner ? .leading : .trailing, 40)
            .frame(maxWidth: .infinity, alignment: owner ? .trailing : .leading)
    }
}

/// A read, a web lookup or a fallback, as a small line; a fetched page opens from it.
struct ActivityLine: View {
    let line: String
    let link: URL?

    var body: some View {
        if let link {
            Link(line, destination: link)
                .font(.caption)
        } else {
            Text(line)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// The web pages an answer cites, numbered from 1; each opens in the browser.
struct SourceList: View {
    let sources: [Sources.Source]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(sources.enumerated()), id: \.element.url) { number, source in
                let label = "\(number + 1). \(source.title)"
                if let url = webURL(source.url) {
                    Link(label, destination: url)
                } else {
                    Text(label)
                }
            }
        }
        .font(.caption)
    }
}

/// The questions an answer suggests, each a button that asks it.
struct SuggestedQuestions: View {
    @Environment(AIFlow.self) private var ai
    let questions: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(questions, id: \.self) { question in
                Button(question) { ai.send(question) }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
            }
        }
        .disabled(ai.phase != .ready)
    }
}

/// How a turn went: its tokens, its estimated cost and its web searches, then why it ended early, if it did.
struct UsageLine: View {
    let turn: TurnRecord
    let cost: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(counts)
                .foregroundStyle(.secondary)
            ForEach(endings, id: \.self) { ending in
                Text(ending)
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
    }

    /// `1200 in · 340 out · 5000 cached · $0.0149 · 2 searches` on Anthropic, `1200 in · 340 out · 120 reasoning ·
    /// on your ChatGPT plan · 2 searches` on the plan; without the searches when there were none.
    private var counts: String {
        let usage = turn.usage
        var parts = ["\(usage.inputTokens) in", "\(usage.outputTokens) out"]
        switch turn.provider {
        case .anthropic: parts += ["\(usage.cacheReadInputTokens) cached", dollars(cost)]
        case .openai: parts += ["\(usage.reasoningTokens) reasoning", "on your ChatGPT plan"]
        }
        if usage.webSearchRequests > 0 {
            parts.append(usage.webSearchRequests == 1 ? "1 search" : "\(usage.webSearchRequests) searches")
        }
        return parts.joined(separator: " · ")
    }

    private var endings: [String] {
        [
            turn.refused ? "The model declined to answer this" : nil,
            turn.truncated ? "The answer was cut short at the length limit" : nil,
            turn.stoppedAtRoundCap ? "Stopped after \(ClaudeClient.roundCap) tool rounds" : nil,
            turn.stopped ? "Stopped" : nil,
        ].compactMap { $0 }
    }
}

/// The owner's question, Send, and Stop while the mechanic answers.
struct ChatInput: View {
    @Environment(AIFlow.self) private var ai
    @State private var text = ""

    var body: some View {
        let answering = ai.phase == .answering
        HStack {
            TextField("Ask the mechanic…", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(send)
            if answering {
                Button("Stop") { ai.stop() }
            }
            Button("Send", action: send)
                .disabled(answering || question.isEmpty)
        }
        .padding()
    }

    private var question: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Sends the question and empties the field; nothing while the mechanic answers.
    private func send() {
        guard ai.phase == .ready, !question.isEmpty else { return }
        ai.send(question)
        text = ""
    }
}

/// A cost estimate as `$0.0149`, or `$?` when the model has no price.
func dollars(_ cost: Double?) -> String {
    cost.map { String(format: "$%.4f", $0) } ?? "$?"
}

/// `text` as a web address, or nil when it is not an http or https URL.
func webURL(_ text: String?) -> URL? {
    guard let url = text.flatMap(URL.init(string:)), let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https" else { return nil }
    return url
}
