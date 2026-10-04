import SwiftUI
import MitschriftCore

/// Das Protokollblatt: Sprecherspalte links, Text rechts, vorläufiger Text heller und kursiv.
/// Wird für die Live-Ansicht und das Ergebnis gleichermaßen benutzt.
///
/// Mit `autoscroll` folgt das Blatt neuem Text nur, solange das Ende sichtbar ist. Wer nach oben
/// scrollt, um mitzulesen, bleibt dort und bekommt einen Knopf „Zum Ende“.
struct TranscriptPaper: View {
    var transcript: Transcript
    var emptyText: String
    var autoscroll = false

    @State private var endVisible = true
    @State private var pendingScroll = false

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
                    ForEach(Array(transcript.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        row(speaker: paragraph.name) {
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
                    Color.clear
                        .frame(height: 1)
                        .id("end")
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: EndOffsetKey.self, value: geometry.frame(in: .named("paper")).maxY)
                        })
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
                .textSelection(.enabled)
            }
            .coordinateSpace(name: "paper")
            .background(GeometryReader { geometry in
                Color.clear.preference(key: PaperHeightKey.self, value: geometry.size.height)
            })
            .onPreferenceChange(EndOffsetKey.self) { endOffset in
                endMaxY = endOffset
                updateEndVisible()
            }
            .onPreferenceChange(PaperHeightKey.self) { height in
                paperHeight = height
                updateEndVisible()
            }
            .onChange(of: transcript) { _, _ in
                guard autoscroll else { return }
                if endVisible {
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("end", anchor: .bottom) }
                } else {
                    pendingScroll = true
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if autoscroll, pendingScroll, !endVisible {
                    Button {
                        withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo("end", anchor: .bottom) }
                        pendingScroll = false
                    } label: {
                        Label("Zum Ende", systemImage: "arrow.down")
                            .font(Theme.Fonts.footnote.weight(.semibold))
                            .foregroundStyle(Theme.night)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Theme.mint, in: Capsule())
                    }
                    .padding(.bottom, 8)
                    .transition(.opacity)
                }
            }
        }
    }

    @State private var endMaxY: CGFloat = 0
    @State private var paperHeight: CGFloat = 0

    private func updateEndVisible() {
        guard paperHeight > 0 else { return }
        let visible = endMaxY <= paperHeight + 24
        if visible != endVisible {
            endVisible = visible
            if visible { pendingScroll = false }
        }
    }

    /// Die Sprecherspalte gibt es nur, wenn die Mitschrift Sprecher kennt; sonst steht der Text am Rand.
    private func row<Content: View>(speaker: String?, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if transcript.hasSpeakers {
                Text(speaker.map(Self.columnLabel) ?? "")
                    .font(Theme.Fonts.speaker)
                    .foregroundStyle(Theme.mint)
                    .frame(width: Theme.speakerColumn, alignment: .trailing)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .accessibilityLabel(speaker ?? "")
            }
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineSpacing(5)
        }
    }

    /// In der schmalen Spalte steht die Nummer („2“) oder die Initialen eines vergebenen Namens („AM“).
    static func columnLabel(_ name: String) -> String {
        if name.hasPrefix("Sprecher ") { return String(name.dropFirst(9)) }
        let parts = name.split(separator: " ").prefix(2)
        return parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }
}

private struct EndOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct PaperHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
