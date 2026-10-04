import SwiftUI
import MitschriftCore

@main
struct MitschriftIOSApp: App {
    @StateObject private var settings = SettingsStore()
    @StateObject private var recorder = RecordingController()

    var body: some Scene {
        WindowGroup {
            RecordView()
                .environmentObject(settings)
                .environmentObject(recorder)
        }
    }
}
