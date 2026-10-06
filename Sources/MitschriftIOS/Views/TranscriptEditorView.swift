import SwiftUI
import MitschriftCore

/// Mitschrift kürzen und korrigieren, bevor sie weiterverarbeitet wird: Abschnitte entfernen (etwa
/// ein Nebengespräch, weil die Aufnahme weiterlief), Texte korrigieren und die entfernten Stellen
/// auf Wunsch auch aus der Audiodatei nehmen. Erst „Sichern“ übernimmt die Änderungen.
struct TranscriptEditorView: View {
    @ObservedObject var recording: OpenRecording
    @Environment(\.dismiss) private var dismiss

    /// Ein behaltener Abschnitt; `id` ist sein Index in der ursprünglichen Mitschrift.
    struct Entry: Identifiable, Equatable {
        let id: Int
        var segment: Segment
    }

    @State private var entries: [Entry] = []
    @State private var history: [[Entry]] = []
    @State private var selection: Set<Int> = []
    @State private var editMode: EditMode = .inactive
    @State private var cutAudio = true
    @State private var correcting: Entry?
    @State private var confirmDiscard = false
    @State private var confirmCut = false
    @State private var saving = false
    @State private var loaded = false

    private var original: [Segment] { recording.transcript.finalSegments }
    private var hasChanges: Bool { entries.map(\.segment) != original }
    private var keep: [Bool] {
        let kept = Set(entries.map(\.id))
        return original.indices.map { kept.contains($0) }
    }
    private var removedCount: Int { original.count - entries.count }
    private var duration: Double {
        max(recording.item.duration ?? 0, original.map(\.end).max() ?? 0)
    }
    private var removedRanges: [ClosedRange<Double>] {
        guard removedCount > 0 else { return [] }
        return TranscriptEditing.removedRanges(segments: original, keep: keep, duration: duration)
    }
    private var willCutAudio: Bool { cutAudio && recording.canEditAudio && removedCount > 0 }

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .safeAreaInset(edge: .bottom) { footer }
            .background(Theme.night)
            .navigationTitle("Mitschrift")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .environment(\.editMode, $editMode)
            .confirmationDialog("Änderungen an der Mitschrift verwerfen?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Verwerfen", role: .destructive) { dismiss() }
                Button("Weiter bearbeiten", role: .cancel) {}
            }
            .confirmationDialog("Die entfernten Stellen werden auch aus der Audiodatei gelöscht. Das lässt sich nicht rückgängig machen.",
                                isPresented: $confirmCut, titleVisibility: .visible) {
                Button("Kürzen und sichern", role: .destructive) { save() }
                Button("Abbrechen", role: .cancel) {}
            }
            .sheet(item: $correcting) { entry in
                SegmentTextSheet(entry: entry, speaker: entry.segment.speaker.map(recording.transcript.speakerName(for:))) { text in
                    mutate { list in
                        if let index = list.firstIndex(where: { $0.id == entry.id }) { list[index].segment.text = text }
                    }
                }
            }
            .tint(Theme.coral)
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(hasChanges || saving)
        .onAppear(perform: load)
    }

    // MARK: Liste

    private var list: some View {
        List(selection: $selection) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { position, entry in
                row(entry, position: position)
                    .tag(entry.id)
                    .listRowBackground(Theme.night)
                    .listRowSeparatorTint(Theme.ink)
                    .contentShape(Rectangle())
                    .onTapGesture { if !editMode.isEditing { correcting = entry } }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { remove([entry.id]) } label: { Label("Entfernen", systemImage: "trash") }
                    }
                    .swipeActions(edge: .leading) {
                        Button { removeFrom(position) } label: { Label("Ab hier", systemImage: "scissors") }
                            .tint(Theme.amber)
                    }
                    .contextMenu {
                        Button { correcting = entry } label: { Label("Text korrigieren", systemImage: "pencil") }
                        Button(role: .destructive) { remove([entry.id]) } label: { Label("Abschnitt entfernen", systemImage: "trash") }
                        Button(role: .destructive) { removeFrom(position) } label: { Label("Ab hier alles entfernen", systemImage: "arrow.down.to.line") }
                        Button(role: .destructive) { removeBefore(position) } label: { Label("Alles davor entfernen", systemImage: "arrow.up.to.line") }
                    }
            }
            if let last = entries.last, last.id < original.count - 1 {
                removedMarker(original.count - 1 - last.id)
                    .listRowBackground(Theme.night)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func row(_ entry: Entry, position: Int) -> some View {
        let previous = position > 0 ? entries[position - 1] : nil
        let gap = entry.id - (previous?.id ?? -1) - 1
        VStack(alignment: .leading, spacing: 6) {
            if gap > 0 { removedMarker(gap) }
            HStack(spacing: 8) {
                if TranscriptEditing.hasTimings(original) {
                    Text(RecordingNaming.elapsedText(entry.segment.start))
                        .font(Theme.Fonts.footnote.monospacedDigit())
                        .foregroundStyle(Theme.mist)
                }
                if let speaker = entry.segment.speaker, speaker != previous?.segment.speaker || gap > 0 {
                    Text(recording.transcript.speakerName(for: speaker))
                        .font(Theme.Fonts.speaker)
                        .foregroundStyle(Theme.mint)
                }
                if entry.segment.text != original[entry.id].text {
                    Text("korrigiert")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.mist)
                }
            }
            Text(entry.segment.text)
                .font(.system(.body, design: .serif))
                .foregroundStyle(Theme.paper)
                .lineSpacing(2)
        }
        .padding(.vertical, 4)
    }

    private func removedMarker(_ count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "scissors")
            Text(count == 1 ? "1 Abschnitt entfernt" : "\(count) Abschnitte entfernt")
        }
        .font(Theme.Fonts.footnote.weight(.semibold))
        .foregroundStyle(Theme.amber)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            removedMarker(original.count)
            Text("Mindestens ein Abschnitt muss bleiben. Soll die ganze Aufnahme weg, lösche sie in der Aufnahmenliste.")
                .font(Theme.Fonts.status)
                .foregroundStyle(Theme.mist)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Fuß und Leiste

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if removedCount > 0 {
                Text(removedSummary)
                    .font(Theme.Fonts.status)
                    .foregroundStyle(Theme.paper)
                if recording.canEditAudio {
                    Toggle(isOn: $cutAudio) {
                        Text("Auch aus der Audiodatei entfernen")
                            .font(Theme.Fonts.status)
                            .foregroundStyle(Theme.paper)
                    }
                    .tint(Theme.mint)
                    Text(cutAudio
                         ? "Am Anfang und Ende wird die Aufnahme gekürzt, dazwischen werden die Stellen stumm. Nachträgliches Transkribieren bringt sie nicht zurück."
                         : "Die Audiodatei bleibt vollständig. Nachträgliches Transkribieren bringt die entfernten Stellen zurück.")
                        .font(Theme.Fonts.footnote)
                        .foregroundStyle(Theme.mist)
                } else {
                    Text(recording.audioLocked
                         ? "Die Aufnahme wird noch komprimiert. Gekürzt wird nur die Mitschrift, die Audiodatei bleibt vollständig."
                         : "Diese Mitschrift hat keine Zeitangaben. Gekürzt wird nur die Mitschrift, die Audiodatei bleibt vollständig.")
                        .font(Theme.Fonts.footnote)
                        .foregroundStyle(Theme.mist)
                }
            } else {
                Text("Abschnitt antippen zum Korrigieren. Nach links wischen entfernt ihn, nach rechts wischen entfernt alles ab hier. Gedrückt halten zeigt weitere Möglichkeiten.")
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(Theme.mist)
            }
            if let error = recording.error {
                Text(error)
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(Theme.amber)
            }
            if saving {
                HStack(spacing: 8) {
                    ProgressView().tint(Theme.mint)
                    Text(willCutAudio ? "Aufnahme wird gekürzt …" : "Wird gesichert …")
                        .font(Theme.Fonts.footnote)
                        .foregroundStyle(Theme.mist)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 12)
        .background(Theme.ink)
    }

    private var removedSummary: String {
        let count = removedCount == 1 ? "1 Abschnitt" : "\(removedCount) Abschnitte"
        let seconds = removedRanges.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
        guard TranscriptEditing.hasTimings(original), seconds >= 1 else { return "\(count) entfernt" }
        let length = seconds < 60 ? "\(Int(seconds.rounded())) Sekunden" : "\(RecordingNaming.elapsedText(seconds)) Minuten"
        return "\(count) entfernt, zusammen \(length) Aufnahme"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Abbrechen") {
                if hasChanges { confirmDiscard = true } else { dismiss() }
            }
            .disabled(saving)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Sichern") {
                if willCutAudio { confirmCut = true } else { save() }
            }
            .fontWeight(.semibold)
            .disabled(!hasChanges || entries.isEmpty || saving)
        }
        ToolbarItemGroup(placement: .bottomBar) {
            Button {
                if let previous = history.popLast() { entries = previous }
            } label: {
                Label("Rückgängig", systemImage: "arrow.uturn.backward")
            }
            .disabled(history.isEmpty || saving)
            Spacer()
            if editMode.isEditing {
                Button(role: .destructive) {
                    remove(selection)
                    selection = []
                    editMode = .inactive
                } label: {
                    Text(selection.isEmpty ? "Entfernen" : "\(selection.count) entfernen")
                }
                .disabled(selection.isEmpty)
                Button("Fertig") {
                    selection = []
                    editMode = .inactive
                }
            } else {
                Button("Auswählen") { editMode = .active }
                    .disabled(entries.isEmpty || saving)
            }
        }
    }

    // MARK: Aktionen

    private func load() {
        guard !loaded else { return }
        loaded = true
        entries = original.enumerated().map { Entry(id: $0.offset, segment: $0.element) }
        #if DEBUG
        // Für Gestaltungs-Screenshots: `SIMCTL_CHILD_MITSCHRIFT_DEV_SHOW_EDITOR=cut` zeigt einen gekürzten
        // Stand, `cutsave` sichert ihn samt Audioschnitt sofort (Test des ganzen Speicherwegs).
        let flag = ProcessInfo.processInfo.environment["MITSCHRIFT_DEV_SHOW_EDITOR"]
        if flag == "cut" || flag == "cutsave", entries.count > 2 {
            removeFrom(entries.count - 2)
            if flag == "cutsave" {
                // Erst nach der Einblendung sichern, sonst greift das Schließen des Blatts nicht.
                Task { try? await Task.sleep(for: .seconds(1.5)); save() }
            }
        }
        #endif
    }

    private func mutate(_ change: (inout [Entry]) -> Void) {
        var copy = entries
        change(&copy)
        guard copy != entries else { return }
        history.append(entries)
        entries = copy
    }

    private func remove(_ ids: Set<Int>) {
        mutate { $0.removeAll { ids.contains($0.id) } }
    }

    private func removeFrom(_ position: Int) {
        mutate { $0.removeSubrange(position...) }
    }

    private func removeBefore(_ position: Int) {
        mutate { $0.removeSubrange(..<position) }
    }

    private func save() {
        let segments = entries.map(\.segment)
        let ranges = removedRanges
        let cut = willCutAudio
        saving = true
        Task {
            let ok = await recording.applyEdit(segments: segments, removed: ranges, cutAudio: cut)
            saving = false
            if ok { dismiss() }
        }
    }
}

