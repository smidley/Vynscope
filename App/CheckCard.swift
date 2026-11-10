import BMWCodingCore
import SwiftUI

/// Check my car, the Car tab's first section: the car's nickname, then before a check the button and its hints;
/// while it runs one line per step with Stop; after it the answer in a sentence with its counts, a row per system
/// with codes and Explain it, See the codes and Check again; or a problem line with Try again, above an earlier
/// answer. While another action holds the adapter it says what runs, and its buttons wait; while the link reconnects by
/// itself it says so, and the buttons that start a check wait.
struct CheckCard: View {
    @Environment(Flow.self) private var flow

    var body: some View {
        let verdict = flow.faultReport?.verdict(silent: flow.faultSilent)
        let problem = flow.checkProblem ?? (verdict?.nothingAnswered == true ? CheckProblem.silentCar : nil)
        Section {
            if let nickname = flow.car?.nickname {
                Text(nickname)
                    .font(.vyn(.headline, weight: .semibold))
            }
            if flow.reconnecting, flow.checkStep == nil {
                HStack {
                    PulseMark(size: 14)
                    Text("Reconnecting to the adapter…")
                }
            } else if flow.busy, flow.checkStep == nil, let other {
                HStack {
                    PulseMark(size: 14)
                    Text(other)
                }
            }
            if let step = flow.checkStep {
                running(step)
            } else {
                if let problem {
                    Text(problem)
                        .foregroundStyle(Color.vynInk)
                    Button("Try again", action: check)
                        .primaryAction()
                        .disabled(cannotCheck)
                }
                if let verdict, !verdict.nothingAnswered {
                    answer(verdict, filled: problem == nil)
                } else if problem == nil {
                    Button("Check my car", action: check)
                        .primaryAction()
                        .disabled(cannotCheck)
                    hint("Plug in the adapter and switch the ignition on. Nothing on the car is changed.")
                    if UserDefaults.standard.string(forKey: Flow.adapterKey) == nil {
                        hint("""
                            The first time, tap within five minutes of plugging the adapter in. Enter 123456 if asked \
                            for a PIN.
                            """)
                    }
                }
            }
        }
    }

    private func check() { Task { await flow.checkCar() } }

    /// Whether the buttons that start a check wait: while something holds the adapter, or the link reconnects by
    /// itself, when `checkCar()` does nothing.
    private var cannotCheck: Bool { flow.busy || flow.reconnecting }

    /// What another action holding the adapter is doing: connecting, as at launch, else the flow's activity.
    private var other: String? {
        flow.link.state == .scanning || flow.link.state == .connecting ? "Connecting to the adapter…" : flow.activity
    }

    /// The steps up to `step`, each before it done, as a skipped one is, then `step` running, then Stop.
    @ViewBuilder private func running(_ step: CheckStep) -> some View {
        let steps: [CheckStep] = [.connecting, .readingCar, .findingSystems, .readingFaults]
        let index = steps.firstIndex(of: step) ?? 0
        ForEach(steps.prefix(index), id: \.self) { done in
            HStack {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.vynGreen)
                    .frame(width: 14)
                    .accessibilityHidden(true)
                doneText(done)
            }
        }
        HStack(alignment: .top) {
            PulseMark(size: 14)
            switch step {
            case .connecting: Text("Connecting to the adapter")
            case .readingCar: Text("Reading the car")
            case .findingSystems:
                // The scan's own bar, under the words.
                ProgressLine(
                    value: Double(flow.scanned), total: Double(flow.scanTotal),
                    label: flow.scanQuick
                        ? "Checking the car's systems · \(flow.scanned + 1) of \(flow.scanTotal)"
                        : "Looking for the car's systems · \(flow.modules.count) found")
            case .readingFaults: Text(flow.readingFaults ?? "")
            }
        }
        Button("Stop") { flow.stopCheck() }
    }

    /// The words of a finished or skipped step.
    @ViewBuilder private func doneText(_ step: CheckStep) -> some View {
        switch step {
        case .connecting: Text("Adapter connected")
        case .readingCar: Text("Car recognised · \(flow.car?.nickname ?? String((flow.vin ?? "").suffix(4)))")
        case .findingSystems: Text("^[\(flow.modules.count) system](inflect: true) found")
        case .readingFaults: EmptyView()
        }
    }

    /// The verdict in a sentence, green only when clean; its counts and the time in a footnote; a row per system with
    /// codes and its chips; then Explain it, filled unless a problem line above holds the filled action, See the codes
    /// and Check again.
    @ViewBuilder private func answer(_ verdict: CheckVerdict, filled: Bool) -> some View {
        Group {
            if verdict.codes == 0 {
                Text("No fault codes")
            } else {
                Text("""
                    ^[\(verdict.codes) fault code](inflect: true) in \
                    ^[\(verdict.systemsWithCodes) system](inflect: true)
                    """)
            }
        }
        .font(.vyn(.headline, weight: .semibold))
        .foregroundStyle(verdict.clean ? Color.vynGreen : Color.vynInk)
        Text(counts(verdict))
            .font(.vyn(.footnote))
            .foregroundStyle(Color.vynMuted)
        ForEach(verdict.rows.indices, id: \.self) { index in
            let row = verdict.rows[index]
            HStack {
                Text(row.name)
                Spacer()
                ForEach(row.chips, id: \.self) { FaultChipLabel(chip: $0) }
            }
        }
        if verdict.codes > 0 {
            if filled {
                Button("Explain it", action: explain)
                    .primaryAction()
                    .disabled(flow.busy)
            } else {
                Button("Explain it", action: explain)
                    .disabled(flow.busy)
            }
        }
        Button("See the codes") {
            flow.tab = .diagnostics
            flow.diagnosticsPath = []
        }
        .disabled(flow.busy)
        Button("Check again", action: check)
            .disabled(cannotCheck)
    }

    private func explain() {
        flow.tab = .diagnostics
        flow.diagnosticsPath = [.mechanic]
    }

    /// `<K> active now · <S> systems checked · <U> could not be read · <time>`, each part only where it applies.
    private func counts(_ verdict: CheckVerdict) -> AttributedString {
        var parts: [AttributedString] = []
        if verdict.active > 0 { parts.append(AttributedString(localized: "\(verdict.active) active now")) }
        parts.append(AttributedString(localized: "^[\(verdict.read) system](inflect: true) checked"))
        if verdict.unread > 0 { parts.append(AttributedString(localized: "\(verdict.unread) could not be read")) }
        if let date = flow.faultReadAt {
            parts.append(AttributedString(date.formatted(date: .omitted, time: .shortened)))
        }
        var line = AttributedString()
        for (index, part) in parts.enumerated() {
            if index > 0 { line += AttributedString(" · ") }
            line += part
        }
        return line
    }

    private func hint(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.vyn(.footnote))
            .foregroundStyle(Color.vynMuted)
    }
}
