import SwiftUI
import MitschriftCore

/// Das Protokoll des Assistenten: Markdown mit Überschriften, Aufzählungen und Aufgaben-Kästchen.
struct NotesView: View {
    @ObservedObject var recording: OpenRecording
    var onRecreate: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let notes = recording.notes {
                    ScrollView {
                        MarkdownNotes(markdown: notes)
                            .padding(.horizontal, Theme.gutter)
                            .padding(.vertical, 12)
                            .textSelection(.enabled)
                    }
                } else {
                    Text("Noch kein Protokoll.")
                        .font(Theme.Fonts.transcript)
                        .foregroundStyle(Theme.mist)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.night)
            .navigationTitle("Protokoll")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Menu {
                        Button {
                            dismiss()
                            onRecreate()
                        } label: {
                            Label("Neu erstellen", systemImage: "arrow.clockwise")
                        }
                        if let model = recording.notesModel {
                            Text("Modell: \(model)")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if let url = recording.item.notesURL {
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .tint(Theme.coral)
        }
        .preferredColorScheme(.dark)
    }
}

/// Einfache Darstellung der festen Protokollstruktur: `#`, `##`, `- [ ]`, `-`, Absätze.
struct MarkdownNotes: View {
    var markdown: String

    private enum Block {
        case title(String)
        case heading(String)
        case task(String, done: Bool)
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
        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("## ") { flush(); result.append(.heading(String(line.dropFirst(3)))) }
            else if line.hasPrefix("# ") { flush(); result.append(.title(String(line.dropFirst(2)))) }
            else if line.hasPrefix("- [ ] ") { flush(); result.append(.task(String(line.dropFirst(6)), done: false)) }
            else if line.lowercased().hasPrefix("- [x] ") { flush(); result.append(.task(String(line.dropFirst(6)), done: true)) }
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
                case .task(let text, let done):
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: done ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(done ? Theme.mint : Theme.coral)
                        Text(inline(text))
                            .font(Theme.Fonts.status)
                            .foregroundStyle(Theme.paper)
                    }
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
