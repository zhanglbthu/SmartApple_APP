import SwiftUI

@main
struct SensorReadApp: App {
    @StateObject private var recorder = SensorRecorder()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(recorder)
                .task {
#if targetEnvironment(simulator)
                    if CommandLine.arguments.contains("--auto-start-demo"), !recorder.isRecording {
                        recorder.start(host: "127.0.0.1", port: 9000)
                    }
#endif
            }
        }
    }
}
