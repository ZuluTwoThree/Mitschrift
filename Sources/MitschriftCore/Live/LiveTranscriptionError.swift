import Foundation

/// Fehler der Live-Übertragung, abgeleitet aus den HTTP-Codes im Vertrag.
public enum LiveTranscriptionError: Error, Equatable, Sendable {
    case invalidRequest(String?)      // 400
    case unauthorized                 // 401
    case sessionNotFound              // 404
    case sessionConflict(String?)     // 409
    case payloadTooLarge              // 413
    case overloaded                   // 429
    case unavailable                  // 503
    case server(status: Int)          // sonstige 5xx
    case transport(String)            // URLSession-Fehler, Timeout, kein Netz
    case invalidResponse              // JSON nicht lesbar
    case notConfigured                // kein Endpunkt hinterlegt

    public init(status: Int, body: APIErrorBody?) {
        switch status {
        case 400: self = .invalidRequest(body?.message)
        case 401: self = .unauthorized
        case 404: self = .sessionNotFound
        case 409: self = .sessionConflict(body?.message)
        case 413: self = .payloadTooLarge
        case 429: self = .overloaded
        case 503: self = .unavailable
        default: self = .server(status: status)
        }
    }

    /// Soll das Segment später erneut gesendet werden?
    public var isRetryable: Bool {
        switch self {
        case .overloaded, .unavailable, .server, .transport: return true
        default: return false
        }
    }

    /// Verwirft das Segment, die Aufnahme läuft aber weiter.
    public var dropsSegment: Bool {
        switch self {
        case .invalidRequest, .payloadTooLarge: return true
        default: return false
        }
    }

    /// Beendet die Live-Session; weitere Segmente brauchen eine neue Session.
    public var endsSession: Bool {
        switch self {
        case .unauthorized, .sessionNotFound, .sessionConflict, .notConfigured, .invalidResponse: return true
        default: return false
        }
    }

    /// Verständliche Meldung für die Oberfläche. Enthält keine Inhalte.
    public var userMessage: String {
        switch self {
        case .invalidRequest: return "Der Server hat ein Audiosegment abgelehnt."
        case .unauthorized: return "Der Server hat den Zugangscode nicht akzeptiert. Bitte Einstellungen prüfen."
        case .sessionNotFound: return "Die Sitzung ist auf dem Server nicht mehr bekannt."
        case .sessionConflict: return "Die Sitzung wurde auf dem Server beendet."
        case .payloadTooLarge: return "Ein Audiosegment war zu groß."
        case .overloaded: return "Der Server ist ausgelastet. Es wird später erneut versucht."
        case .unavailable: return "Der Server startet noch oder ist vorübergehend nicht erreichbar."
        case .server(let status): return "Serverfehler (\(status)). Es wird erneut versucht."
        case .transport: return "Keine Verbindung zum Server. Ist Tailscale verbunden?"
        case .invalidResponse: return "Die Antwort des Servers war nicht lesbar."
        case .notConfigured: return "Es ist kein Server eingerichtet."
        }
    }
}
