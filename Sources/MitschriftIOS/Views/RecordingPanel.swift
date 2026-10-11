import SwiftUI
import MitschriftCore

/// Aktionen zu einer geöffneten Aufnahme: Hinweis auf Lücken, Fortschritt, Mitschrift bearbeiten,
/// nachträglich übertragen, Protokoll oder Zusammenfassung erstellen, Sprecher benennen, Teilen.
/// Unter dem Blatt in der Hauptansicht und in der Detailansicht aus der Liste.
struct RecordingPanel: View {
    @ObservedObject var recording: OpenRecording
    @EnvironmentObject private var settings: SettingsStore
    @State private var showSpeakers = false
    @State private var showEditor = false
    @State private var confirmRefine = false
    @State private var notesSheet: NotesKind?

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
            if let model = recording.refinedModel, recording.activity == nil {
                Text("Genaue Fassung, transkribiert mit \(RefineJob.displayName(forModel: model)).")
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(Theme.mist)
            }
            if let outdatedText {
                Text(outdatedText)
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
                    if settings.isConfigured, recording.refinedModel == nil || recording.canRetranscribe {
                        Button {
                            if recording.transcript.isEmpty { refine() } else { confirmRefine = true }
                        } label: {
                            Label("Genau transkribieren", systemImage: "waveform.badge.magnifyingglass")
                        }
                        .buttonStyle(PaperButtonStyle(prominent: recording.canRetranscribe))
                        .disabled(recording.audioLocked)
                    }
                    if !recording.transcript.isEmpty {
                        Button {
                            showEditor = true
                        } label: {
                            Label("Bearbeiten", systemImage: "scissors")
                        }
                        .buttonStyle(PaperButtonStyle(prominent: false))
                    }
                    if settings.isConfigured, !recording.transcript.isEmpty {
                        ForEach(NotesKind.allCases) { kind in
                            notesButton(kind)
                        }
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
        .confirmationDialog(refineQuestion, isPresented: $confirmRefine, titleVisibility: .visible) {
            Button("Genau transkribieren", action: refine)
            Button("Abbrechen", role: .cancel) {}
        }
        .onChange(of: recording.isBusy) { _, busy in
            // Upload und Rechnen auf dem Server dauern bei langen Aufnahmen Minuten; die Sperre würde
            // die App anhalten und den Auftrag abreißen lassen.
            UIApplication.shared.isIdleTimerDisabled = busy
        }
        .sheet(isPresented: $showSpeakers) {
            SpeakerNamesSheet(recording: recording)
        }
        .sheet(isPresented: $showEditor) {
            TranscriptEditorView(recording: recording)
        }
        .sheet(item: $notesSheet) { kind in
            NotesView(recording: recording, kind: kind)
        }
        .onChange(of: recording.texts) { old, new in
            // Ein frisch erstellter Text öffnet sich von selbst.
            if let kind = NotesKind.allCases.first(where: { old[$0] == nil && new[$0] != nil }) { notesSheet = kind }
        }
        .onAppear {
            #if DEBUG
            let environment = ProcessInfo.processInfo.environment
            switch environment["MITSCHRIFT_DEV_SHOW_NOTES"] {
            case "1" where recording.text(.minutes) != nil: notesSheet = .minutes
            case "summary" where recording.text(.summary) != nil: notesSheet = .summary
            default: break
            }
            if let flag = environment["MITSCHRIFT_DEV_SHOW_EDITOR"], !flag.isEmpty, !recording.transcript.isEmpty { showEditor = true }
            // Startet „Genau transkribieren“ ohne Rückfrage (Test gegen einen echten Server im Simulator).
            if environment["MITSCHRIFT_DEV_REFINE"] == "1", recording.activity == nil { refine() }
            #endif
        }
    }

    private func refine() {
        guard let endpoint = settings.endpoint else { return }
        Task { await recording.refine(endpoint: endpoint) }
    }

    private var refineQuestion: String {
        var text = "Der Server transkribiert die ganze Aufnahme noch einmal mit einem genaueren Modell, das auch Dialekte und Namen besser erkennt. Die Mitschrift wird dann ersetzt."
        if !recording.texts.isEmpty {
            text += " Vorhandene Protokolle und Zusammenfassungen lassen sich danach neu erstellen."
        }
        text += " Eigene Textkorrekturen gehen verloren; nur aus der Audiodatei entfernte Stellen bleiben entfernt."
        return text
    }

    private func notesButton(_ kind: NotesKind) -> some View {
        let exists = recording.text(kind) != nil
        return Button {
            if exists {
                notesSheet = kind
            } else {
                guard let endpoint = settings.endpoint else { return }
                Task { await recording.createNotes(kind: kind, endpoint: endpoint) }
            }
        } label: {
            Label(exists ? kind.title : "\(kind.title) erstellen", systemImage: Self.icon(for: kind))
        }
        // Hervorgehoben nur der naheliegende nächste Schritt: ein Protokoll, solange es noch keinen Text gibt.
        .buttonStyle(PaperButtonStyle(prominent: kind == .minutes && recording.texts.isEmpty && !recording.canRetranscribe))
    }

    static func icon(for kind: NotesKind) -> String {
        switch kind {
        case .minutes: return "list.bullet.clipboard"
        case .summary: return "text.book.closed"
        }
    }

    private var incompleteText: String {
        if recording.missingSegments > 0 {
            return "Live-Übertragung unvollständig, \(recording.missingSegments) Abschnitte fehlen. Die Aufnahme ist gesichert."
        }
        return "Live-Übertragung unvollständig. Die Aufnahme ist gesichert."
    }

    private var outdatedText: String? {
        let kinds = NotesKind.allCases.filter { recording.outdated.contains($0) && recording.text($0) != nil }
        guard !kinds.isEmpty else { return nil }
        let names = kinds.map(\.title).joined(separator: " und ")
        return "\(names) \(kinds.count > 1 ? "stammen" : "stammt") noch aus der Mitschrift vor der Bearbeitung. Zum Aktualisieren öffnen und neu erstellen."
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
        case .writing(let kind):
            HStack(spacing: 8) {
                ProgressView().tint(Theme.mint)
                Text(kind == .summary
                     ? "Der Assistent liest die Mitschrift und schreibt die Zusammenfassung. Bei langen Aufnahmen dauert das einige Minuten."
                     : "Der Assistent liest die Mitschrift und schreibt das Protokoll. Das dauert je nach Länge bis zu einigen Minuten.")
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(Theme.mist)
            }
        case .refining(let stage):
            refiningLine(stage)
        case .editing:
            HStack(spacing: 8) {
                ProgressView().tint(Theme.mint)
                Text("Aufnahme wird gekürzt …")
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(Theme.mist)
            }
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private func refiningLine(_ stage: OpenRecording.RefineStage) -> some View {
        switch stage {
        case .uploading(let fraction):
            ProgressView(value: fraction) {
                Text("Aufnahme wird zum Server hochgeladen")
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(Theme.mist)
            }
            .tint(Theme.mint)
        case .queued:
            HStack(spacing: 8) {
                ProgressView().tint(Theme.mint)
                Text("Wartet auf dem Server, bis ein anderer Auftrag fertig ist …")
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(Theme.mist)
            }
        case .processing(let phase, let elapsed):
            HStack(spacing: 8) {
                ProgressView().tint(Theme.mint)
                Text("\(Self.phaseText(phase)) (\(RecordingNaming.elapsedText(elapsed)))")
                    .font(Theme.Fonts.footnote.monospacedDigit())
                    .foregroundStyle(Theme.mist)
            }
        }
    }

    private static func phaseText(_ phase: String?) -> String {
        switch phase {
        case "decoding": return "Der Server bereitet die Aufnahme vor"
        case "diarizing": return "Der Server ordnet die Sprecher zu"
        default: return "Der Server transkribiert genau"
        }
    }

    private var shareMenu: some View {
        Menu {
            if let url = recording.item.transcriptTextURL {
                ShareLink(item: url) { Label("Mitschrift als Text", systemImage: "doc.text") }
            }
            ForEach(NotesKind.allCases) { kind in
                if let url = recording.item.url(for: kind) {
                    ShareLink(item: url) { Label(kind.title, systemImage: Self.icon(for: kind)) }
                }
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
