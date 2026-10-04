import Foundation
import Testing
@testable import MitschriftCore

@Suite struct WAVFileWriterTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("wavwriter-\(UUID().uuidString).wav")
    }

    @Test func writesValidFileIncrementally() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WAVFileWriter(url: url)
        try writer.append([1, 2, 3])
        try writer.append([4, 5])
        #expect(writer.durationSeconds == 5.0 / 16_000)
        try writer.close()
        let samples = try #require(WAVEncoder.samples(from: Data(contentsOf: url)))
        #expect(samples == [1, 2, 3, 4, 5])
    }

    @Test func repairsHeaderAfterCrash() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WAVFileWriter(url: url)
        try writer.append([7, 8, 9, 10])
        // Kein close(): Header steht auf Länge 0.
        let before = try Data(contentsOf: url)
        #expect(WAVEncoder.samples(from: before) == [])
        try WAVFileWriter.repairHeader(at: url)
        let samples = try #require(WAVEncoder.samples(from: Data(contentsOf: url)))
        #expect(samples == [7, 8, 9, 10])
    }
}
