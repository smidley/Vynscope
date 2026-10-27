import SwiftUI

@main
struct BMWCodingApp: App {
    @State private var flow = Flow()

    var body: some Scene {
        WindowGroup {
            FlowView()
                .environment(flow)
        }
        #if os(macOS)
        .defaultSize(width: 420, height: 760)
        #endif

        #if os(macOS)
        // One log window: Log brings it to the front rather than opening another.
        Window("Log", id: "log") {
            LogView()
                .environment(flow)
        }
        #endif
    }
}

/// The current step under the step indicator, with Back, Log and Next in the toolbar.
struct FlowView: View {
    @Environment(Flow.self) private var flow

    var body: some View {
        @Bindable var flow = flow
        NavigationStack {
            VStack(spacing: 0) {
                StepIndicator(current: flow.step)
                if let error = flow.error {
                    Text(error)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                }
                switch flow.step {
                case .connect: ConnectStep()
                default: Spacer()
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .navigationTitle(Text(flow.step.title))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                if flow.step != .connect {
                    ToolbarItem(placement: .navigation) {
                        Button("Back") { flow.back() }
                    }
                }
                ToolbarItem { LogButton() }
                ToolbarItem(placement: .primaryAction) {
                    Button(flow.step == .backup ? "Done" : "Next") { flow.next() }
                        .disabled(!flow.canGoNext)
                }
            }
        }
        #if os(iOS)
        .sheet(isPresented: $flow.showingLog) {
            NavigationStack { LogView() }
        }
        #endif
    }
}

/// The four steps by title, the current one bold.
struct StepIndicator: View {
    let current: Step

    var body: some View {
        HStack {
            ForEach(Step.allCases, id: \.self) { step in
                Text("\(step.rawValue + 1) \(step.title)")
                    .fontWeight(step == current ? .bold : .regular)
                    .foregroundStyle(step == current ? .primary : .secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .font(.caption)
        .padding(.vertical, 8)
    }
}
