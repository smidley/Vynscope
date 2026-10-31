import BMWCodingCore
import SwiftUI

/// The mechanic's settings, the Settings tab: the provider, its sign-in (the Anthropic API key, or the ChatGPT
/// sign-in), its model, the effort of chat turns, the prices the estimates use (Anthropic's), what a conversation sends
/// and to whom, and Clear conversations; on the Mac, last, the app folder. Every change is saved as it is made. The
/// error, when there is one, shows under the sign-in and under Clear conversations.
struct AISettingsView: View {
    @Environment(Flow.self) private var flow
    @Environment(AIFlow.self) private var ai
    /// The key being entered, cleared once it is saved.
    @State private var key = ""
    @State private var confirmingClear = false

    var body: some View {
        @Bindable var ai = ai
        Form {
            Section("AI provider") {
                Picker("Provider", selection: $ai.settings.provider) {
                    ForEach(Provider.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                // Not while a check or a turn runs: it answers in the conversation of the provider it started on.
                .disabled(flow.busy)
            }
            switch ai.settings.provider {
            case .anthropic: apiKeySection
            case .openai: chatGPTSection
            }
            Section("Model") {
                switch ai.settings.provider {
                case .anthropic:
                    Picker("Model", selection: $ai.settings.model) {
                        ForEach(AISettings.models, id: \.0) { model in
                            Text(model.1).tag(model.0)
                        }
                    }
                case .openai:
                    Picker("Model", selection: $ai.settings.openAIModel) {
                        ForEach(ai.openAIModels, id: \.id) { model in
                            Text(model.name).tag(Optional(model.id))
                        }
                    }
                    .disabled(ai.chatGPT == nil)
                    if ai.chatGPT == nil {
                        Text("Sign in to see your models")
                            .foregroundStyle(Color.vynMuted)
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
                    .font(.vyn(.footnote))
                    .foregroundStyle(Color.vynMuted)
            }
            if ai.settings.provider == .anthropic {
                Section("Prices, dollars per million tokens") {
                    ForEach(AISettings.models, id: \.0) { model in
                        PriceField(label: "\(model.1) input", value: price(model.0, \.input))
                        PriceField(label: "\(model.1) output", value: price(model.0, \.output))
                        PriceField(label: "\(model.1) cache read", value: price(model.0, \.cacheRead))
                    }
                }
            }
            Section("Privacy") {
                switch ai.settings.provider {
                case .anthropic:
                    Text("""
                        Each conversation sends your car's data (VIN, module identifications, fault codes and any \
                        coding bytes the mechanic reads) to Anthropic under your own API key.
                        """)
                case .openai:
                    Text("""
                        Each conversation sends your car's data (VIN, module identifications, fault codes and any \
                        coding bytes the mechanic reads) to OpenAI on your ChatGPT plan.
                        """)
                }
            }
            Section("Conversations") {
                // Not while a check or a turn runs: it would save its conversation again when it ends.
                Button("Clear conversations", role: .destructive) { confirmingClear = true }
                    .disabled(flow.busy)
                errorLine
            }
            #if os(macOS)
            Section {
                Text(flow.appFolder().path)
                    .font(.vyn(.caption))
                    .textSelection(.enabled)
                // As on Backups: a backup runs on into the folder it started in.
                Button("Choose folder") { flow.chooseFolder() }
                    .disabled(flow.backupTask != nil)
            } header: {
                Text("App folder")
            } footer: {
                Text("Backups, the car book and the conversations are kept here; the log from the next launch.")
                    .font(.vyn(.footnote))
                    .foregroundStyle(Color.vynMuted)
            }
            #endif
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color.vynIvory)
        .connectionLine()
        .confirmationDialog("Clear conversations?", isPresented: $confirmingClear) {
            Button("Clear conversations", role: .destructive) { ai.clearConversations() }
        } message: {
            Text("The saved \(ai.settings.provider.displayName) conversations of every car are deleted.")
        }
        .onChange(of: ai.settings) { ai.saveSettings() }
        .onChange(of: ai.settings.provider) { ai.switchProvider() }
        // Every time the tab opens, and when OpenAI is picked in it: the account's models may have changed.
        .task(id: ai.settings.provider) {
            if ai.settings.provider == .openai, ai.chatGPT != nil {
                await ai.loadOpenAIModels()
            }
        }
        .sheet(isPresented: $ai.showWelcome) { ChatGPTWelcome() }
        #if os(iOS)
        .sheet(item: $ai.signInURL, onDismiss: { ai.cancelSignIn() }) { url in
            ChatGPTBrowser.SafariSheet(url: url)
        }
        #endif
    }

    /// The Anthropic API key: entered, saved, removed.
    private var apiKeySection: some View {
        Section("API key") {
            SecureField("Anthropic API key", text: $key)
            Button("Save key") {
                ai.saveKey(key)
                key = ""
            }
            .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Text(ai.hasKey ? "A key is saved" : "No key saved")
                .foregroundStyle(Color.vynMuted)
            Button("Remove key", role: .destructive) { ai.removeKey() }
                .disabled(!ai.hasKey)
            errorLine
        }
    }

    /// The ChatGPT sign-in: Continue with ChatGPT, which a sign-in without plan usage shows again, Cancel while it
    /// waits for the browser, `Completing sign-in…` once the redirect is in, and the account with Sign out.
    private var chatGPTSection: some View {
        Section("ChatGPT") {
            if let account = ai.chatGPT {
                // The email is empty when the ID token carried none.
                let signedIn = account.email.isEmpty ? "Signed in" : "Signed in as \(account.email)"
                if account.mayUsePlan {
                    Text(signedIn)
                } else {
                    Text("\(signedIn), but Vynscope may not use your ChatGPT plan")
                    Text("Disconnect Vynscope in ChatGPT Settings, then sign in again and allow plan usage.")
                        .foregroundStyle(Color.vynMuted)
                }
            }
            if ai.signInPhase == .completing {
                Text("Completing sign-in…")
            } else if ai.chatGPT?.mayUsePlan != true {
                HStack {
                    ContinueWithChatGPT { Task { await ai.signInToChatGPT() } }
                        .disabled(ai.signInPhase != .idle || ai.signingOut)
                    if ai.signInPhase == .waitingForBrowser {
                        Button("Cancel") { ai.cancelSignIn() }
                            .buttonStyle(.borderless)
                    }
                }
            }
            if ai.chatGPT != nil {
                Button(ai.signingOut ? "Signing out…" : "Sign out", role: .destructive) {
                    Task { await ai.signOutOfChatGPT() }
                }
                .disabled(ai.signInPhase != .idle || ai.signingOut)
            }
            errorLine
        }
    }

    /// `ai.error` in red, when it is set.
    @ViewBuilder private var errorLine: some View {
        if let error = ai.error {
            Text(error).foregroundStyle(.red)
        }
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

/// OpenAI's sign-in button: `Continue with ChatGPT` after the white ChatGPT logo, white on black, dimmed while it is
/// disabled.
struct ContinueWithChatGPT: View {
    @Environment(\.isEnabled) private var isEnabled
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                Text("Continue with ChatGPT")
                    .fontWeight(.medium)
            } icon: {
                Image("ChatGPTLogo")
            }
            .labelStyle(.titleAndIcon)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.black, in: .capsule)
            .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
    }
}

/// The welcome to plan usage, once, after the first sign-in that allows it.
struct ChatGPTWelcome: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("You're using your ChatGPT plan")
                .font(.vyn(.headline, weight: .semibold))
            Text("Eligible AI requests in Vynscope use your ChatGPT plan. You can manage usage in ChatGPT settings.")
                .multilineTextAlignment(.center)
            Link("Manage usage", destination: ChatGPTBrowser.usagePage)
            Button("Got it") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
        #if os(macOS)
        .frame(width: 380)
        #endif
        .presentationDetents([.medium])
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
