//
//  CellaApp.swift
//  Cella
//
//  App entry point — configures fullscreen window with hidden title bar.
//

import SwiftUI

@main
struct CellaApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    enterFullScreen()
                }
        }
        .windowStyle(.hiddenTitleBar)
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
