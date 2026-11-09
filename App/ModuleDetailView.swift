import BMWCodingCore
import SwiftUI

/// What one module said about itself during the scan, and its coding data from the latest backup. Opening it never
/// reads the car.
struct ModuleDetailView: View {
    @Environment(Flow.self) private var flow
    let module: DiscoveredModule
    /// The module's coding data in the latest backup, by identifier in order; nil when no backup has the module.
    @State private var coding: [(key: String, value: String)]? = nil
    /// Whether a backup holds this module complete, which the write test checks against.
    @State private var hasBackup = false

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
            if let vin = flow.vin, WriteTest.isEligible(module, vin: vin) {
                WriteTestSection(module: module, hasBackup: hasBackup)
            }
            #if DEBUG
            SurveySection(address: module.address)
            #endif
        }
        .quietButtons()
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color.vynIvory)
        .connectionLine()
        .navigationTitle(module.title)
        .toolbar {
            ToolbarItem { LogButton() }
        }
        .task(id: [String(module.address), flow.lastBackup?.path ?? ""]) {
            hasBackup = flow.newestBackup(complete: module.address) != nil
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
                Text("Back up the car to read its coding data")
            }
        }
    }

    /// `0102AB` as `01 02 AB`.
    private func spaced(_ hex: String) -> String {
        String(hex.enumerated().flatMap { $0.offset > 0 && $0.offset % 2 == 0 ? [" ", $0.element] : [$0.element] })
    }
}

/// The write test of a module it is allowed on: what it does, its button, the confirmation, the progress while it
/// writes, and how it ended this session.
struct WriteTestSection: View {
    @Environment(Flow.self) private var flow
    let module: DiscoveredModule
    let hasBackup: Bool

    private var name: String { module.description ?? module.title }

    /// Why the button cannot be used now; nil when it can.
    private var unavailable: String? {
        if flow.busy { return "Still working" }
        if flow.diag == nil || flow.gaveUp { return "Not connected" }
        if !hasBackup { return "Back up the car first" }
        return nil
    }

    var body: some View {
        Section {
            Text("Writes this module's coding back unchanged to see whether it accepts a write. Nothing on the car changes.")
            if flow.writeTestModule?.address == module.address, let progress = flow.writeTestProgress {
                ProgressLine(
                    value: Double(progress.done), total: Double(progress.total),
                    label: "Writing back identifier \(progress.done + 1) of \(progress.total)",
                    stop: flow.stopWriteTest)
            } else if flow.writeTestModule?.address == module.address, flow.writeTestChecking {
                HStack {
                    PulseMark(size: 14)
                    Text("Checking against the backup…")
                }
            } else {
                Button("Write test") { Task { await flow.prepareWriteTest(module) } }
                    .disabled(unavailable != nil)
                if let unavailable { note(unavailable) }
            }
            if let result = flow.writeTestResults[module.address] { WriteTestResultLines(result: result) }
        } header: {
            Text("Write test")
        }
        .confirmationDialog(
            "Write test on \(name)?",
            isPresented: Binding(
                get: { flow.writeTestReady?.address == module.address },
                set: { if !$0 { Task { flow.cancelWriteTest() } } }),
            presenting: flow.writeTestReady
        ) { ready in
            Button("Write test") { Task { await flow.confirmWriteTest(ready) } }
            Button("Cancel", role: .cancel) {}
        } message: { ready in
            Text("""
                Writes \(ready.identifiers.count) identifiers, \(ready.bytes) bytes, back unchanged. \
                Checked against the backup of \(ready.backupDate.formatted(date: .abbreviated, time: .shortened)). \
                Battery \(ready.voltage.formatted(.number.precision(.fractionLength(1)))) V. \
                Park with the ignition on.
                """)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.vyn(.footnote)).foregroundStyle(Color.vynMuted)
    }
}

/// How the last write test of a module ended, in footnote lines.
struct WriteTestResultLines: View {
    let result: WriteTestResult

    var body: some View {
        switch result {
        case .preparation(let preparation): preparationLines(preparation)
        case .outcome(let outcome): outcomeLines(outcome)
        case .stopped(let done, let total, let why):
            line("Stopped after \(done) of \(total)")
            if let why { line(why) }
        }
    }

    @ViewBuilder
    private func preparationLines(_ preparation: WriteTest.Preparation) -> some View {
        switch preparation {
        case .ready: EmptyView()
        case .notEligible: line("Not eligible for the write test")
        case .noBackup: line("Back up the car first")
        case .backupTooOld: line("The backup was made before coding files could be read. Back up the car again.")
        case .changed(let differences):
            line("Changed since the backup")
            ForEach(differences, id: \.what) { mono("\($0.what) · backup \($0.backup) · now \($0.now)") }
        case .lowVoltage(let volts): line(lowVoltage(volts))
        }
    }

    @ViewBuilder
    private func outcomeLines(_ outcome: WriteTest.Outcome) -> some View {
        switch outcome.end {
        case .accepted:
            line("Accepted · \(outcome.written) identifiers written back and read back identical", color: .vynGreen)
        case .refused(let identifier, let code):
            line("Refused at \(hex(identifier)) · \(WriteTest.describe(code)) (0x\(String(format: "%02X", code)))")
        case .mismatch(let identifier, let written, let readBack):
            line("Read back differently at \(hex(identifier))", color: .vynRed)
            mono("Written \(bytes(written))")
            mono("Read back \(bytes(readBack))")
            line("Read this module's fault codes before doing anything else.", color: .vynRed)
        case .noAnswer(let identifier):
            line("Stopped at \(hex(identifier)) after \(outcome.written) of \(outcome.total) · no answer")
        case .sessionRefused: line("Refused the extended session")
        case .notEligible: line("Not eligible for the write test")
        case .lowVoltage(let volts): line(lowVoltage(volts))
        case .changed(let identifier, let prepared, let now):
            line("Changed since the check at \(hex(identifier)), so nothing was written to it")
            mono("Checked \(bytes(prepared))")
            mono(now.map { "Now \(bytes($0))" } ?? "Now no answer")
        }
    }

    private func lowVoltage(_ volts: Double?) -> String {
        volts.map { "Battery at \($0.formatted(.number.precision(.fractionLength(1)))) V, under 12.0 V" }
            ?? "Could not read the battery voltage"
    }

    private func hex(_ identifier: UInt16) -> String { String(format: "%04X", identifier) }

    private func bytes(_ data: [UInt8]) -> String { data.map { String(format: "%02X", $0) }.joined() }

    private func line(_ text: String, color: Color = .vynMuted) -> some View {
        Text(text).font(.vyn(.footnote)).foregroundStyle(color)
    }

    private func mono(_ text: String) -> some View {
        Text(text).font(.vynMono(.footnote)).foregroundStyle(Color.vynMuted)
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
        } footer: {
            Text("Debug builds only. Logs what the module answers to F100 to F1FF.")
                .font(.vyn(.footnote))
                .foregroundStyle(Color.vynMuted)
        }
    }
}
#endif
