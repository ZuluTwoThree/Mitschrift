import SwiftUI
import MitschriftCore

/// Ziele in der Aufnahmenliste: die Aufnahme selbst oder direkt ihr Protokoll bzw. ihre Zusammenfassung.
enum RecordingRoute: Hashable {
    case detail(String)
    case notes(String, NotesKind)
}

/// Alle gespeicherten Aufnahmen: öffnen, Protokoll oder Zusammenfassung direkt aufrufen, löschen, aufräumen.
struct RecordingsListView: View {
    @EnvironmentObject private var library: RecordingLibraryModel
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<String> = []
    @State private var editMode: EditMode = .inactive
    @State private var confirmDelete = false
    @State private var path: [RecordingRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if library.items.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .background(Theme.night)
            .navigationTitle("Aufnahmen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !library.items.isEmpty {
                        EditButton()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if editMode.isEditing, !selection.isEmpty {
                        Button("Löschen", role: .destructive) { confirmDelete = true }
                    } else {
                        Button("Fertig") { dismiss() }
                    }
                }
            }
            .environment(\.editMode, $editMode)
            .confirmationDialog("\(selection.count) Aufnahmen samt Mitschrift, Protokoll und Zusammenfassung löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Löschen", role: .destructive) {
                    library.delete(ids: selection)
                    selection = []
                    editMode = .inactive
                }
                Button("Abbrechen", role: .cancel) {}
            }
            .tint(Theme.coral)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            library.reload()
            #if DEBUG
            // Für Gestaltungs-Screenshots: `SIMCTL_CHILD_MITSCHRIFT_DEV_SHOW_RECORDINGS=detail|notes|summary` öffnet die neueste Aufnahme.
            if let first = library.items.first {
                switch ProcessInfo.processInfo.environment["MITSCHRIFT_DEV_SHOW_RECORDINGS"] {
                case "detail": path = [.detail(first.id)]
                case "notes": path = [.notes(first.id, .minutes)]
                case "summary": path = [.notes(first.id, .summary)]
                default: break
                }
            }
            #endif
        }
    }

    private var list: some View {
        List(selection: $selection) {
            Section {
                ForEach(library.items) { item in
                    NavigationLink(value: RecordingRoute.detail(item.id)) {
                        RecordingRow(item: item) { kind in
                            path.append(.notes(item.id, kind))
                        }
                    }
                    .listRowBackground(Theme.ink)
                }
                .onDelete { offsets in
                    for index in offsets { library.delete(library.items[index]) }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(library.items.count) Aufnahmen, \(RecordingLibraryModel.sizeText(library.totalBytes)) auf diesem iPhone.")
                    Text("Zum Aufräumen „Bearbeiten“ wählen, mehrere Aufnahmen markieren und löschen. Gelöscht wird immer alles zusammen: Audio, Mitschrift, Protokoll und Zusammenfassung.")
                    if let error = library.error {
                        Text(error).foregroundStyle(Theme.amber)
                    }
                }
                .font(Theme.Fonts.footnote)
                .foregroundStyle(Theme.mist)
            }
        }
        .scrollContentBackground(.hidden)
        .navigationDestination(for: RecordingRoute.self) { route in
            switch route {
            case .detail(let id):
                if let item = library.items.first(where: { $0.id == id }) {
                    RecordingDetailView(item: item)
                }
            case .notes(let id, let kind):
                if let item = library.items.first(where: { $0.id == id }) {
                    RecordingNotesView(item: item, kind: kind)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 36))
                .foregroundStyle(Theme.mist)
            Text("Noch keine Aufnahmen. Jede Aufnahme landet hier, mit Mitschrift, Protokoll und Zusammenfassung.")
                .font(Theme.Fonts.status)
                .foregroundStyle(Theme.mist)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Eine Zeile der Liste: Zeitpunkt, Dauer und Größe, Marken für Mitschrift, Protokoll und
/// Zusammenfassung. Die Marken der Texte sind Knöpfe und öffnen den Text direkt.
struct RecordingRow: View {
    var item: RecordingItem
    var onOpenNotes: (NotesKind) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.createdAt, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated).year().hour().minute())
                .font(Theme.Fonts.status)
                .foregroundStyle(Theme.paper)
            Text(detailText)
                .font(Theme.Fonts.footnote)
                .foregroundStyle(Theme.mist)
            HStack(spacing: 6) {
                if item.needsRepair {
                    badge("unterbrochen", color: Theme.amber)
                }
                if item.hasTranscript {
                    badge("Mitschrift", color: Theme.mint)
                }
                ForEach(NotesKind.allCases) { kind in
                    if item.url(for: kind) != nil {
                        Button { onOpenNotes(kind) } label: {
                            badge(kind.title, color: Theme.mint, filled: true)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("\(kind.title) öffnen")
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var detailText: String {
        var parts: [String] = []
        if let duration = item.duration { parts.append(RecordingNaming.elapsedText(duration)) }
        parts.append(RecordingLibraryModel.sizeText(item.fileSize))
        parts.append(item.audioURL.pathExtension.uppercased())
        return parts.joined(separator: ", ")
    }

    private func badge(_ text: String, color: Color, filled: Bool = false) -> some View {
        Text(text)
            .lineLimit(1)
            .fixedSize()
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(filled ? Theme.night : color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(filled ? color : Color.clear, in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(filled ? 0 : 0.6)))
    }
}

/// Eine Aufnahme aus der Liste: das Blatt mit den gleichen Aktionen wie nach dem Stoppen.
struct RecordingDetailView: View {
    @StateObject private var recording: OpenRecording
    @EnvironmentObject private var library: RecordingLibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    init(item: RecordingItem) {
        let directory = item.audioURL.deletingLastPathComponent()
        _recording = StateObject(wrappedValue: OpenRecording(item: item, language: "de", library: RecordingLibrary(directory: directory)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TranscriptPaper(transcript: recording.transcript,
                            emptyText: recording.item.hasTranscript ? "Die Mitschrift ist leer." : "Zu dieser Aufnahme gibt es noch keine Mitschrift.")
                .padding(.horizontal, Theme.gutter)
            RecordingPanel(recording: recording)
                .padding(.horizontal, Theme.gutter)
                .padding(.bottom, 12)
        }
        .themedScreen()
        .navigationTitle(recording.createdAt.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(recording.isBusy)
            }
        }
        .confirmationDialog("Aufnahme samt Mitschrift, Protokoll und Zusammenfassung löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                library.delete(recording.item)
                dismiss()
            }
            Button("Abbrechen", role: .cancel) {}
        }
        .onDisappear { library.reload() }
    }
}

/// Protokoll oder Zusammenfassung einer Aufnahme aus der Liste, ohne Umweg über die Detailansicht.
struct RecordingNotesView: View {
    @StateObject private var recording: OpenRecording
    let kind: NotesKind

    init(item: RecordingItem, kind: NotesKind) {
        self.kind = kind
        let directory = item.audioURL.deletingLastPathComponent()
        _recording = StateObject(wrappedValue: OpenRecording(item: item, language: "de", library: RecordingLibrary(directory: directory)))
    }

    var body: some View {
        NotesScreen(recording: recording, kind: kind)
            .themedScreen()
    }
}
