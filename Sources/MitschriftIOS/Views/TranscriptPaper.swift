import SwiftUI
import MitschriftCore

/// Das Protokollblatt: Sprecherspalte links, Text rechts, vorläufiger Text heller und kursiv.
/// Wird für die Live-Ansicht und das Ergebnis gleichermaßen benutzt.
struct TranscriptPaper: View {
    var transcript: Transcript
    var emptyText: String
    var autoscroll = false

    private struct Paragraph: Identifiable {
        let id: Int
        let speaker: String?
        let text: String
    }

    private var paragraphs: [Paragraph] {
        guard transcript.hasSpeakers else {
            let text = transcript.finalText
            return text.isEmpty ? [] : [Paragraph(id: 0, speaker: nil, text: text)]
        }
        return Transcript.speakerParagraphs(transcript.finalSegments).enumerated().map { index, paragraph in
            if let colon = paragraph.range(of: ": "), paragraph.hasPrefix("Sprecher ") {
                let label = String(paragraph[paragraph.index(paragraph.startIndex, offsetBy: 9)..<colon.lowerBound])
                return Paragraph(id: index, speaker: label, text: String(paragraph[colon.upperBound...]))
            }
            return Paragraph(id: index, speaker: nil, text: paragraph)
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if transcript.isEmpty {
                        Text(emptyText)
                            .font(Theme.Fonts.transcript)
                            .foregroundStyle(Theme.mist)
                            .padding(.top, 8)
                    }
                    ForEach(paragraphs) { paragraph in
                        row(speaker: paragraph.speaker) {
                            Text(paragraph.text)
                                .font(Theme.Fonts.transcript)
                                .foregroundStyle(Theme.paper)
                        }
                    }
                    if !transcript.partialText.isEmpty {
                        row(speaker: nil) {
                            Text(transcript.partialText)
                                .font(Theme.Fonts.transcriptPartial)
                                .foregroundStyle(Theme.mist)
                        }
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
                .textSelection(.enabled)
            }
            .onChange(of: transcript) { _, _ in
                guard autoscroll else { return }
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    /// Die Sprecherspalte gibt es nur, wenn die Mitschrift Sprecher kennt; sonst steht der Text am Rand.
    private func row<Content: View>(speaker: String?, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if transcript.hasSpeakers {
                Text(speaker ?? "")
                    .font(Theme.Fonts.speaker)
                    .foregroundStyle(Theme.mint)
                    .frame(width: Theme.speakerColumn, alignment: .trailing)
                    .accessibilityLabel(speaker.map { "Sprecher \($0)" } ?? "")
            }
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineSpacing(5)
        }
    }
}
