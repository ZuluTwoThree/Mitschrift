import SwiftUI
import MitschriftCore

/// Aktionen zu einer geöffneten Aufnahme: Hinweis auf Lücken, Fortschritt, Sprecher benennen,
/// nachträglich übertragen, Protokoll erstellen, Teilen. Unter dem Blatt in der Hauptansicht
/// und in der Detailansicht aus der Liste.
struct RecordingPanel: View {
    @ObservedObject var recording: OpenRecording
    @EnvironmentObject private var settings: SettingsStore
    @State private var showSpeakers = false
    @State private var showNotes = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if recording.incomplete {
                Text(incompleteText)
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(Theme.amber)
            }
            if recording.item.needsRepair {
                Text("Die Aufnahme wurde beim letzten Mal unterbrochen und beim Start repariert.")
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(Theme.amber)
            }
            activityLine
            if let error = recording.error, recording.activity == nil {
                Text(error)
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(Theme.amber)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    if settings.isConfigured, recording.canRetranscribe {
                        Button("Nachträglich transkribieren") {
                            guard let endpoint = settings.endpoint else { return }
                            Task { await recording.retranscribe(endpoint: endpoint) }
                        }
                        .buttonStyle(PaperButtonStyle(prominent: true))
                    }
                    if settings.isConfigured, !recording.transcript.isEmpty {
                        Button {
                            if recording.notes != nil {
                                showNotes = true
                            } else {
                                createNotes()
                            }
                        } label: {
                            Label(recording.notes == nil ? "Protokoll erstellen" : "Protokoll", systemImage: "list.bullet.clipboard")
                        }
                        .buttonStyle(PaperButtonStyle(prominent: recording.notes == nil && !recording.canRetranscribe))
                    }
                    if recording.transcript.hasSpeakers {
                        Button {
                            showSpeakers = true
                        } label: {
                            Label("Sprecher benennen", systemImage: "person.2")
                        }
                        .buttonStyle(PaperButtonStyle(prominent: false))
                    }
                    shareMenu
                }
            }
            .disabled(recording.isBusy)
            .opacity(recording.isBusy ? 0.5 : 1)
        }
        .sheet(isPresented: $showSpeakers) {
            SpeakerNamesSheet(recording: recording)
        }
        .sheet(isPresented: $showNotes) {
            NotesView(recording: recording, onRecreate: createNotes)
        }
        .onChange(of: recording.notes) { old, new in
            if old == nil, new != nil { showNotes = true }
        }
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.environment["MITSCHRIFT_DEV_SHOW_NOTES"] == "1", recording.notes != nil { showNotes = true }
            #endif
        }
    }

    private func createNotes() {
        guard let endpoint = settings.endpoint else { return }
        Task { await recording.createNotes(endpoint: endpoint) }
    }

    private var incompleteText: String {
        if recording.missingSegments > 0 {
            return "Live-Übertragung unvollständig, \(recording.missingSegments) Abschnitte fehlen. Die Aufnahme ist gesichert."
        }
        return "Live-Übertragung unvollständig. Die Aufnahme ist gesichert."
    }

    @ViewBuilder
    private var activityLine: some View {
        switch recording.activity {
        case .transcribing(let progress):
            ProgressView(value: progress) {
                Text("Aufnahme wird nachträglich übertragen")
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(Theme.mist)
            }
            .tint(Theme.mint)
        case .writingNotes:
            HStack(spacing: 8) {
                ProgressView().tint(Theme.mint)
                Text("Der Assistent liest die Mitschrift und schreibt das Protokoll. Das dauert je nach Länge bis zu einigen Minuten.")
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(Theme.mist)
            }
        case nil:
            EmptyView()
        }
    }

    private var shareMenu: some View {
        Menu {
            if let url = recording.item.transcriptTextURL {
                ShareLink(item: url) { Label("Mitschrift als Text", systemImage: "doc.text") }
            }
            if let url = recording.item.notesURL {
                ShareLink(item: url) { Label("Protokoll", systemImage: "list.bullet.clipboard") }
            }
            ShareLink(item: recording.item.audioURL) { Label("Audio", systemImage: "waveform") }
        } label: {
            Label("Teilen", systemImage: "square.and.arrow.up")
        }
        .buttonStyle(PaperButtonStyle(prominent: false))
    }
}

/// Ruhige Knöpfe auf dem Blatt: Umriss in Nebel, hervorgehoben in Mint.
struct PaperButtonStyle: ButtonStyle {
    var prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Fonts.footnote.weight(.semibold))
            .foregroundStyle(prominent ? Theme.night : Theme.paper)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(prominent ? Theme.mint : Theme.ink)
            )
            .overlay(Capsule().strokeBorder(prominent ? Color.clear : Theme.mist.opacity(0.35)))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
