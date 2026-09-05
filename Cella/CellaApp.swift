//
//  CellaApp.swift
//  Cella
//
//  App entry point — configures fullscreen window with hidden title bar.
//

import SwiftUI
import Darwin

@main
struct CellaApp: App {
    init() {
        // Writing to a pipe whose reader (e.g. the OpenMix Python subprocess)
        // has just exited raises SIGPIPE, which terminates the app by default.
        ignoreSIGPIPE()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    enterFullScreen()
                }
        }
        .windowStyle(.hiddenTitleBar)
    }

    /// Ignore SIGPIPE so a dead IPC pipe can't crash the app.
    private func ignoreSIGPIPE() {
        signal(SIGPIPE, SIG_IGN)
    }

    // MARK: - Fullscreen

    /// Toggles the window to fullscreen shortly after launch.
    private func enterFullScreen() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            if let window = NSApplication.shared.windows.first,
               !window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }
        }
    }
}
