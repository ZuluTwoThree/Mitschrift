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
        let finalText = session.transcript.finalText
        let partialText = session.transcript.partialText
        let finals = Text(finalText).foregroundColor(.primary)
        guard !partialText.isEmpty else { return finals }
        let partial = Text((finalText.isEmpty ? "" : " ") + partialText)
            .italic()
            .foregroundColor(.secondary)
        return finals + partial
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
