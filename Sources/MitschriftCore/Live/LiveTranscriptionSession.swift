import Foundation
import Combine

/// Steuert eine Live-Sitzung: Warteschlange, Übertragung, Wiederholung und Zusammenführen der Antworten.
///
/// Plattformneutral. Die App liefert WAV-Segmente über `submit`, liest `transcript` und `status`
/// und ruft am Ende `finish()`.
@MainActor
public final class LiveTranscriptionSession: ObservableObject {
    public enum Status: Equatable, Sendable {
        case idle
        case connected
        case waiting(String)      // Wiederholung läuft; Text ist die Nutzermeldung
        case paused               // Warteschlange voll, Übertragung angehalten
        case finishing
        case finished
        case failed(String)
    }

    public let sessionId: String
    public let language: String

    @Published public private(set) var transcript = Transcript()
    @Published public private(set) var status: Status = .idle
    @Published public private(set) var queuedCount = 0
    @Published public private(set) var lastDiagnostics: Diagnostics?
    /// Segmente, die der Server endgültig abgelehnt hat (400/413). Zählt für den Hinweis in der UI.
    @Published public private(set) var droppedCount = 0

    private let transport: LiveTranscriptionTransport
    private let backoff: BackoffPolicy
    private let sleeper: @Sendable (TimeInterval) async -> Void
    private var queue: SegmentQueue
    private var nextSequence = 0
    private var drainTask: Task<Void, Never>?
    private var finishRequested = false

    public init(
        transport: LiveTranscriptionTransport,
        language: String = "de",
        sessionId: String = UUID().uuidString.lowercased(),
        queueCapacity: Int = 60,
        backoff: BackoffPolicy = BackoffPolicy(),
        sleeper: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.transport = transport
        self.language = language
        self.sessionId = sessionId
        self.queue = SegmentQueue(capacity: queueCapacity)
        self.backoff = backoff
        self.sleeper = sleeper
    }

    public var isActive: Bool {
        switch status {
        case .finished, .failed: return false
        default: return true
        }
    }

    /// Reiht ein WAV-Segment ein und stößt die Übertragung an. Liefert die vergebene Sequenznummer,
    /// oder `nil`, wenn die Warteschlange voll ist.
    @discardableResult
    public func submit(wavData: Data, capturedAt: Date = Date()) -> Int? {
        guard isActive, !finishRequested else { return nil }
        let segment = AudioSegment(sequence: nextSequence, data: wavData, capturedAt: capturedAt)
        guard queue.enqueue(segment) else {
            status = .paused
            return nil
        }
        nextSequence += 1
        queuedCount = queue.count
        if status == .paused || status == .idle { status = .connected }
        pump()
        return segment.sequence
    }

    /// Höchstzahl der `finish`-Versuche bei wiederholbaren Fehlern (Netz, 429, 5xx).
    public static let finishAttempts = 5

    /// Wartet, bis alle Segmente bestätigt sind, und schließt die Sitzung auf dem Server.
    ///
    /// Der Server liefert bei wiederholtem `finish` dieselbe Antwort (Vertrag), deshalb darf bei
    /// Netzfehlern wiederholt werden, ohne finale Segmente zu verlieren oder zu verdoppeln.
    public func finish() async {
        guard isActive else { return }
        finishRequested = true
        status = .finishing
        pump()
        await drainTask?.value
        guard case .finishing = status else { return }
        var attempt = 0
        while true {
            attempt += 1
            do {
                let response = try await transport.finish(sessionId: sessionId)
                transcript.apply(response)
                status = .finished
                return
            } catch {
                let failure = (error as? LiveTranscriptionError) ?? .transport(error.localizedDescription)
                if case .sessionNotFound = failure {
                    status = .finished
                    return
                }
                if failure.isRetryable, attempt < Self.finishAttempts, !Task.isCancelled {
                    status = .waiting(failure.userMessage)
                    await sleeper(backoff.delay(forAttempt: attempt))
                    status = .finishing
                    continue
                }
                status = .failed(failure.userMessage)
                return
            }
        }
    }

    /// Bricht ab, ohne auf den Server zu warten. Offene Segmente gehen verloren.
    public func cancel() {
        drainTask?.cancel()
        drainTask = nil
        queue.removeAll()
        queuedCount = 0
        if isActive { status = .finished }
    }

    private func pump() {
        guard drainTask == nil else { return }
        drainTask = Task { [weak self] in
            await self?.drain()
            self?.drainTask = nil
        }
    }

    private func drain() async {
        while !Task.isCancelled, let segment = queue.checkOut() {
            do {
                let response = try await transport.sendSegment(segment, sessionId: sessionId, language: language)
                queue.acknowledge(sequence: segment.sequence)
                transcript.apply(response)
                lastDiagnostics = response.diagnostics
                queuedCount = queue.count
                if status != .finishing { status = .connected }
            } catch let error as LiveTranscriptionError {
                if !(await handle(error, for: segment)) { return }
            } catch {
                let wrapped = LiveTranscriptionError.transport(error.localizedDescription)
                if !(await handle(wrapped, for: segment)) { return }
            }
        }
    }

    /// Liefert `false`, wenn die Schleife enden soll.
    private func handle(_ error: LiveTranscriptionError, for segment: AudioSegment) async -> Bool {
        if error.dropsSegment {
            queue.drop(sequence: segment.sequence)
            droppedCount += 1
            queuedCount = queue.count
            return true
        }
        if error.endsSession {
            queue.removeAll()
            queuedCount = 0
            status = .failed(error.userMessage)
            return false
        }
        let attempts = queue.requeue(sequence: segment.sequence)
        if status != .finishing { status = .waiting(error.userMessage) }
        await sleeper(backoff.delay(forAttempt: attempts))
        return !Task.isCancelled
    }
}
