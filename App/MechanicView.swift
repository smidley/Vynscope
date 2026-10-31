import BMWCodingCore
import SwiftUI

/// The AI mechanic, pushed from Fault codes: the notice to sign in, the chat about the car, which stays readable
/// whatever the link does, Not connected, No car read, the health check as it runs, or Run health check, with New
/// conversation in the toolbar. Its first appearance runs the health check when the car has no conversation yet; every
/// appearance hands the conversation a fresh fault read (`AIFlow.handFaults()`). Leaving it stops nothing.
struct MechanicView: View {
    @Environment(Flow.self) private var flow
    @Environment(AIFlow.self) private var ai
    @State private var confirmingNew = false
    /// The screen appeared before: a return to it, from another tab, runs no health check by itself.
    @State private var entered = false

    var body: some View {
        // One container for every state, so that `.task` follows the screen, not the state.
        VStack(spacing: 0) {
            if !ai.hasCredentials {
                Form {
                    Section {
                        switch ai.settings.provider {
                        case .anthropic: Text("Enter your Anthropic API key in Settings to switch on the AI mechanic.")
                        case .openai: Text("Sign in to ChatGPT in Settings to switch on the AI mechanic.")
                        }
                        Button("Settings") { flow.tab = .settings }
                    }
                }
                .formStyle(.grouped)
            } else if ai.conversation != nil && ai.conversation?.vin == flow.vin {
                // Whatever the link: the connection line says how it is, and Send waits for the car.
                ChatView()
            } else if flow.diag == nil || flow.gaveUp {
                Form { Text("Not connected") }
                    .formStyle(.grouped)
            } else if flow.vin == nil {
                Form { Text("No car read. Turn the ignition on and read it on the Car tab.") }
                    .formStyle(.grouped)
            } else if case .checking(let step) = ai.phase {
                Form {
                    Section {
                        HStack {
                            PulseMark()
                            Text(flow.reconnecting ? "Reconnecting to the adapter…" : step)
                        }
                        Button("Stop") { ai.stop() }
                    }
                }
                .formStyle(.grouped)
            } else {
                Form {
                    Section {
                        // The check's own scan, when no module was listed.
                        if flow.discovering {
                            ScanProgress()
                        }
                        Button("Run health check") { Task { await ai.healthCheck() } }
                            .disabled(flow.busy)
                        if let error = ai.error {
                            Text(error).foregroundStyle(.red)
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
        // Ivory under every state: the forms' own background hidden, the chat on it.
        .scrollContentBackground(.hidden)
        .background(Color.vynIvory)
        .connectionLine()
        .navigationTitle("Mechanic")
        // Leaving the screen, for Fault codes or another tab, stops nothing: a check or a turn runs on until its Stop.
        .task {
            let first = !entered
            entered = true
            await ai.enter(runningCheck: first)
            await ai.handFaults()
        }
        .toolbar {
            ToolbarItem {
                Button("New conversation", systemImage: "square.and.pencil") { confirmingNew = true }
                    .disabled(flow.busy || flow.diag == nil || flow.gaveUp || flow.vin == nil || !ai.hasCredentials)
            }
            ToolbarItem { LogButton() }
        }
        .confirmationDialog("Start a new conversation?", isPresented: $confirmingNew) {
            Button("New conversation", role: .destructive) { Task { await ai.newConversation() } }
        } message: {
            Text("This car's conversation is deleted and the health check runs again.")
        }
    }
}
