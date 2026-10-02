import Foundation

/// Konfigurierter ASR-Server: private HTTPS-URL im Tailnet und Anwendungstoken.
public struct ServerEndpoint: Equatable, Sendable {
    public var baseURL: URL
    public var token: String

    public init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }

    /// Prüft eine vom Nutzer eingegebene Adresse. Erlaubt nur `https`, ergänzt das Schema, wenn es fehlt.
    public static func normalizedURL(from input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else {
            return nil
        }
        return url
    }
}

/// Ablage der Serverkonfiguration. Die URL darf in UserDefaults liegen, der Token gehört in den Schlüsselbund.
public protocol EndpointStore: AnyObject {
    func load() -> ServerEndpoint?
    func save(_ endpoint: ServerEndpoint) throws
    func clear() throws
}

/// Ablage nur im Speicher, für Tests und Vorschauen.
public final class InMemoryEndpointStore: EndpointStore {
    private var endpoint: ServerEndpoint?

    public init(_ endpoint: ServerEndpoint? = nil) {
        self.endpoint = endpoint
    }

    public func load() -> ServerEndpoint? { endpoint }
    public func save(_ endpoint: ServerEndpoint) throws { self.endpoint = endpoint }
    public func clear() throws { endpoint = nil }
}
