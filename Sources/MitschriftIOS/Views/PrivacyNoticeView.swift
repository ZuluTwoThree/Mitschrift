import SwiftUI

/// Wird vor der ersten Aufnahme gezeigt und erklärt, wohin das Audio geht.
struct PrivacyNoticeView: View {
    var onAccept: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Label("Wohin geht das Audio?", systemImage: "lock.shield")
                    .font(.title2.bold())
                Text("Mitschrift nimmt über das Mikrofon auf und speichert die Aufnahme auf diesem iPhone.")
                Text("Für die Live-Transkription werden kurze Audioabschnitte verschlüsselt über dein privates Tailnet an deinen eigenen Server geschickt. Es gibt keinen Upload an einen externen Transkriptionsdienst.")
                Text("Ohne eingerichteten Server bleibt die Aufnahme nur lokal.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    onAccept()
                } label: {
                    Text("Verstanden, Aufnahme starten")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
        }
    }
}
