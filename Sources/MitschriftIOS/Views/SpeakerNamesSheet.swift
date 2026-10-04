import SwiftUI
import MitschriftCore

/// Sprecher benennen: je Label ein Feld, daneben die ersten Worte dieses Sprechers zur Orientierung.
struct SpeakerNamesSheet: View {
    @ObservedObject var recording: OpenRecording
    @Environment(\.dismiss) private var dismiss
    @State private var names: [String: String] = [:]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(recording.transcript.speakerLabels, id: \.self) { label in
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Sprecher \(label)", text: binding(for: label))
                                .textInputAutocapitalization(.words)
                                .autocorrectionDisabled()
                                .font(Theme.Fonts.button)
                            Text(sample(for: label))
                                .font(Theme.Fonts.footnote)
                                .foregroundStyle(Theme.mist)
                                .lineLimit(2)
                        }
                        .padding(.vertical, 2)
                    }
                } footer: {
                    Text("Die Namen stehen in der Mitschrift, im Export und im Protokoll. Leer lassen behält „Sprecher N“.")
                }
            }
            .navigationTitle("Sprecher")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        recording.rename(speakers: names)
                        dismiss()
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.night)
            .tint(Theme.coral)
        }
        .preferredColorScheme(.dark)
        .onAppear { names = recording.transcript.speakerNames }
    }

    private func binding(for label: String) -> Binding<String> {
        Binding(get: { names[label] ?? "" }, set: { names[label] = $0 })
    }

    /// Der Anfang des ersten längeren Beitrags dieses Sprechers.
    private func sample(for label: String) -> String {
        let texts = recording.transcript.paragraphs.filter { $0.label == label }.map(\.text)
        let chosen = texts.first { $0.count > 40 } ?? texts.first ?? ""
        return "„\(chosen.prefix(90))\(chosen.count > 90 ? " …" : "")“"
    }
}
