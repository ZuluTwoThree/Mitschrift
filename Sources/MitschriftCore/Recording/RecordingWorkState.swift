import Foundation

/// Zustand einer Aufnahme mit anschließender Datei-Transkription (macOS-Pfad).
public enum RecordingWorkState: Equatable, Sendable {
    case idle
    case recording
    case transcribing
    case done
    case failed(String)

    public var statusText: String {
        switch self {
        case .idle: return "Bereit für eine neue Aufnahme"
        case .recording: return "Aufnahme läuft"
        case .transcribing: return "Whisper erstellt die Mitschrift …"
        case .done: return "Mitschrift fertig und automatisch gespeichert"
        case .failed(let message): return message
        }
    }

    public var isRecording: Bool { self == .recording }
    public var isBusy: Bool { self == .transcribing }
    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}
