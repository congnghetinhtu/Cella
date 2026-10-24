//
//  FileOpenRouter.swift
//  Cella
//
//  Routes file-open events (Finder "Open With", double-click, drag & drop)
//  into a single pending-audio slot that ContentView observes. The app-level
//  AppDelegate resolves incoming URLs, filters them against the supported
//  audio whitelist, and drops the first match here.
//

import Foundation
import Combine

/// Whitelist of audio extensions the app can open directly.
enum AudioFileExtensions {
    static let supported: Set<String> = ["mp3", "wav", "m4a", "flac", "aac", "caf", "ogg", "aif"]
}

/// ObservableObject singleton bridging AppKit open-url delivery into SwiftUI.
final class FileOpenRouter: ObservableObject {
    static let shared = FileOpenRouter()

    @Published var pendingAudioURL: URL?
}