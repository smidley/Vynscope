import BMWCodingCore
import SwiftUI

/// The last fault read: Read fault codes, or Read again, with the read's progress; then a section per module in the
/// read's order and one for the standard OBD codes. Ask the mechanic in the toolbar. Nothing here writes to the car.
struct FaultCodesView: View {
    @Environment(Flow.self) private var flow

    var body: some View {
        List {
            Section {
                Button(flow.faultReport == nil ? "Read fault codes" : "Read again") {
                    Task { await flow.readFaults() }
                }
                .disabled(flow.busy)
                if let reading = flow.readingFaults {
                    HStack {
                        ProgressView()
                        Text(reading)
                    }
                }
            } footer: {
                if flow.faultReport == nil, flow.readingFaults == nil {
                    Text("Reads every module's fault memory and the standard codes. Nothing is cleared.")
                        .font(.vyn(.footnote))
                        .foregroundStyle(Color.vynMuted)
                }
            }
            if let report = flow.faultReport {
                let obd = Self.obdRows(report.obd)
                ForEach(report.modules, id: \.address) { module in
                    Section {
                        if let faults = module.faults {
                            if faults.isEmpty {
                                Text("No faults")
                                    .foregroundStyle(Color.vynMuted)
                            }
                            ForEach(faults.indices, id: \.self) { index in
                                let fault = faults[index]
                                FaultRow(
                                    code: fault.code, chip: FaultChip.chip(forStatus: fault.status),
                                    status: fault.status)
                            }
                        } else {
                            Text(module.faultRead ?? "no answer")
                                .foregroundStyle(Color.vynMuted)
                        }
                    } header: {
                        Text(module.name.map { "\($0) · \(module.address)" } ?? "0x\(module.address)")
                            .textCase(nil)
                    } footer: {
                        if obd.isEmpty, module.address == report.modules.last?.address { readAt }
                    }
                }
                if !obd.isEmpty {
                    Section {
                        ForEach(obd.indices, id: \.self) { index in
                            FaultRow(code: obd[index].code, chip: obd[index].chip)
                        }
                    } header: {
                        Text("OBD")
                            .textCase(nil)
                    } footer: {
                        readAt
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.vynIvory)
        .connectionLine()
        .toolbar {
            ToolbarItem {
                NavigationLink("Ask the mechanic") { MechanicView() }
            }
        }
    }

    /// `Read at 14:05`, the time of the last read, for the last section's footer.
    @ViewBuilder private var readAt: some View {
        if let date = flow.faultReadAt {
            Text("Read at \(date.formatted(date: .omitted, time: .shortened))")
                .font(.vyn(.footnote))
                .foregroundStyle(Color.vynMuted)
        }
    }

    /// The standard OBD codes as rows: the stored codes, then the pending, each in the controllers' sorted order.
    private static func obdRows(_ obd: HealthCheck.OBDHealth?) -> [(code: String, chip: FaultChip)] {
        guard let obd else { return [] }
        return [(obd.storedCodes, FaultChip.stored), (obd.pendingCodes, .pending)].flatMap { codes, chip in
            codes.sorted { $0.key < $1.key }.flatMap(\.value).map { (code: $0, chip: chip) }
        }
    }
}

/// A fault code in mono and its chip, then the raw status byte in muted mono when the code came with one. A status
/// that is not a byte has no chip.
private struct FaultRow: View {
    let code: String
    let chip: FaultChip?
    var status: String?

    var body: some View {
        HStack {
            Text(code)
                .font(.vynMono(.body))
            if let chip {
                Text(chip.rawValue)
                    .font(.vyn(.caption, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .foregroundStyle(chip == .old ? Color.vynMuted : Color.vynPaper)
                    .background(Self.fill(chip), in: .capsule)
            }
            if let status {
                Text(status)
                    .font(.vynMono(.caption))
                    .foregroundStyle(Color.vynMuted)
            }
        }
    }

    /// Active red, pending orange, stored ink, old the line color.
    private static func fill(_ chip: FaultChip) -> Color {
        switch chip {
        case .active: .red
        case .pending: .vynOrange
        case .stored: .vynInk
        case .old: .vynLine
        }
    }
}
