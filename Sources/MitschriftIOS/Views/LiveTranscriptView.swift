import SwiftUI
import MitschriftCore

/// Live-Ansicht einer laufenden Session: Verbindungszeile und Protokollblatt mit Autoscroll.
struct LiveTranscriptView: View {
    @ObservedObject var session: LiveTranscriptionSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            connectionLine
            TranscriptPaper(
                transcript: session.transcript,
                emptyText: "Der Text erscheint hier, sobald der Server antwortet.",
                autoscroll: true
            )
        }
    }

    /// Finale Abschnitte als Text, mit Sprecherabsätzen; für Export und Vorschauen.
    static func finalText(for transcript: Transcript) -> Text {
        Text(transcript.finalTextWithSpeakers)
    }

    private var connectionLine: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(Theme.Fonts.footnote)
                .foregroundStyle(Theme.mist)
                .lineLimit(2)
            Spacer()
            if session.queuedCount > 0 {
                Text("\(session.queuedCount) wartend")
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(Theme.amber)
            }
        }
    }

    private var statusText: String {
        switch session.status {
        case .idle: return "Verbindung wird aufgebaut"
        case .connected:
            if let ms = session.lastDiagnostics?.serverLatencyMs { return "Live, Server antwortet in \(ms) ms" }
            return "Live verbunden"
        case .waiting(let message): return message
        case .paused: return "Live-Übertragung pausiert, Warteschlange voll. Audio wird lokal gespeichert."
        case .finishing: return "Letzte Abschnitte werden übertragen"
        case .finished: return "Übertragung abgeschlossen"
        case .failed(let message): return message
        }
    }

    private var statusColor: Color {
        switch session.status {
        case .connected, .finished: return Theme.mint
        case .waiting, .paused: return Theme.amber
        case .failed: return Theme.coral
        default: return Theme.mist
        }
    }
}
