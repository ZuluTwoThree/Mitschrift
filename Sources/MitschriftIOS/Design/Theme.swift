import SwiftUI

/// Visuelle Identität der iOS-App, abgeleitet vom App-Icon: Nacht und Tinte als Flächen, Papier als
/// Text, Koralle ausschließlich für die Aufnahme, Mint für Live-Verbindung und Sprecherspalte.
enum Theme {
    static let night = Color(red: 0.090, green: 0.078, blue: 0.184)   // Hintergrund
    static let ink = Color(red: 0.141, green: 0.122, blue: 0.271)     // Flächen, Transportleiste
    static let inkRaised = Color(red: 0.184, green: 0.161, blue: 0.341)
    static let paper = Color(red: 0.953, green: 0.937, blue: 1.0)     // Text
    static let mist = Color(red: 0.663, green: 0.639, blue: 0.788)    // Nebentext
    static let coral = Color(red: 0.992, green: 0.471, blue: 0.361)   // Aufnahme
    static let coralDeep = Color(red: 0.929, green: 0.329, blue: 0.298)
    static let mint = Color(red: 0.522, green: 0.922, blue: 0.780)    // Live, Sprecher
    static let amber = Color(red: 0.98, green: 0.78, blue: 0.40)      // Warnungen

    enum Fonts {
        /// Mitschrift: Serife, eine Stufe größer als Systemtext, skaliert mit der Dynamischen Schrift.
        static let transcript = Font.system(.title3, design: .serif)
        static let transcriptPartial = Font.system(.title3, design: .serif).italic()
        static let speaker = Font.system(.subheadline, design: .serif).weight(.semibold)
        static let title = Font.system(.title2, design: .serif).weight(.semibold)
        static let timer = Font.system(.title, design: .default).weight(.medium).monospacedDigit()
        static let status = Font.system(.subheadline).weight(.medium)
        static let footnote = Font.system(.footnote)
        static let button = Font.system(.body).weight(.semibold)
    }

    static let gutter: CGFloat = 20
    static let speakerColumn: CGFloat = 30
}

extension View {
    func themedScreen() -> some View {
        self
            .background(Theme.night.ignoresSafeArea())
            .preferredColorScheme(.dark)
            .tint(Theme.coral)
    }
}
