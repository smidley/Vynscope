import SwiftUI

/// Connects to the OBDLink CX and shows what it says it is.
struct ConnectStep: View {
    @Environment(Flow.self) private var flow

    var body: some View {
        Form {
            Section {
                LabeledContent("Adapter") {
                    Text(stateText)
                        .foregroundStyle(flow.link.state == .ready ? Color.vynGreen : Color.vynMuted)
                }
                if let warning = flow.link.warning {
                    Text(warning)
                        .font(.vyn(.footnote))
                        .foregroundStyle(Color.vynOrangeDark)
                }
                // The drop's own warning clears with the next answer, so the count is what stays.
                if flow.link.reconnects > 0 {
                    Text("Reconnected ^[\(flow.link.reconnects) time](inflect: true) this session")
                        .font(.vyn(.footnote))
                        .foregroundStyle(Color.vynMuted)
                }
                if let adapter = flow.adapter {
                    LabeledContent("Model", value: flow.link.deviceModel ?? "not reported")
                    LabeledContent("Firmware", value: flow.link.deviceFirmware ?? "not reported")
                    LabeledContent("Device", value: adapter.model.isEmpty ? "not reported" : adapter.model)
                    LabeledContent(
                        "Device firmware", value: adapter.firmware.isEmpty ? "not reported" : adapter.firmware)
                }
            }
            Section {
                Button("Connect") { Task { await flow.connect() } }
                    .disabled(flow.busy || flow.reconnecting)
                Button("Disconnect") { flow.disconnect() }
                    .disabled(flow.link.state == .off)
                Button("Forget adapter") { UserDefaults.standard.removeObject(forKey: Flow.adapterKey) }
            } footer: {
                Text("""
                    Bonding only works for five minutes after the adapter is plugged in. Enter 123456 if asked for a \
                    PIN. Next time the app reconnects to the last adapter by itself; Forget adapter makes it scan \
                    for one instead.
                    """)
                    .font(.vyn(.footnote))
                    .foregroundStyle(Color.vynMuted)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color.vynIvory)
        .task {
            if flow.adapter == nil, UserDefaults.standard.string(forKey: Flow.adapterKey) != nil {
                await flow.connect()
            }
        }
    }

    private var stateText: String {
        switch flow.link.state {
        case .off: "Not connected"
        case .scanning: "Scanning…"
        case .connecting: "Connecting…"
        case .ready: "Connected"
        case .reconnecting: "Reconnecting…"
        case .failed(let why): why
        }
    }
}
