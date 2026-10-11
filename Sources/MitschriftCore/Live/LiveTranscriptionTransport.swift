import Foundation

/// Netzwerkseite des Vertrags. Austauschbar für Tests.
public protocol LiveTranscriptionTransport: Sendable {
    func sendSegment(_ segment: AudioSegment, sessionId: String, language: String) async throws -> SegmentResponse
    func finish(sessionId: String) async throws -> FinishResponse
    func health() async throws -> HealthResponse
}

/// Der Protokoll-Assistent des Servers (`POST /v1/notes`).
public protocol NotesTransport: Sendable {
    func notes(_ request: NotesRequest) async throws -> NotesResponse
}

/// Genaue Nach-Transkription einer ganzen Aufnahme (`/v1/transcriptions`).
public protocol RefineTransport: Sendable {
    /// Lädt die Audiodatei hoch und legt einen Auftrag an; `progress` meldet den Upload (0…1).
    func startRefine(audioFile: URL, language: String, progress: (@Sendable (Double) -> Void)?) async throws -> RefineJob
    func refineStatus(id: String) async throws -> RefineJob
}

/// Umsetzung des Vertrags mit `URLSession`.
public final class URLSessionLiveTransport: LiveTranscriptionTransport, NotesTransport, RefineTransport, @unchecked Sendable {
    public static let clientHeaderValue = "mitschrift/\(coreVersion)"
    public static let coreVersion = "0.1.0"

    private let endpoint: ServerEndpoint
    private let session: URLSession
    private let decoder = JSONDecoder()

    public init(endpoint: ServerEndpoint, session: URLSession? = nil) {
        self.endpoint = endpoint
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 15
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    public func sendSegment(_ segment: AudioSegment, sessionId: String, language: String) async throws -> SegmentResponse {
        var request = URLRequest(url: endpoint.baseURL.appendingPathComponent("v1/live-transcriptions/segments"))
        request.httpMethod = "POST"
        request.httpBody = segment.data
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.setValue(sessionId, forHTTPHeaderField: "X-Mitschrift-Session")
        request.setValue(String(segment.sequence), forHTTPHeaderField: "X-Mitschrift-Sequence")
        request.setValue(language, forHTTPHeaderField: "X-Mitschrift-Language")
        request.setValue(ISO8601DateFormatter().string(from: segment.capturedAt), forHTTPHeaderField: "X-Mitschrift-Captured-At")
        applyCommonHeaders(&request)
        return try await perform(request)
    }

    public func finish(sessionId: String) async throws -> FinishResponse {
        var request = URLRequest(url: endpoint.baseURL.appendingPathComponent("v1/live-transcriptions/\(sessionId)/finish"))
        request.httpMethod = "POST"
        applyCommonHeaders(&request)
        return try await perform(request)
    }

    /// Erstellt ein Protokoll. Das LLM braucht je nach Länge bis zu einigen Minuten, deshalb ein eigenes Timeout.
    public func notes(_ body: NotesRequest) async throws -> NotesResponse {
        var request = URLRequest(url: endpoint.baseURL.appendingPathComponent("v1/notes"))
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyCommonHeaders(&request)
        return try await perform(request, session: longSession)
    }

    public func startRefine(audioFile: URL, language: String, progress: (@Sendable (Double) -> Void)?) async throws -> RefineJob {
        var request = URLRequest(url: endpoint.baseURL.appendingPathComponent("v1/transcriptions"))
        request.httpMethod = "POST"
        request.setValue(Self.contentType(for: audioFile), forHTTPHeaderField: "Content-Type")
        request.setValue(language, forHTTPHeaderField: "X-Mitschrift-Language")
        applyCommonHeaders(&request)
        let delegate = UploadProgressDelegate(progress: progress)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await longSession.upload(for: request, fromFile: audioFile, delegate: delegate)
        } catch {
            throw LiveTranscriptionError.transport(error.localizedDescription)
        }
        return try decode(data, response)
    }

    public func refineStatus(id: String) async throws -> RefineJob {
        var request = URLRequest(url: endpoint.baseURL.appendingPathComponent("v1/transcriptions/\(id)"))
        request.httpMethod = "GET"
        applyCommonHeaders(&request)
        return try await perform(request)
    }

    static func contentType(for file: URL) -> String {
        switch file.pathExtension.lowercased() {
        case "m4a", "mp4": return "audio/mp4"
        case "wav": return "audio/wav"
        case "caf": return "audio/x-caf"
        case "flac": return "audio/flac"
        default: return "application/octet-stream"
        }
    }

    /// Eigene Session für langlaufende Anfragen: Der Leerlauf-Timeout der Standard-Session (15 s) gilt
    /// hier nicht, weil das LLM ohne Streaming erst am Ende antwortet.
    private lazy var longSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 600
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    public func health() async throws -> HealthResponse {
        var request = URLRequest(url: endpoint.baseURL.appendingPathComponent("v1/health"))
        request.httpMethod = "GET"
        request.setValue(Self.clientHeaderValue, forHTTPHeaderField: "X-Mitschrift-Client")
        request.timeoutInterval = 8
        // 503 trägt bei /health einen gültigen Body; deshalb hier nicht über perform().
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LiveTranscriptionError.invalidResponse }
        guard http.statusCode == 200 || http.statusCode == 503 else {
            throw LiveTranscriptionError(status: http.statusCode, body: try? decoder.decode(APIErrorBody.self, from: data))
        }
        do {
            return try decoder.decode(HealthResponse.self, from: data)
        } catch {
            throw LiveTranscriptionError.invalidResponse
        }
    }

    private func applyCommonHeaders(_ request: inout URLRequest) {
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.clientHeaderValue, forHTTPHeaderField: "X-Mitschrift-Client")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
    }

    private func perform<T: Decodable>(_ request: URLRequest, session: URLSession? = nil) async throws -> T {
        let (data, response) = try await data(for: request, session: session ?? self.session)
        return try decode(data, response)
    }

    private func decode<T: Decodable>(_ data: Data, _ response: URLResponse) throws -> T {
        guard let http = response as? HTTPURLResponse else { throw LiveTranscriptionError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw LiveTranscriptionError(status: http.statusCode, body: try? decoder.decode(APIErrorBody.self, from: data))
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw LiveTranscriptionError.invalidResponse
        }
    }

    private func data(for request: URLRequest, session: URLSession? = nil) async throws -> (Data, URLResponse) {
        do {
            return try await (session ?? self.session).data(for: request)
        } catch {
            throw LiveTranscriptionError.transport(error.localizedDescription)
        }
    }
}


/// Meldet den Fortschritt eines Uploads an einen Callback.
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let progress: (@Sendable (Double) -> Void)?

    init(progress: (@Sendable (Double) -> Void)?) {
        self.progress = progress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        progress?(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}
