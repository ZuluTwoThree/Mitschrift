import SwiftUI

/// Wird vor der ersten Aufnahme gezeigt und erklärt, wohin das Audio geht.
struct PrivacyNoticeView: View {
    var onAccept: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text("Wohin geht das Audio?")
                    .font(Theme.Fonts.title)
                    .foregroundStyle(Theme.paper)
                Text("Mitschrift nimmt über das Mikrofon auf und speichert die Aufnahme auf diesem iPhone.")
                Text("Für die Live-Mitschrift gehen kurze Audioabschnitte verschlüsselt über dein privates Tailnet an deinen eigenen Server. Es gibt keinen Upload an einen fremden Dienst.")
                Text("Ohne eingerichteten Server bleibt die Aufnahme nur auf dem iPhone.")
                    .foregroundStyle(Theme.mist)
                Spacer()
                Button {
                    onAccept()
                } label: {
                    Text("Verstanden, Aufnahme starten")
                        .font(Theme.Fonts.button)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.coral)
            }
            .font(Theme.Fonts.transcript)
            .foregroundStyle(Theme.paper)
            .padding(Theme.gutter)
            .themedScreen()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
        }
    }
}
