import SwiftUI

@main
struct RaummodeApp: App {
    @StateObject private var capture = CaptureEngine()
    @StateObject private var session = SessionStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(capture)
                .environmentObject(session)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var capture: CaptureEngine

    var body: some View {
        TabView {
            RTAView()
                .tabItem { Label("RTA", systemImage: "waveform.path.ecg") }
            SweepView()
                .tabItem { Label("Sweep", systemImage: "waveform") }
            SessionView()
                .tabItem { Label("Session", systemImage: "square.stack.3d.up") }
            InfoView()
                .tabItem { Label("Info", systemImage: "info.circle") }
        }
        .task { await capture.requestPermissionAndStart() }
    }
}
