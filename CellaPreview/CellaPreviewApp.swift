//
//  CellaPreviewApp.swift
//  CellaPreview
//
//  Dedicated companion app for fast audio previews. Launched via Finder
//  "Open With → Cella Preview" it pops a single mini player window that
//  replaces its content on every new file. No fullscreen player UI, no
//  automix — just the independent preview engine.
//

import SwiftUI
import AppKit

@main
struct CellaPreviewApp: App {
    @NSApplicationDelegateAdaptor(PreviewAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class PreviewAppDelegate: NSObject, NSApplicationDelegate {
    private let viewModel = MiniPlayerViewModel()
    private lazy var windowController = PreviewWindowController(viewModel: viewModel)

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: {
            AudioFileExtensions.supported.contains($0.pathExtension.lowercased())
        }) else { return }

        viewModel.open(url: url)
        windowController.show(theme: resolvedTheme())
        application.activate(ignoringOtherApps: true)
    }

    /// Mirrors the main app's themeOverride mapping so the preview window
    /// matches the user's chosen look.
    private func resolvedTheme() -> Theme {
        switch UserDefaults.standard.string(forKey: "themeOverride") {
        case "bipolar": return .bipolar
        case "mint": return .mint
        case "dark": return .dark
        default: return .seafoam
        }
    }
}