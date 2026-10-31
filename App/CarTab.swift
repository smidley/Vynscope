import SwiftUI

/// The adapter and the car: the adapter's state and what it says it is, Connect, Reconnect while a known car's
/// adapter was dropped, Disconnect and Forget adapter; then Read, the VIN with the car's nickname, and the other cars
/// on file.
struct CarTab: View {
    @Environment(Flow.self) private var flow
    @Environment(AIFlow.self) private var ai

    var body: some View {
        Form {
            if let error = flow.error {
                Section {
                    Text(error).foregroundStyle(.red)
                }
            }
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
                // A known car whose adapter was dropped: after a give-up, or by an action's error (`Flow.explain`).
                if flow.diag == nil, flow.vin != nil {
                    if flow.error == nil {
                        Text(reconnectReason)
                            .foregroundStyle(.red)
                    }
                    Button("Reconnect") {
                        Task {
                            await flow.reconnect()
                            if flow.diag != nil { ai.error = nil }  // the AI step's line that asked for it
                        }
                    }
                    .disabled(flow.busy || flow.reconnecting)
                }
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
            Section {
                Button("Read") { Task { await flow.readCar() } }
                    .disabled(flow.busy)
            } footer: {
                Text("Turn the ignition on; there is no need to start driving.")
                    .font(.vyn(.footnote))
                    .foregroundStyle(Color.vynMuted)
            }
            if let vin = flow.vin {
                Section {
                    Text(vin)
                        .font(.vynMono(.body))
                        .textSelection(.enabled)
                    if let car = flow.car {
                        LabeledContent("Nickname", value: car.nickname)
                    } else {
                        NicknameField()
                    }
                } header: {
                    Text("VIN from the car")
                } footer: {
                    if flow.car == nil {
                        Text("The first time a VIN shows up you give it a nickname; after that it is recognised.")
                            .font(.vyn(.footnote))
                            .foregroundStyle(Color.vynMuted)
                    }
                }
            }
            if !flow.otherCars.isEmpty {
                Section("Also on file") {
                    ForEach(flow.otherCars, id: \.vin) { car in
                        LabeledContent(car.nickname, value: car.vin)
                    }
                }
                .foregroundStyle(Color.vynMuted)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color.vynIvory)
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

    /// Why Reconnect is offered, shown while no error says so: the link's message once it has given up, else that the
    /// adapter needs setting up.
    private var reconnectReason: String {
        if case .failed(let message) = flow.link.state { return message }
        return "The adapter needs to be set up again."
    }
}

/// The nickname for a new car: at most 40 characters, saved without the blanks around it.
struct NicknameField: View {
    @Environment(Flow.self) private var flow
    @State private var text = ""

    var body: some View {
        let nickname = text.trimmingCharacters(in: .whitespacesAndNewlines)
        TextField("Nickname", text: $text)
            .onChange(of: text) {
                if text.count > 40 { text = String(text.prefix(40)) }
            }
            .onSubmit {
                if !nickname.isEmpty { flow.name(nickname) }
            }
        Button("Save") { flow.name(nickname) }
            .disabled(nickname.isEmpty)
    }
}
