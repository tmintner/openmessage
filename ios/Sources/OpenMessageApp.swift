import SwiftUI

@main
struct OpenMessageApp: App {
    @StateObject private var backend = EmbeddedBackend()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(backend: backend)
                .onAppear { backend.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            // iOS suspends the process on background, freezing the backend's
            // goroutines and dropping its sockets. Nothing useful can be done
            // at that moment — the work is on the way back in, where the health
            // probe re-runs and the Go supervisors reconnect.
            if phase == .active {
                backend.applicationDidBecomeActive()
            }
        }
    }
}
