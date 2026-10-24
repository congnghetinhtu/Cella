//
//  MiniPlayerViewModel.swift
//  Cella
//
//  View model for the floating WAV preview mini player. It owns an independent
//  PreviewAudioEngine plus its own Orquesta state, persisted under dedicated
//  `mini.*` keys — none of it touches the main PlayerViewModel engine, the
//  Config tab values, or the global theme override.
//

import SwiftUI
import AVFoundation

@MainActor
@Observable
final class MiniPlayerViewModel {
    // MARK: - Independent storage keys

    private static let presetStorageKey = "mini.orquestaPresetID"
    private static let customGainsStorageKey = "mini.orquestaCustomGains"
    private static let surroundStorageKey = "mini.surroundMode"

    // MARK: - Dependencies

    let engine = PreviewAudioEngine(config: .standard)

    // MARK: - State

    var url: URL?
    var title: String = ""
    var metadata: AudioFileMetadata?
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var volume: Float = 1.0
    var isLooping = false
    var isVisible = false
    var loadError: String?

    var currentPreset: OrquestaPreset = .natural
    var surroundMode: SurroundMode = .off

    var allPresets: [OrquestaPreset] {
        OrquestaPreset.factoryPresets + [OrquestaPreset.custom]
    }

    private var uiTimer: Timer?

    // MARK: - Init

    init() {
        engine.onTrackEnd = { [weak self] in
            self?.handleTrackEnd()
        }
        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.syncPlaybackTime()
            }
        }
    }

    private func syncPlaybackTime() {
        currentTime = engine.currentTime
        duration = engine.duration
    }

    private func handleTrackEnd() {
        if isLooping {
            engine.seek(to: 0)
            engine.play()
            isPlaying = true
        } else {
            isPlaying = false
        }
    }

    // MARK: - Transport

    func open(url: URL) {
        self.url = url
        title = url.deletingPathExtension().lastPathComponent
        loadError = nil

        isVisible = true
        isPlaying = false
        currentTime = 0

        do {
            try engine.load(url: url)
            engine.setVolume(volume)
            duration = engine.duration
            restoreStoredOrquesta()
            engine.play()
            isPlaying = true
        } catch {
            loadError = error.localizedDescription
            duration = 0
        }

        loadMetadata()
    }

    func close() {
        isVisible = false
        engine.stop()
        isPlaying = false
        currentTime = 0
        duration = 0
        metadata = nil
    }

    func togglePlayPause() {
        guard url != nil else { return }
        if isPlaying {
            engine.pause()
            isPlaying = false
        } else {
            engine.play()
            isPlaying = true
        }
        syncPlaybackTime()
    }

    func seek(to time: TimeInterval) {
        let clamped = max(0, min(time, engine.duration))
        engine.seek(to: clamped)
        syncPlaybackTime()
    }

    func setVolume(_ newVolume: Float) {
        volume = min(1, max(0, newVolume))
        engine.setVolume(volume)
    }

    func toggleLoop() {
        isLooping.toggle()
    }

    private func loadMetadata() {
        Task { [weak self] in
            guard let self, let url = self.url else { return }
            let meta = await AudioFileMetadataLoader.load(for: url)
            guard self.url == url else { return }
            self.metadata = meta
        }
    }

    // MARK: - Orquesta (scoped to mini storage + preview engine)

    func selectPreset(_ preset: OrquestaPreset) {
        currentPreset = preset
        engine.setSoloBand(nil)
        engine.applyProfileEQ(preset)
        UserDefaults.standard.set(preset.id, forKey: Self.presetStorageKey)
        if !preset.isCustom {
            applySurround(preset.surround)
        }
    }

    func applyCustomGain(_ index: Int, _ gain: Float) {
        var gains = OrquestaPreset.readCustomGains()
        guard gains.indices.contains(index) else { return }
        gains[index] = min(6, max(-6, gain))
        OrquestaPreset.saveCustomGains(gains)
        let custom = OrquestaPreset.custom
        if currentPreset != custom {
            selectPreset(custom)
        } else {
            engine.applyProfileEQ(custom)
        }
    }

    func applySurround(_ mode: SurroundMode) {
        surroundMode = mode
        engine.setSurroundMode(mode)
        UserDefaults.standard.set(mode.rawValue, forKey: Self.surroundStorageKey)
    }

    /// Solo a single EQ band (0–9). Pass nil to unsolo.
    func setSoloBand(_ index: Int?) {
        engine.setSoloBand(index)
        engine.applyProfileEQ(currentPreset)
    }

    func resetOrquesta() {
        withAnimation(.smooth) {
            OrquestaPreset.resetCustomGains()
            selectPreset(.natural)
        }
    }

    private func restoreStoredOrquesta() {
        let storedID = UserDefaults.standard.string(forKey: Self.presetStorageKey)
        let preset = OrquestaPreset.resolve(
            storedID == OrquestaPreset.storageKeyEmpty ? nil : storedID
        )
        currentPreset = preset
        engine.applyProfileEQ(preset)

        let mode = UserDefaults.standard.string(forKey: Self.surroundStorageKey)
            .flatMap { SurroundMode(rawValue: $0) } ?? .off
        surroundMode = mode
        engine.setSurroundMode(mode)
    }
}