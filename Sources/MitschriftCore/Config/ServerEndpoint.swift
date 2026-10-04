import Foundation

/// Konfigurierter ASR-Server: private HTTPS-URL im Tailnet und Anwendungstoken.
public struct ServerEndpoint: Equatable, Sendable {
    public var baseURL: URL
    public var token: String

    public init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }

    /// Prüft eine vom Nutzer eingegebene Adresse. Erlaubt `https`; `http` nur für Loopback-Adressen
    /// (Entwicklung mit Simulator und lokalem Adapter). Ergänzt `https://`, wenn das Schema fehlt.
    public static func normalizedURL(from input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        switch url.scheme?.lowercased() {
        case "https": return url
        case "http": return isLoopback(host) ? url : nil
        default: return nil
        }
    }

    public static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
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
