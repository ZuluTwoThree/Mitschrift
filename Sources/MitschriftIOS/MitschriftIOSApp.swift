import SwiftUI
import MitschriftCore

@main
struct MitschriftIOSApp: App {
    @StateObject private var settings = SettingsStore()
    @StateObject private var recorder = RecordingController()
    @StateObject private var library = RecordingLibraryModel()

    var body: some Scene {
        WindowGroup {
            RecordView()
                .environmentObject(settings)
                .environmentObject(recorder)
                .environmentObject(library)
                .task { library.repairAndReload() }
        }
    }
}
