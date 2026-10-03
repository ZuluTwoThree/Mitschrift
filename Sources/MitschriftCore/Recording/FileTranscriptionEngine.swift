import Foundation

/// Transkribiert eine fertige Audiodatei. macOS setzt das mit `whisper-cli` um; iOS nutzt den Server.
public protocol FileTranscriptionEngine: Sendable {
    /// Liefert den Text der Datei. `language` ist `de`, `en` oder `auto`.
    func transcribe(fileURL: URL, language: String) async throws -> String
}
