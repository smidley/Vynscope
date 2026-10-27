import Foundation
import Observation

/// One line of the adapter conversation.
public struct LogEntry: Identifiable, Sendable {
    public let id: UUID
    public let time: Date
    public let direction: Direction
    public let text: String

    public enum Direction: Sendable { case sent, received, note }
}

/// Every command sent to the adapter and every line received, in order, for the Log screen and for
/// sharing. Once a file is attached each entry is also appended to it as it is added, so a crash
/// leaves a record up to the last entry. Text is recorded as given; callers pass one line.
@Observable
public final class Log {
    // ponytail: unbounded; a first full sweep may log tens of thousands of lines. Window it if that gets slow.
    public private(set) var entries: [LogEntry] = []
    @ObservationIgnored private var mirror: FileHandle?

    /// Fixed locale so the digits and the 24-hour clock do not depend on the user's region settings.
    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    public init() {}

    public func sent(_ text: String) { add(.sent, text) }
    public func received(_ text: String) { add(.received, text) }
    public func note(_ text: String) { add(.note, text) }

    /// Starts mirroring to `url`: the file is created if missing and appended to if it exists, never
    /// truncated. Entries added before this call are not written. Writes after it are best-effort: one
    /// that fails is dropped and the entry stays in `entries`. Throws if the file cannot be created or
    /// opened.
    public func attachFile(_ url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        mirror = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    /// The whole log as text: one line per entry, each ending in a newline, the same lines the file gets.
    public func asText() -> String {
        entries.map { line($0) + "\n" }.joined()
    }

    private func add(_ direction: LogEntry.Direction, _ text: String) {
        let entry = LogEntry(id: UUID(), time: Date(), direction: direction, text: text)
        entries.append(entry)
        try? mirror?.write(contentsOf: Data((line(entry) + "\n").utf8))
    }

    private func line(_ entry: LogEntry) -> String {
        let mark = switch entry.direction {
        case .sent: "→"
        case .received: "←"
        case .note: "·"
        }
        return "\(Self.timestamp.string(from: entry.time)) \(mark) \(entry.text)"
    }
}
