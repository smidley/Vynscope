import BMWCodingCore
import SwiftUI

/// The mechanic's settings, as a sheet: the API key, the model, the effort of chat turns, the prices the estimates
/// use, what a conversation sends to Anthropic, and Clear conversations. Every change is saved as it is made.
struct AISettingsView: View {
    @Environment(Flow.self) private var flow
    @Environment(AIFlow.self) private var ai
    @Environment(\.dismiss) private var dismiss
    /// The key being entered, cleared once it is saved.
    @State private var key = ""
    @State private var confirmingClear = false

    var body: some View {
        @Bindable var ai = ai
        NavigationStack {
            Form {
                Section("API key") {
                    SecureField("Anthropic API key", text: $key)
                    Button("Save key") {
                        ai.saveKey(key)
                        key = ""
                    }
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text(ai.hasKey ? "A key is saved" : "No key saved")
                        .foregroundStyle(.secondary)
                    Button("Remove key", role: .destructive) { ai.removeKey() }
                        .disabled(!ai.hasKey)
                }
                Section("Model") {
                    Picker("Model", selection: $ai.settings.model) {
                        ForEach(AISettings.models, id: \.0) { model in
                            Text(model.1).tag(model.0)
                        }
                    }
                }
                Section {
                    Picker("Effort", selection: $ai.settings.effort) {
                        ForEach(AISettings.efforts, id: \.self) { Text($0).tag($0) }
                    }
                } header: {
                    Text("Effort for chat turns")
                } footer: {
                    Text("The health-check summary always uses high.")
                }
                Section("Prices, dollars per million tokens") {
                    ForEach(AISettings.models, id: \.0) { model in
                        PriceField(label: "\(model.1) input", value: price(model.0, \.input))
                        PriceField(label: "\(model.1) output", value: price(model.0, \.output))
                        PriceField(label: "\(model.1) cache read", value: price(model.0, \.cacheRead))
                    }
                }
                Section("Privacy") {
                    Text("""
                        Each conversation sends your car's data (VIN, module identifications, fault codes and any \
                        coding bytes the mechanic reads) to Anthropic under your own API key.
                        """)
                }
                Section("Conversations") {
                    // Not while a check or a turn runs: it would save its conversation again when it ends.
                    Button("Clear conversations", role: .destructive) { confirmingClear = true }
                        .disabled(flow.busy)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Clear conversations?", isPresented: $confirmingClear) {
                Button("Clear conversations", role: .destructive) { ai.clearConversations() }
            } message: {
                Text("The saved conversations of every car are deleted.")
            }
            .onChange(of: ai.settings) { ai.saveSettings() }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 560)
        #endif
    }

    /// One price of `model` in the settings' price table.
    private func price(_ model: String, _ field: WritableKeyPath<PriceTable.Price, Double>) -> Binding<Double> {
        Binding {
            ai.settings.prices.prices[model]?[keyPath: field] ?? 0
        } set: {
            ai.settings.prices.prices[model]?[keyPath: field] = $0
        }
    }
}

/// A price in dollars per million tokens, edited as a number.
struct PriceField: View {
    let label: String
    @Binding var value: Double

    var body: some View {
        LabeledContent(label) {
            TextField(label, value: $value, format: .number)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
        }
    }
}
