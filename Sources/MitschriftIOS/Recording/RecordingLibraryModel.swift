import Foundation
import Combine
import MitschriftCore

/// Die gespeicherten Aufnahmen für die Liste: liest den Ordner, ergänzt Dauern, repariert beim Start
/// unvollständige WAV-Dateien und löscht Aufnahmen.
@MainActor
final class RecordingLibraryModel: ObservableObject {
    @Published private(set) var items: [RecordingItem] = []
    @Published private(set) var repairedCount = 0
    @Published private(set) var error: String?

    let library: RecordingLibrary?

    init() {
        library = (try? RecordingsDirectory.url()).map { RecordingLibrary(directory: $0) }
    }

    /// Beim Start: Dateien nach einem Absturz nachbessern, dann die Liste lesen.
    func repairAndReload() {
        guard let library else { return }
        repairedCount = library.repairUnfinishedRecordings()
        reload()
    }

    func reload() {
        guard let library else { return }
        items = library.items().map { item in
            var item = item
            if item.duration == nil, !item.needsRepair {
                item.duration = AudioFileReader.duration(of: item.audioURL)
            }
            return item
        }
    }

    var totalBytes: Int { items.reduce(0) { $0 + $1.fileSize } }

    func delete(_ item: RecordingItem) {
        guard let library else { return }
        do {
            try library.delete(item)
            error = nil
        } catch {
            self.error = "Löschen fehlgeschlagen: \(error.localizedDescription)"
        }
        reload()
    }

    func delete(ids: Set<String>) {
        for item in items where ids.contains(item.id) {
            delete(item)
        }
    }

    static func sizeText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