/// Den Text eines Abschnitts korrigieren.
private struct SegmentTextSheet: View {
    let entry: TranscriptEditorView.Entry
    let speaker: String?
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    if entry.segment.end > 0 {
                        Text(RecordingNaming.elapsedText(entry.segment.start))
                            .font(Theme.Fonts.footnote.monospacedDigit())
                            .foregroundStyle(Theme.mist)
                    }
                    if let speaker {
                        Text(speaker)
                            .font(Theme.Fonts.speaker)
                            .foregroundStyle(Theme.mint)
                    }
                }
                TextEditor(text: $text)
                    .font(.system(.body, design: .serif))
                    .foregroundStyle(Theme.paper)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Theme.ink, in: RoundedRectangle(cornerRadius: 10))
                    .focused($focused)
                Text("Korrigiert wird nur der Text. Ein Abschnitt, der ganz weg soll, wird in der Liste entfernt.")
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(Theme.mist)
            }
            .padding(Theme.gutter)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.night)
            .navigationTitle("Abschnitt korrigieren")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Übernehmen") {
                        onSave(trimmed)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(trimmed.isEmpty || trimmed == entry.segment.text)
                }
            }
            .tint(Theme.coral)
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .onAppear {
            text = entry.segment.text
            focused = true
        }
    }
}
