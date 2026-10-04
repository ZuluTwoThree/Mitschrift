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

    public var isHealthy: Bool { status == "ok" }
}

/// Fehlerkörper des Servers: `{ "error": "...", "message": "..." }`.
public struct APIErrorBody: Codable, Equatable, Sendable {
    public var error: String
    public var message: String?
}
