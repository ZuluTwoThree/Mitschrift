import SwiftUI
import MitschriftCore

/// Zeigt eine laufende Session: Serverstatus, Warteschlange, finaler und vorläufiger Text.
struct LiveTranscriptView: View {
    @ObservedObject var session: LiveTranscriptionSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusLine
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if session.transcript.isEmpty {
                            Text("Der Text erscheint hier, sobald der Server antwortet.")
                                .foregroundStyle(.tertiary)
                        }
                        transcriptText
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(12)
                }
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                .onChange(of: session.transcript) { _, _ in
                    withAnimation { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
        }
    }

    private var transcriptText: Text {
        let transcript = session.transcript
        let partialText = transcript.partialText
        let finals = Self.finalText(for: transcript)
        guard !partialText.isEmpty else { return finals }
        let separator = transcript.finalSegments.isEmpty ? "" : (transcript.hasSpeakers ? "\n" : " ")
        let partial = Text(separator + partialText)
            .italic()
            .foregroundColor(.secondary)
        return finals + partial
    }

    /// Finale Abschnitte; mit Sprecherlabels als Absätze mit fettem „Sprecher N:“-Präfix.
    static func finalText(for transcript: Transcript) -> Text {
        guard transcript.hasSpeakers else {
            return Text(transcript.finalText).foregroundColor(.primary)
        }
        var result = Text("")
        for (index, paragraph) in Transcript.speakerParagraphs(transcript.finalSegments).enumerated() {
            if index > 0 { result = result + Text("\n") }
            if let range = paragraph.range(of: "Sprecher "), range.lowerBound == paragraph.startIndex,
               let colon = paragraph.range(of: ": ") {
                let prefix = String(paragraph[paragraph.startIndex..<colon.lowerBound])
                let body = String(paragraph[colon.upperBound...])
                result = result + Text(prefix + ":").bold() + Text(" " + body)
            } else {
                result = result + Text(paragraph)
            }
        }
        return result.foregroundColor(.primary)
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusColor)
            Text(statusText)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            if session.queuedCount > 0 {
                Text("\(session.queuedCount) wartend")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color(.tertiarySystemFill)))
            }
        }
        .font(.callout)
    }

    private var statusText: String {
        switch session.status {
        case .idle: return "Verbindung wird aufgebaut"
        case .connected:
            if let ms = session.lastDiagnostics?.serverLatencyMs { return "Live · Server \(ms) ms" }
            return "Live verbunden"
        case .waiting(let message): return message
        case .paused: return "Live-Übertragung pausiert: Warteschlange voll. Audio wird lokal gespeichert."
        case .finishing: return "Letzte Abschnitte werden übertragen …"
        case .finished: return "Übertragung abgeschlossen"
        case .failed(let message): return message
        }
    }

    private var statusSymbol: String {
        switch session.status {
        case .connected, .finished: return "checkmark.circle.fill"
        case .waiting, .paused: return "arrow.triangle.2.circlepath"
        case .failed: return "exclamationmark.triangle.fill"
        default: return "ellipsis.circle"
        }
    }

    private var statusColor: Color {
        switch session.status {
        case .connected, .finished: return .green
        case .waiting, .paused: return .orange
        case .failed: return .red
        default: return .secondary
        }
    }
}
