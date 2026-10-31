import BMWCodingCore
import SwiftUI

/// The AI mechanic, pushed from Fault codes: the notice to sign in, Not connected, the health check as it runs, or
/// the chat about the connected car, with New conversation in the toolbar. Opening it hands the conversation a fresh
/// fault read (`AIFlow.handFaults()`); leaving it stops nothing.
struct MechanicView: View {
    @Environment(Flow.self) private var flow
    @Environment(AIFlow.self) private var ai
    @State private var confirmingNew = false

    var body: some View {
        // One container for every state, so that `.task` and `.onDisappear` follow the screen, not the state.
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
            } else if flow.diag == nil || flow.gaveUp {
                Form { Text("Not connected") }
                    .formStyle(.grouped)
            } else if case .checking(let step) = ai.phase {
                Form {
                    Section {
                        ProgressView(flow.reconnecting ? "Reconnecting to the adapter…" : step)
                        Button("Stop") { ai.stop() }
                    }
                }
                .formStyle(.grouped)
            } else if ai.phase == .idle, ai.conversation == nil {
                Form {
                    Section {
                        Button("Run health check") { Task { await ai.healthCheck() } }
                            .disabled(flow.busy)
                        if let error = ai.error {
                            Text(error).foregroundStyle(.red)
                        }
                    }
                }
                .formStyle(.grouped)
            } else {
                ChatView()
            }
        }
        // Ivory under every state: the forms' own background hidden, the chat on it.
        .scrollContentBackground(.hidden)
        .background(Color.vynIvory)
        .connectionLine()
        .navigationTitle("Mechanic")
        .task {
            ai.mechanicVisible = true
            await ai.enter()
            await ai.handFaults()
        }
        // Leaving the screen, for Fault codes or another tab, stops nothing: a check or a turn runs on until its Stop.
        .onDisappear { ai.mechanicVisible = false }
        .toolbar {
            ToolbarItem {
                Button("New conversation", systemImage: "square.and.pencil") { confirmingNew = true }
                    .disabled(flow.busy || flow.diag == nil || flow.gaveUp || !ai.hasCredentials)
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
