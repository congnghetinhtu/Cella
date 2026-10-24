//
//  CellaIOSApp.swift
//  CellaIOS
//
//  iOS app entry. One now-playing screen: cover, synced lyrics, progress bar
//  and the playing pill, over the shared Metro aero backdrop. Single theme
//  only — Frutiger Aurora, with the playing-pill white flip. The theme
//  environment is injected here, once per theme change, so the 30 Hz clock
//  inside the screen never churns the environment.
//

import SwiftUI

@main
struct CellaIOSApp: App {
    @State private var player = IOSPlayerModel()
    @AppStorage("whiteMode") private var whiteMode = false

    var body: some Scene {
        WindowGroup {
            NowPlayingScreen(player: player, whiteMode: $whiteMode)
                .environment(\.theme, whiteMode ? .frutigerLight : .frutiger)
        }
    }
}
