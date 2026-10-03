import Foundation

/// Transkribiert Dateien lokal mit `whisper-cli` aus Homebrew; wandelt fremde Formate vorher mit `ffmpeg`.
///
/// Nur macOS: nutzt `Process`. Die Modelle liegen im App-Bundle unter `Resources/models`.
struct LocalWhisperEngine: FileTranscriptionEngine {
    enum Failure: LocalizedError {
        case whisperMissing
        case modelMissing(String)
        case ffmpegMissing
        case processFailed(String)

        var errorDescription: String? {
            switch self {
            case .whisperMissing:
                return "Die lokale Whisper-Engine wurde nicht gefunden. Bitte installiere whisper.cpp mit Homebrew."
            case .modelMissing(let name):
                return "Das Whisper-Sprachmodell „\(name)“ fehlt im App-Paket."
            case .ffmpegMissing:
                return "Für M4A-Dateien wird FFmpeg benötigt. Bitte installiere es mit Homebrew."
            case .processFailed(let message):
                return message
            }
        }
    }

    static let nativeFormats: Set<String> = ["wav", "mp3", "flac", "ogg"]

    var modelName: String
    var outputDirectory: URL

    func transcribe(fileURL: URL, language: String) async throws -> String {
        guard let whisper = Self.whisperExecutable() else { throw Failure.whisperMissing }
        guard let model = Self.modelURL(named: modelName) else { throw Failure.modelMissing(modelName) }

        let needsConversion = !Self.nativeFormats.contains(fileURL.pathExtension.lowercased())
        let converter = needsConversion ? Self.ffmpegExecutable() : nil
        if needsConversion && converter == nil { throw Failure.ffmpegMissing }

        let outputURL = outputDirectory.appendingPathComponent(
            RecordingNaming.transcriptFileName(forAudioNamed: fileURL.lastPathComponent)
        )
        let outputPrefix = outputURL.deletingPathExtension().path
        try? FileManager.default.removeItem(at: outputURL)

        return try await Task.detached(priority: .userInitiated) {
            var temporaryAudioURL: URL?
            defer {
                if let temporaryAudioURL { try? FileManager.default.removeItem(at: temporaryAudioURL) }
            }

            let whisperInput: URL
            if let converter {
                let converted = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Mitschrift-\(UUID().uuidString).wav")
                temporaryAudioURL = converted
                try Self.run(
                    executable: converter,
                    arguments: [
                        "-y", "-hide_banner", "-loglevel", "error",
                        "-i", fileURL.path,
                        "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le",
                        converted.path
                    ],
                    failureMessage: "Die Audiodatei konnte nicht in WAV umgewandelt werden."
                )
                whisperInput = converted
            } else {
                whisperInput = fileURL
            }

            try Self.run(
                executable: whisper,
                arguments: [
                    "-m", model.path,
                    "-f", whisperInput.path,
                    "-l", language,
                    "-otxt", "-of", outputPrefix,
                    "-nt", "-np", "-ng"
                ],
                failureMessage: "Whisper konnte die Audiodatei nicht transkribieren."
            )

            return try String(contentsOf: outputURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }

    private static func run(executable: URL, arguments: [String], failureMessage: String) throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        try process.run()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let diagnostics = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw Failure.processFailed(diagnostics.isEmpty ? failureMessage : "\(failureMessage)\n\(diagnostics)")
        }
    }

    static func whisperExecutable() -> URL? {
        let candidates = [
            Bundle.main.url(forResource: "whisper-cli", withExtension: nil, subdirectory: "bin"),
            URL(fileURLWithPath: "/opt/homebrew/bin/whisper-cli"),
            URL(fileURLWithPath: "/usr/local/bin/whisper-cli")
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func ffmpegExecutable() -> URL? {
        let candidates = [
            URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
            URL(fileURLWithPath: "/usr/local/bin/ffmpeg")
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func modelURL(named name: String) -> URL? {
        Bundle.main.url(forResource: "ggml-\(name)", withExtension: "bin", subdirectory: "models")
    }
}
