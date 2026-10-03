import SwiftUI
import MitschriftCore

@main
struct MitschriftIOSApp: App {
    @StateObject private var settings = SettingsStore()
    @StateObject private var recorder = RecordingController()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(recorder)
        }
    }
}

private struct RootView: View {
    var body: some View {
        TabView {
            RecordView()
                .tabItem { Label("Aufnahme", systemImage: "mic.fill") }
            SettingsView()
                .tabItem { Label("Server", systemImage: "network") }
        }
    }
}
