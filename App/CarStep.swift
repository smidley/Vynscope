import SwiftUI

/// Reads the VIN and names a car the first time it shows up.
struct CarStep: View {
    @Environment(Flow.self) private var flow

    var body: some View {
        Form {
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
