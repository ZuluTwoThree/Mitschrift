import Foundation

/// Netzwerkseite des Vertrags. Austauschbar für Tests.
public protocol LiveTranscriptionTransport: Sendable {
    func sendSegment(_ segment: AudioSegment, sessionId: String, language: String) async throws -> SegmentResponse
    func finish(sessionId: String) async throws -> FinishResponse
    func health() async throws -> HealthResponse
}

/// Umsetzung des Vertrags mit `URLSession`.
public final class URLSessionLiveTransport: LiveTranscriptionTransport, @unchecked Sendable {
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

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await data(for: request)
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

    private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw LiveTranscriptionError.transport(error.localizedDescription)
        }
    }
}
