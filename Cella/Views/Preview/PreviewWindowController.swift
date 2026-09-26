//
//  PreviewWindowController.swift
//  Cella
//
//  Hosts the preview mini player in its own floating macOS window — the same
//  pattern as Quick Look / Preview: a separate closeable card above the main
//  app (even when the main window is fullscreen), draggable, and independent
//  from the Cella tab's player.
//

import AppKit
import SwiftUI

/// Owns the `NSPanel` that displays `MiniPlayerView`. Content state stays in
/// `MiniPlayerViewModel`; this controller only manages the window shell.
final class PreviewWindowController: NSObject {
    private let viewModel: MiniPlayerViewModel
    private var panel: NSPanel?
    private var hostingView: NSHostingView<AnyView>?

    init(viewModel: MiniPlayerViewModel) {
        self.viewModel = viewModel
        super.init()
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: - Show / Hide

    func show(theme: Theme) {
        if panel == nil { buildWindow(theme: theme) }
        updateTheme(theme)
        positionWindow()
        panel?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        if let panel, let hostingView {
            panel.makeFirstResponder(hostingView)
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func updateTheme(_ theme: Theme) {
        hostingView?.rootView = AnyView(
            MiniPlayerView(viewModel: viewModel).environment(\.theme, theme)
        )
    }

    // MARK: - Window Shell

    private func buildWindow(theme: Theme) {
        let hosting = NSHostingView(
            rootView: AnyView(
                MiniPlayerView(viewModel: viewModel).environment(\.theme, theme)
            )
        )
        hostingView = hosting

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = viewModel.title
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = hosting

        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        panel.setContentSize(size)

        self.panel = panel
    }

    /// Bottom-trailing of the screen hosting the main window (fullscreen-aware).
    private func positionWindow() {
        guard let panel else { return }
        let screen = NSApp.keyWindow?.screen
            ?? panel.screen
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }

        let margin: CGFloat = 24
        let size = panel.frame.size
        let origin = NSPoint(
            x: frame.maxX - size.width - margin,
            y: frame.minY + margin
        )
        panel.setFrameOrigin(origin)
    }
}

// MARK: - NSWindowDelegate

extension PreviewWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        viewModel.close()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let panel, let hostingView {
            panel.makeFirstResponder(hostingView)
        }
    }
}