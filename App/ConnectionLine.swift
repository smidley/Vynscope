import SwiftUI

/// The line under the title of every screen but the Car tab's: the connection (the car and its modules, how the link
/// is doing, Not connected with Connect, or no car read with Read, both buttons opening the Car tab), what runs now on
/// any tab, and the flow's error.
struct ConnectionLine: View {
    @Environment(Flow.self) private var flow
    @Environment(AIFlow.self) private var ai

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                if flow.reconnecting {
                    Text("Reconnecting…")
                        .foregroundStyle(Color.vynOrangeDark)
                } else if let warning = flow.link.warning {
                    Text(warning)
                        .foregroundStyle(Color.vynOrangeDark)
                } else if flow.diag == nil || flow.gaveUp {
                    Text("Not connected")
                        .foregroundStyle(Color.vynMuted)
                    Button("Connect") { flow.tab = .car }
                        .buttonStyle(.borderless)
                } else if flow.vin == nil {
                    Text("Adapter connected · no car read")
                        .foregroundStyle(Color.vynMuted)
                    Button("Read") { flow.tab = .car }
                        .buttonStyle(.borderless)
                } else {
                    connected
                        .foregroundStyle(Color.vynMuted)
                }
            }
            if let activity {
                HStack {
                    PulseMark(size: 14)
                    Text(activity)
                }
            }
            if let error = flow.error {
                Text(error)
                    .foregroundStyle(.red)
            }
        }
        .font(.vyn(.footnote))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color.vynIvory)
    }

    /// `Connected · <nickname, or the VIN's last four> · <n> modules`: the car once it was read, the count once a
    /// scan found modules.
    private var connected: Text {
        let car = flow.car?.nickname ?? flow.vin.map { String($0.suffix(4)) }
        let text = car.map { "Connected · \($0)" } ?? "Connected"
        return flow.modules.isEmpty ? Text(text) : Text("\(text) · ^[\(flow.modules.count) module](inflect: true)")
    }

    /// What runs now: the flow's fault read, scan or backup, else the health check at its step, else the mechanic's
    /// answer.
    private var activity: String? {
        if let activity = flow.activity { return activity }
        return switch ai.phase {
        case .checking(let step): step
        case .answering: "The mechanic is thinking"
        case .idle, .ready: nil
        }
    }
}

extension View {
    /// The connection line between the screen's title and its content.
    func connectionLine() -> some View {
        safeAreaInset(edge: .top, spacing: 0) { ConnectionLine() }
    }
}
