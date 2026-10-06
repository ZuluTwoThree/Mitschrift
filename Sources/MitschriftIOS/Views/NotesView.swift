import SwiftUI
import MitschriftCore

/// Protokoll oder Zusammenfassung des Assistenten als Blatt über der Aufnahme.
struct NotesView: View {
    @ObservedObject var recording: OpenRecording
    var kind: NotesKind
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            NotesScreen(recording: recording, kind: kind)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Fertig") { dismiss() }
                    }
                }
        }
        .preferredColorScheme(.dark)
    }
}

/// Die Seite für Protokoll oder Zusammenfassung: Markdown mit Überschriften, Aufzählungen und
/// Aufgaben-Kästchen, dazu Bearbeiten, Teilen und Neu erstellen. Steht im Blatt nach dem Stoppen und
/// direkt aus der Aufnahmenliste.
struct NotesScreen: View {
    @ObservedObject var recording: OpenRecording
    var kind: NotesKind
    @EnvironmentObject private var settings: SettingsStore
    @State private var editing = false
    @State private var draft = ""
    @State private var confirmDiscard = false
    @State private var confirmRecreate = false

    private var text: String? { recording.text(kind) }
    private var hasChanges: Bool { editing && draft != (text ?? "") }

    var body: some View {
        Group {
            if editing {
                MarkdownEditor(text: $draft)
            } else if recording.activity == .writing(kind) {
                VStack(spacing: 12) {
                    ProgressView().tint(Theme.mint)
                    Text(kind == .summary ? "Der Assistent liest die Mitschrift und schreibt die Zusammenfassung."
                                          : "Der Assistent liest die Mitschrift und schreibt das Protokoll.")
                        .font(Theme.Fonts.status)
                        .foregroundStyle(Theme.mist)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
            } else if let text {
                ScrollView {
                    if recording.outdated.contains(kind) {
                        Text("Die Mitschrift wurde nach dem Erstellen bearbeitet. Über „Neu erstellen“ entsteht der Text aus der aktuellen Fassung.")
                            .font(Theme.Fonts.footnote)
                            .foregroundStyle(Theme.amber)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Theme.gutter)
                            .padding(.top, 12)
                    }
                    MarkdownNotes(markdown: text) { line in recording.toggleTask(atLine: line, kind: kind) }
                        .padding(.horizontal, Theme.gutter)
                        .padding(.vertical, 12)
                        .textSelection(.enabled)
                }
            } else {
                VStack(spacing: 12) {
                    Text(recording.error ?? (kind == .summary ? "Noch keine Zusammenfassung." : "Noch kein Protokoll."))
                        .font(Theme.Fonts.status)
                        .foregroundStyle(recording.error == nil ? Theme.mist : Theme.amber)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    if settings.isConfigured, !recording.transcript.isEmpty {
                        Button("\(kind.title) erstellen", action: recreate)
                            .buttonStyle(PaperButtonStyle(prominent: true))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.night)
        .navigationTitle(editing ? "Bearbeiten" : kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(editing)
        .toolbar {
            if editing {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") {
                        if hasChanges { confirmDiscard = true } else { editing = false }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        recording.saveNotes(draft, kind: kind)
                        editing = false
                    }
                    .fontWeight(.semibold)
                }
            } else {
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 14) {
                        if text != nil {
                            Button {
                                draft = text ?? ""
                                editing = true
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .accessibilityLabel("\(kind.title) bearbeiten")
                            .disabled(recording.isBusy)
                        }
                        if let url = recording.item.url(for: kind), text != nil {
                            ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                        }
                        Menu {
                            if settings.isConfigured, !recording.transcript.isEmpty {
                                Button {
                                    if text != nil { confirmRecreate = true } else { recreate() }
                                } label: {
                                    Label("Neu erstellen", systemImage: "arrow.clockwise")
                                }
                                .disabled(recording.isBusy)
                            }
                            if let model = recording.models[kind] {
                                Text("Modell: \(model)")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
        }
        .confirmationDialog("\(kind == .summary ? "Die vorhandene Zusammenfassung" : "Das vorhandene Protokoll") wird durch \(kind == .summary ? "eine neu erstellte" : "ein neu erstelltes") ersetzt. Eigene Änderungen gehen dabei verloren.", isPresented: $confirmRecreate, titleVisibility: .visible) {
            Button("Neu erstellen", role: .destructive, action: recreate)
            Button("Abbrechen", role: .cancel) {}
        }
        .confirmationDialog("Änderungen \(kind == .summary ? "an der Zusammenfassung" : "am Protokoll") verwerfen?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Verwerfen", role: .destructive) { editing = false }
            Button("Weiter bearbeiten", role: .cancel) {}
        }
        .interactiveDismissDisabled(hasChanges)
        .tint(Theme.coral)
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.environment["MITSCHRIFT_DEV_SHOW_NOTES"] == "edit", let text {
                draft = text
                editing = true
            }
            #endif
        }
    }

    private func recreate() {
        guard let endpoint = settings.endpoint else { return }
        Task { await recording.createNotes(kind: kind, endpoint: endpoint) }
    }
}

/// Einfache Darstellung der festen Protokollstruktur: `#`, `##`, `- [ ]`, `-`, Absätze.
/// Aufgaben lassen sich antippen; `onToggleTask` bekommt die Zeilennummer im Markdown.
struct MarkdownNotes: View {
    var markdown: String
    var onToggleTask: ((Int) -> Void)? = nil

    private enum Block {
        case title(String)
        case heading(String)
        case subheading(String)
        case task(String, done: Bool, line: Int)
        case bullet(String)
        case paragraph(String)
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty {
                result.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }
        for (index, rawLine) in markdown.components(separatedBy: "\n").enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("### ") { flush(); result.append(.subheading(String(line.dropFirst(4)))) }
            else if line.hasPrefix("## ") { flush(); result.append(.heading(String(line.dropFirst(3)))) }
            else if line.hasPrefix("# ") { flush(); result.append(.title(String(line.dropFirst(2)))) }
            else if line.hasPrefix("- [ ] ") { flush(); result.append(.task(String(line.dropFirst(6)), done: false, line: index)) }
            else if line.lowercased().hasPrefix("- [x] ") { flush(); result.append(.task(String(line.dropFirst(6)), done: true, line: index)) }
            else if line.hasPrefix("- ") || line.hasPrefix("* ") { flush(); result.append(.bullet(String(line.dropFirst(2)))) }
            else { paragraph.append(line) }
        }
        flush()
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .title(let text):
                    Text(inline(text))
                        .font(Theme.Fonts.title)
                        .foregroundStyle(Theme.paper)
                        .padding(.bottom, 4)
                case .heading(let text):
                    Text(inline(text))
                        .font(Theme.Fonts.speaker)
                        .foregroundStyle(Theme.mint)
                        .padding(.top, 10)
                case .subheading(let text):
                    Text(inline(text))
                        .font(Theme.Fonts.status.weight(.semibold))
                        .foregroundStyle(Theme.paper)
                        .padding(.top, 6)
                case .task(let text, let done, let line):
                    Button {
                        onToggleTask?(line)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(done ? Theme.mint : Theme.coral)
                            Text(inline(text))
                                .font(Theme.Fonts.status)
                                .foregroundStyle(done ? Theme.mist : Theme.paper)
                                .strikethrough(done, color: Theme.mist)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(onToggleTask == nil)
                    .accessibilityHint(done ? "Als offen markieren" : "Als erledigt markieren")
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("•").foregroundStyle(Theme.mist)
                        Text(inline(text))
                            .font(Theme.Fonts.status)
                            .foregroundStyle(Theme.paper)
                    }
                case .paragraph(let text):
                    Text(inline(text))
                        .font(Theme.Fonts.status)
                        .foregroundStyle(Theme.paper)
                        .lineSpacing(3)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Fett und kursiv innerhalb einer Zeile über die Markdown-Unterstützung von `Text`.
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
