import BMWCodingCore
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// Every command sent to the adapter and every line it answered, oldest first.
struct LogView: View {
    @Environment(Flow.self) private var flow
    #if os(iOS)
    @Environment(\.dismiss) private var dismiss
    #endif

    var body: some View {
        List(flow.log.entries) { entry in
            Text("\(entry.time, format: logTime) \(mark(entry.direction)) \(entry.text)")
        }
        .font(.caption)
        .monospaced()
        .defaultScrollAnchor(.bottom)
        .navigationTitle("Log")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink("Share", item: LogText(log: flow.log), preview: SharePreview("BMW Coding log"))
            }
            #if os(iOS)
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
            #endif
        }
    }

    private func mark(_ direction: LogEntry.Direction) -> String {
        switch direction {
        case .sent: "→"
        case .received: "←"
        case .note: "·"
        }
    }
}

/// When a line was logged, local time to the millisecond, as in `14:03:11.123`.
private let logTime = Date.ISO8601FormatStyle(timeZone: .current).time(includingFractionalSeconds: true)

/// Opens the log: a window on the Mac, a sheet on the iPhone.
struct LogButton: View {
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Log") { openWindow(id: "log") }
    }
    #else
    @Environment(Flow.self) private var flow

    var body: some View {
        Button("Log") { flow.showingLog = true }
    }
    #endif
}

/// The whole log as text for Share, built only when a share actually happens.
nonisolated struct LogText: Transferable {
    let log: Log

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .utf8PlainText) { item in Data(await item.log.asText().utf8) }
    }
}
