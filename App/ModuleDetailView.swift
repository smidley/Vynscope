import BMWCodingCore
import SwiftUI

/// What one module said about itself during the scan, and its coding data from the latest backup. Opening it never
/// reads the car.
struct ModuleDetailView: View {
    @Environment(Flow.self) private var flow
    let module: DiscoveredModule
    /// The module's coding data in the latest backup, by identifier in order; nil when no backup has the module.
    @State private var coding: [(key: String, value: String)]? = nil

    var body: some View {
        Form {
            Section {
                Text([module.description, String(format: "diagnostic address 0x%02X", module.address)]
                    .compactMap { $0 }.joined(separator: " · "))
            }
            IdentificationSection(
                hardware: module.hardware, software: module.software, serial: module.serial, signed: module.signed)
            CodingFilesSection(files: module.codingFiles)
            CodingDataSection(coding: coding)
            #if DEBUG
            SurveySection(address: module.address)
            #endif
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color.vynIvory)
        .connectionLine()
        .navigationTitle(module.title)
        .toolbar {
            ToolbarItem { LogButton() }
        }
        .task(id: module.address) {
            coding = flow.latestBackup()?.modules.first { $0.address == module.address }?
                .coding.sorted { $0.key < $1.key }
        }
    }
}

struct IdentificationSection: View {
    let hardware: String?
    let software: String?
    let serial: String?
    let signed: Bool

    var body: some View {
        Section("Identification") {
            LabeledContent("Hardware", value: hardware ?? "not reported")
            LabeledContent("Software", value: software ?? "not reported")
            LabeledContent("Serial", value: serial ?? "not reported")
            LabeledContent("Coding", value: signed ? "signed" : "not signed")
        }
    }
}

struct CodingFilesSection: View {
    let files: [String]

    var body: some View {
        Section("Coding files") {
            if files.isEmpty { Text("not reported") }
            ForEach(files, id: \.self) { Text($0).font(.vynMono(.body)) }
        }
    }
}

/// The coding data as `DID  bytes` lines, with how many identifiers and bytes there are.
struct CodingDataSection: View {
    let coding: [(key: String, value: String)]?

    var body: some View {
        Section("Coding data · read-only") {
            if let coding {
                let bytes = coding.reduce(0) { $0 + $1.value.count / 2 }
                Text("^[\(coding.count) identifier](inflect: true) · \(sizeText(bytes))")
                ForEach(coding, id: \.key) { did, hex in
                    Text("\(did)  \(spaced(hex))").font(.vynMono(.body))
                }
            } else {
                Text("Run Backup to read coding data")
            }
        }
    }

    /// `0102AB` as `01 02 AB`.
    private func spaced(_ hex: String) -> String {
        String(hex.enumerated().flatMap { $0.offset > 0 && $0.offset % 2 == 0 ? [" ", $0.element] : [$0.element] })
    }
}

#if DEBUG
/// For the in-car survey, in debug builds only: every identification identifier of the module, into the log.
struct SurveySection: View {
    @Environment(Flow.self) private var flow
    let address: UInt8

    var body: some View {
        Section {
            Button("Survey identification") { Task { await flow.survey(address) } }
                .disabled(flow.busy)
            if let error = flow.error {
                Text(error).foregroundStyle(.red)
            }
        } footer: {
            Text("Debug builds only. Logs what the module answers to F100 to F1FF.")
                .font(.vyn(.footnote))
                .foregroundStyle(Color.vynMuted)
        }
    }
}
#endif
