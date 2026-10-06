import Foundation

/// Antwort auf `POST /v1/live-transcriptions/segments` (siehe docs/api/segment-contract.md).
public struct SegmentResponse: Codable, Equatable, Sendable {
    public var sessionId: String
    public var sequence: Int
    public var windowStart: Double?
    public var windowEnd: Double?
    public var finalSegments: [Segment]
    public var partialSegments: [Segment]
    public var diagnostics: Diagnostics?

    enum CodingKeys: String, CodingKey {
        case sessionId, sequence, windowStart, windowEnd, diagnostics
        case finalSegments = "final"
        case partialSegments = "partial"
    }

    public init(
        sessionId: String,
        sequence: Int,
        windowStart: Double? = nil,
        windowEnd: Double? = nil,
        finalSegments: [Segment] = [],
        partialSegments: [Segment] = [],
        diagnostics: Diagnostics? = nil
    ) {
        self.sessionId = sessionId
        self.sequence = sequence
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.finalSegments = finalSegments
        self.partialSegments = partialSegments
        self.diagnostics = diagnostics
    }
}

/// Antwort auf `POST /v1/live-transcriptions/{sessionId}/finish`.
public struct FinishResponse: Codable, Equatable, Sendable {
    public var sessionId: String
    public var lastSequence: Int?
    public var finalSegments: [Segment]
    public var partialSegments: [Segment]

    enum CodingKeys: String, CodingKey {
        case sessionId, lastSequence
        case finalSegments = "final"
        case partialSegments = "partial"
    }

    public init(sessionId: String, lastSequence: Int? = nil, finalSegments: [Segment] = [], partialSegments: [Segment] = []) {
        self.sessionId = sessionId
        self.lastSequence = lastSequence
        self.finalSegments = finalSegments
        self.partialSegments = partialSegments
    }
}

/// Betriebsdaten aus einer Segmentantwort. Enthält nie Inhalte.
public struct Diagnostics: Codable, Equatable, Sendable {
    public var serverLatencyMs: Int?
    public var realtimeFactor: Double?
    public var queuedSegments: Int?

    public init(serverLatencyMs: Int? = nil, realtimeFactor: Double? = nil, queuedSegments: Int? = nil) {
        self.serverLatencyMs = serverLatencyMs
        self.realtimeFactor = realtimeFactor
        self.queuedSegments = queuedSegments
    }
}

/// Antwort auf `GET /v1/health`.
public struct HealthResponse: Codable, Equatable, Sendable {
    public var status: String
    public var version: String?
    public var model: String?
    public var modelLoaded: Bool?
    public var activeSessions: Int?
    public var maxSessions: Int?
    public var language: String?
    public var backend: String?
    /// Sprechertrennung auf dem Server aktiv (Segmente tragen dann `speaker`).
    public var diarization: Bool?
    /// Der Protokoll-Assistent (`POST /v1/notes`) ist auf dem Server eingerichtet.
    public var notes: Bool?

    public var isHealthy: Bool { status == "ok" }
}

/// Fehlerkörper des Servers: `{ "error": "...", "message": "..." }`.
public struct APIErrorBody: Codable, Equatable, Sendable {
    public var error: String
    public var message: String?
}

/// Anfrage an `POST /v1/notes`: die Mitschrift als Text, aus der der Assistent ein Protokoll erstellt.
public struct NotesRequest: Codable, Equatable, Sendable {
    public var transcript: String
    public var language: String
    public var title: String?
    public var recordedAt: String?
    /// `minutes` oder `summary`; ältere Server ignorieren das Feld und liefern ein Protokoll.
    public var kind: NotesKind

    public init(transcript: String, language: String, title: String? = nil, recordedAt: Date? = nil,
                timeZone: TimeZone = .current, kind: NotesKind = .minutes) {
        self.transcript = transcript
        self.language = language
        self.title = title
        self.kind = kind
        // Mit Zeitzonenversatz, damit der Server die Ortszeit des Geräts ins Protokoll schreibt.
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        self.recordedAt = recordedAt.map { formatter.string(from: $0) }
    }
}

/// Antwort auf `POST /v1/notes`: das Protokoll als Markdown.
public struct NotesResponse: Codable, Equatable, Sendable {
    public var notes: String
    /// Die erzeugte Textart als Rohwert; fehlt bei älteren Servern (dann war es ein Protokoll).
    public var kind: String?
    public var model: String?
    public var diagnostics: NotesDiagnostics?

    public init(notes: String, kind: String? = nil, model: String? = nil, diagnostics: NotesDiagnostics? = nil) {
        self.notes = notes
        self.kind = kind
        self.model = model
        self.diagnostics = diagnostics
    }

    /// Die erzeugte Textart; `nil`, wenn der Server einen unbekannten Wert meldet.
    public var resolvedKind: NotesKind? {
        guard let kind else { return .minutes }
        return NotesKind(rawValue: kind)
    }
}

public struct NotesDiagnostics: Codable, Equatable, Sendable {
    public var latencyMs: Int?
    public var promptTokens: Int?
    public var completionTokens: Int?
    /// Zahl der vorverdichteten Teile einer langen Mitschrift (1 = ein Durchgang).
    public var chunks: Int?

    public init(latencyMs: Int? = nil, promptTokens: Int? = nil, completionTokens: Int? = nil, chunks: Int? = nil) {
        self.latencyMs = latencyMs
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.chunks = chunks
    }
}
