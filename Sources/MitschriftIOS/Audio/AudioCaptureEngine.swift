import Foundation
import AVFoundation
import MitschriftCore

/// Mikrofonaufnahme mit `AVAudioEngine`, konvertiert auf 16 kHz mono Int16.
///
/// Liefert Samples über `onSamples` auf einer Hintergrund-Queue. Unterbrechungen (Anruf, Siri)
/// werden über `onInterruption` gemeldet; die Engine pausiert dann und setzt nach Ende fort.
final class AudioCaptureEngine: @unchecked Sendable {
    enum Failure: LocalizedError {
        case permissionDenied
        case sessionUnavailable(String)
        case formatUnavailable

        var errorDescription: String? {
            switch self {
            case .permissionDenied: return "Mikrofonzugriff wurde nicht erlaubt."
            case .sessionUnavailable(let reason): return "Audio konnte nicht gestartet werden: \(reason)"
            case .formatUnavailable: return "Das Mikrofonformat kann nicht in 16 kHz mono umgewandelt werden."
            }
        }
    }

    enum InterruptionEvent {
        case began
        case ended(shouldResume: Bool)
    }

    var onSamples: (([Int16]) -> Void)?
    var onInterruption: ((InterruptionEvent) -> Void)?

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var observers: [NSObjectProtocol] = []
    private(set) var isRunning = false

    private static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: Double(WAVEncoder.sampleRate),
        channels: AVAudioChannelCount(WAVEncoder.channels),
        interleaved: true
    )!

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    static var permissionStatus: AVAudioApplication.recordPermission {
        AVAudioApplication.shared.recordPermission
    }

    func start() throws {
        guard !isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
            try session.setPreferredSampleRate(Double(WAVEncoder.sampleRate))
            try session.setActive(true, options: [])
        } catch {
            throw Failure.sessionUnavailable(error.localizedDescription)
        }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
              let converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat) else {
            throw Failure.formatUnavailable
        }
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.convertAndForward(buffer)
        }
        installObservers(session: session)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw Failure.sessionUnavailable(error.localizedDescription)
        }
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Nach einer Unterbrechung die Engine wieder anwerfen.
    func resume() throws {
        guard isRunning, !engine.isRunning else { return }
        try AVAudioSession.sharedInstance().setActive(true, options: [])
        try engine.start()
    }

    private func convertAndForward(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = Self.targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0, let channel = output.int16ChannelData else { return }
        let samples = Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
        onSamples?(samples)
    }

    private func installObservers(session: AVAudioSession) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began:
                self.onInterruption?(.began)
            case .ended:
                let options = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
                self.onInterruption?(.ended(shouldResume: options.contains(.shouldResume)))
            @unknown default:
                break
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] _ in
            // Kopfhörer rein/raus: Engine läuft weiter, Format kann sich ändern → Tap neu setzen.
            guard let self, self.isRunning else { return }
            if !self.engine.isRunning { try? self.engine.start() }
        })
    }
}
