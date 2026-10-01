//
//  CellaApp.swift
//  Cella
//
//  App entry point — configures fullscreen window with hidden title bar.
//

import SwiftUI
import Darwin
import AppKit

@main
struct CellaApp: App {
    init() {
        ignoreSIGPIPE()
        SeafoamCursor.install()
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

    private func ignoreSIGPIPE() {
        signal(SIGPIPE, SIG_IGN)
    }

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

// MARK: - Custom Cursor

enum SeafoamCursor {
    private static var circleCursor: NSCursor!
    private static var pressFrames: [NSCursor] = []
    private static var releaseFrames: [NSCursor] = []
    private static var animTimer: Timer?
    private static var animStep = 0
    private static var isAnimating = false
    private static var installed = false
    static var _inSet = false
    static var currentCursor: NSCursor!

    // MARK: - Theme

    private static func accentColor(for themeName: String) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        switch themeName {
        case "bipolar": return (1.0, 0.361, 0.541)
        case "seafoam": return (0.576, 0.914, 0.745)
        case "mint":    return (0.133, 0.827, 0.933)
        case "frutiger": return (0.243, 0.839, 0.596)
        default:        return (1.0, 0.502, 0.220)
        }
    }

    private static func currentThemeName() -> String {
        UserDefaults.standard.string(forKey: "themeOverride") ?? "dark"
    }

    // MARK: - Morph frame

    private static func makeMorphFrame(t: CGFloat, color: (r: CGFloat, g: CGFloat, b: CGFloat)) -> NSImage {
        let size = NSSize(width: 20, height: 20)
        let image = NSImage(size: size)
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            let fill = NSColor(red: color.r, green: color.g, blue: color.b, alpha: 1.0)
            ctx.setFillColor(fill.cgColor)

            let w = 16.0 - t * 4.0
            let h = 16.0 - t * 14.0
            let x = (20.0 - w) / 2.0
            let y = (20.0 - h) / 2.0
            let corner = max(1.0, (1.0 - t) * 8.0)

            let rect = CGRect(x: x, y: y, width: w, height: h)
            let path = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
            ctx.addPath(path)
            ctx.fillPath()

            if t < 0.5 {
                let borderAlpha = Float(0.5) * Float(1.0 - t * 2.0)
                let border = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: CGFloat(borderAlpha))
                ctx.setStrokeColor(border.cgColor)
                ctx.setLineWidth(1.0)
                let inset = CGRect(x: x + 0.5, y: y + 0.5, width: w - 1, height: h - 1)
                let borderPath = CGPath(roundedRect: inset, cornerWidth: corner, cornerHeight: corner, transform: nil)
                ctx.addPath(borderPath)
                ctx.strokePath()
            }
        }
        image.unlockFocus()
        return image
    }

    // MARK: - Rebuild

    static func rebuildCursors() {
        let color = accentColor(for: currentThemeName())
        circleCursor = NSCursor(image: makeMorphFrame(t: 0, color: color), hotSpot: NSPoint(x: 10, y: 10))
        currentCursor = circleCursor

        pressFrames = (0...4).map { i in
            let t = CGFloat(i) / 4.0
            return NSCursor(image: makeMorphFrame(t: t, color: color), hotSpot: NSPoint(x: 10, y: 10))
        }
        releaseFrames = pressFrames.reversed()
    }

    // MARK: - Animation

    private static func startAnimation(press: Bool) {
        animTimer?.invalidate()
        animTimer = nil
        isAnimating = true
        animStep = 0

        let frames = press ? pressFrames : releaseFrames
        guard !frames.isEmpty else {
            isAnimating = false
            currentCursor = circleCursor
            circleCursor?.set()
            return
        }

        animTimer = Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true) { timer in
            guard animStep < frames.count else {
                timer.invalidate()
                animTimer = nil
                if press {
                    isAnimating = false
                } else {
                    isAnimating = false
                    currentCursor = circleCursor
                    circleCursor?.set()
                }
                return
            }
            currentCursor = frames[animStep]
            frames[animStep].set()
            animStep += 1
        }
    }

    // MARK: - Install

    static func install() {
        guard !installed else { return }
        installed = true

        rebuildCursors()
        swizzleResetCursorRects()
        swizzleCursorSet()

        circleCursor.set()

        NSEvent.addLocalMonitorForEvents(matching: [
            .mouseMoved, .scrollWheel,
            .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp,
            .keyDown, .keyUp,
            .flagsChanged
        ]) { event in
            switch event.type {
            case .leftMouseDown, .rightMouseDown:
                startAnimation(press: true)
            case .leftMouseUp, .rightMouseUp:
                if isAnimating { startAnimation(press: false) }
            default:
                if !isAnimating {
                    circleCursor?.set()
                }
            }
            return event
        }

        let center = NotificationCenter.default
        center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            rebuildCursors()
            if !isAnimating { circleCursor?.set() }
        }
    }

    // MARK: - Swizzles

    private static func swizzleResetCursorRects() {
        let a = class_getInstanceMethod(NSView.self, #selector(NSView.resetCursorRects))
        let b = class_getInstanceMethod(NSView.self, #selector(NSView.cellSwizzled_resetCursorRects))
        if let a, let b { method_exchangeImplementations(a, b) }
    }

    private static func swizzleCursorSet() {
        let a = class_getInstanceMethod(NSCursor.self, #selector(NSCursor.set))
        let b = class_getInstanceMethod(NSCursor.self, #selector(NSCursor.cellSwizzled_set))
        if let a, let b { method_exchangeImplementations(a, b) }
    }
}

// MARK: - NSView swizzle — kill cursor rects inside our views

extension NSView {
    @objc func cellSwizzled_resetCursorRects() {
        guard let cv = self.window?.contentView else {
            self.cellSwizzled_resetCursorRects()
            return
        }
        if self === cv {
            return
        } else {
            self.cellSwizzled_resetCursorRects()
        }
    }
}

// MARK: - NSCursor swizzle — redirect all .set() to our cursor, except I-beam for text input

extension NSCursor {
    @objc func cellSwizzled_set() {
        if SeafoamCursor._inSet {
            self.cellSwizzled_set()
            return
        }
        if self === NSCursor.iBeam {
            self.cellSwizzled_set()
            return
        }
        SeafoamCursor._inSet = true
        SeafoamCursor.currentCursor?.set()
        SeafoamCursor._inSet = false
    }
}
