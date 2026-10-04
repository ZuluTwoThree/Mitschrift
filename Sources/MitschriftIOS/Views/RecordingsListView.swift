import SwiftUI
import MitschriftCore

/// Alle gespeicherten Aufnahmen: öffnen, teilen, löschen, aufräumen.
struct RecordingsListView: View {
    @EnvironmentObject private var library: RecordingLibraryModel
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<String> = []
    @State private var editMode: EditMode = .inactive
    @State private var confirmDelete = false
    @State private var path: [String] = []

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
            .confirmationDialog("\(selection.count) Aufnahmen samt Mitschrift und Protokoll löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
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
            // Für Gestaltungs-Screenshots: `SIMCTL_CHILD_MITSCHRIFT_DEV_SHOW_RECORDINGS=detail` öffnet die neueste Aufnahme.
            if ProcessInfo.processInfo.environment["MITSCHRIFT_DEV_SHOW_RECORDINGS"] == "detail", let first = library.items.first {
                path = [first.id]
            }
            #endif
        }
    }

    private var list: some View {
        List(selection: $selection) {
            Section {
                ForEach(library.items) { item in
                    NavigationLink(value: item.id) {
                        RecordingRow(item: item)
                    }
                    .listRowBackground(Theme.ink)
                }
                .onDelete { offsets in
                    for index in offsets { library.delete(library.items[index]) }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(library.items.count) Aufnahmen, \(RecordingLibraryModel.sizeText(library.totalBytes)) auf diesem iPhone.")
                    Text("Zum Aufräumen „Bearbeiten“ wählen, mehrere Aufnahmen markieren und löschen. Gelöscht wird immer Audio, Mitschrift und Protokoll zusammen.")
                    if let error = library.error {
                        Text(error).foregroundStyle(Theme.amber)
                    }
                }
                .font(Theme.Fonts.footnote)
                .foregroundStyle(Theme.mist)
            }
        }
        .scrollContentBackground(.hidden)
        .navigationDestination(for: String.self) { id in
            if let item = library.items.first(where: { $0.id == id }) {
                RecordingDetailView(item: item)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 36))
                .foregroundStyle(Theme.mist)
            Text("Noch keine Aufnahmen. Jede Aufnahme landet hier, mit Mitschrift und Protokoll.")
                .font(Theme.Fonts.status)
                .foregroundStyle(Theme.mist)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Eine Zeile der Liste: Zeitpunkt, Dauer und Größe, Marken für Mitschrift und Protokoll.
struct RecordingRow: View {
    var item: RecordingItem

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(item.createdAt, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated).year().hour().minute())
                .font(Theme.Fonts.status)
                .foregroundStyle(Theme.paper)
            HStack(spacing: 8) {
                Text(detailText)
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(Theme.mist)
                Spacer(minLength: 4)
                if item.needsRepair {
                    badge("unterbrochen", color: Theme.amber)
                }
                if item.hasTranscript {
                    badge("Mitschrift", color: Theme.mint)
                }
                if item.hasNotes {
                    badge("Protokoll", color: Theme.mint)
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

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .overlay(Capsule().strokeBorder(color.opacity(0.6)))
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
        .confirmationDialog("Aufnahme samt Mitschrift und Protokoll löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                library.delete(recording.item)
                dismiss()
            }
            Button("Abbrechen", role: .cancel) {}
        }
        .onDisappear { library.reload() }
    }
}
