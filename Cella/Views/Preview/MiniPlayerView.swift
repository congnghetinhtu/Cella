//
//  MiniPlayerView.swift
//  Cella
//
//  Floating mini player card for previewing a single audio file (typically a
//  WAV dropped anywhere on the window or opened via Finder "Open With"). Card
//  layout mirrors the Config tab's bento styling, and its compact Cella
//  Orquesta panel drives the independent preview engine — never the main
//  player or the global theme.
//

import SwiftUI

struct MiniPlayerView: View {
    var viewModel: MiniPlayerViewModel
    @Environment(\.theme) private var theme

    private let cardRadius: CGFloat = 18

    // Orquesta compact state
    @State private var draggingBand: Int?
    @State private var dragStartGain: Float = 0
    @State private var soloBand: Int?

    private var frequencies: [Float] { OrquestaPreset.eqFrequencies }

    private var currentGains: [Float] {
        viewModel.currentPreset.eqBands.map { $0.gain }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider().background(theme.textSecondary.opacity(0.10))
            transport
            Divider().background(theme.textSecondary.opacity(0.10))
            orquestaPanel
        }
        .padding(16)
        .frame(width: 420)
        .background(theme.screenBackground)
        .clipShape(RoundedRectangle(cornerRadius: cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cardRadius)
                .stroke(theme.textSecondary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: theme.haloPrimary.opacity(0.18), radius: 24, y: 10)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) {
            viewModel.togglePlayPause()
            return .handled
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.dotActive.opacity(0.14))
                .frame(width: 40, height: 40)
                .overlay(
                    Image(systemName: "waveform")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(theme.dotActive)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(viewModel.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    if let meta = viewModel.metadata {
                        if let codec = meta.codec, codec.uppercased().contains("PCM") {
                            badge("PCM", tint: theme.haloAccent)
                        }
                        if let sr = meta.sampleRateLabel {
                            badge(sr, tint: theme.textSecondary)
                        }
                        if meta.qualityLabel == "Lossless" {
                            badge("Lossless", tint: theme.haloWarm)
                        }
                    }
                }
            }

            Spacer(minLength: 8)

            Button {
                viewModel.close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(theme.dotInactive.opacity(0.5)))
            }
            .buttonStyle(.plain)
            .help("Close preview")
        }
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.12)))
            .overlay(Capsule().stroke(tint.opacity(0.3), lineWidth: 0.5))
    }

    // MARK: - Transport

    private var transport: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    viewModel.togglePlayPause()
                } label: {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(theme.dotActive))
                        .shadow(color: theme.haloPrimary.opacity(0.5), radius: 8)
                }
                .buttonStyle(.plain)

                scrubBar

                Button {
                    viewModel.toggleLoop()
                } label: {
                    Image(systemName: viewModel.isLooping ? "repeat" : "repeat")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(viewModel.isLooping ? theme.dotActive : theme.textSecondary)
                        .frame(width: 26, height: 26)
                        .background(
                            Circle().fill(viewModel.isLooping ? theme.dotActive.opacity(0.15) : theme.dotInactive.opacity(0.5))
                        )
                }
                .buttonStyle(.plain)
                .help("Loop track")

                Image(systemName: "speaker.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.textSecondary)

                Slider(value: volumeBinding, in: 0...1)
                    .controlSize(.mini)
                    .frame(width: 70)
            }

            HStack {
                Text(timeLabel(viewModel.currentTime))
                Spacer()
                Text(timeLabel(viewModel.duration))
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(theme.textSecondary.opacity(0.8))
        }
    }

    private var volumeBinding: Binding<Float> {
        Binding(
            get: { viewModel.volume },
            set: { viewModel.setVolume($0) }
        )
    }

    private var scrubBar: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let progress = viewModel.duration > 0
                ? min(1, max(0, viewModel.currentTime / viewModel.duration))
                : 0
            let barHeight: CGFloat = 6

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.dotInactive.opacity(0.7))
                    .frame(height: barHeight)

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [theme.dotActive, theme.haloSecondary],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(barHeight, width * progress), height: barHeight)

                Circle()
                    .fill(.white)
                    .frame(width: 10, height: 10)
                    .shadow(color: theme.haloPrimary.opacity(0.7), radius: 5)
                    .offset(x: width * progress - 5)
            }
            .frame(height: 20, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = min(1, max(0, value.location.x / max(1, width)))
                        viewModel.seek(to: Double(fraction) * viewModel.duration)
                    }
            )
        }
        .frame(height: 20)
    }

    // MARK: - Orquesta compact

    private var orquestaPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "music.quarternote.3")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.dotActive)
                Text("Cella Orquesta")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Text("PREVIEW")
                    .font(.system(size: 7, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(theme.dotActive)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(theme.dotActive.opacity(0.12)))
                    .overlay(Capsule().stroke(theme.dotActive.opacity(0.35), lineWidth: 0.5))
                Spacer()
                if let solo = soloBand {
                    Text("Solo: \(freqLabel(frequencies[solo])) Hz")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.haloWarm)
                }
            }

            presetRow

            bandBars

            HStack(spacing: 8) {
                surroundSegmented

                Button {
                    viewModel.resetOrquesta()
                    soloBand = nil
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 34, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 9)
                                .fill(theme.dotInactive.opacity(0.4))
                        )
                }
                .buttonStyle(.plain)
                .help("Reset (curve + surround)")
            }
        }
    }

    private var presetRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(viewModel.allPresets, id: \.id) { preset in
                    let isSelected = preset.id == viewModel.currentPreset.id
                    Button {
                        viewModel.selectPreset(preset)
                        soloBand = nil
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: preset.iconName)
                                .font(.system(size: 10))
                            Text(preset.displayName)
                                .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                        }
                        .foregroundStyle(isSelected ? .white : theme.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isSelected ? preset.accentColor : theme.dotInactive.opacity(0.4))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var bandBars: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(frequencies.indices, id: \.self) { i in
                bandBar(index: i)
            }
        }
        .padding(.horizontal, 2)
        .frame(height: 96)
    }

    private func bandBar(index: Int) -> some View {
        let gain = currentGains[safe: index] ?? 0
        let isSolo = soloBand == index
        let trackHeight: CGFloat = 88
        let barHeight = CGFloat(abs(gain) / 6.0) * 40
        let boosted = gain > 0

        return VStack(spacing: 3) {
            ZStack {
                Capsule()
                    .fill(theme.dotInactive.opacity(0.55))
                    .frame(width: 10, height: trackHeight)

                if abs(gain) > 0.01 {
                    Capsule()
                        .fill(boosted ? theme.dotActive : theme.haloWarm)
                        .frame(width: 10, height: max(3, barHeight))
                        .frame(height: trackHeight, alignment: boosted ? .bottom : .top)
                }
            }
            .overlay(
                Capsule()
                    .stroke(isSolo ? theme.haloWarm : theme.textSecondary.opacity(0.0), lineWidth: 1)
            )
            .frame(width: 16, height: trackHeight)
            .contentShape(Rectangle())
            .animation(.smooth(duration: 0.15), value: gain)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if draggingBand != index {
                            draggingBand = index
                            dragStartGain = gain
                        }
                        let perPixel: CGFloat = 6.0 / 40.0
                        let newGain = dragStartGain - Float(value.translation.height) * Float(perPixel)
                        viewModel.applyCustomGain(index, newGain)
                    }
                    .onEnded { _ in
                        draggingBand = nil
                    }
            )
            .onTapGesture {
                soloBand = (soloBand == index) ? nil : index
                viewModel.setSoloBand(soloBand)
            }
            .help("\(String(format: "%+.1f", gain)) dB — tap to solo")

            Text(freqLabel(frequencies[index]))
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(soloBand == index ? theme.textPrimary : theme.textSecondary.opacity(0.6))
        }
    }

    private var surroundSegmented: some View {
        HStack(spacing: 6) {
            ForEach(SurroundMode.allCases, id: \.self) { mode in
                let isSelected = mode == viewModel.surroundMode
                Button {
                    viewModel.applySurround(mode)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: mode.iconName)
                            .font(.system(size: 10))
                        Text(mode.displayName)
                            .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                    }
                    .foregroundStyle(isSelected ? .white : theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(isSelected ? theme.dotActive : theme.dotInactive.opacity(0.3))
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Helpers

    private func freqLabel(_ f: Float) -> String {
        if f >= 1000 { return String(format: "%.0fK", f / 1000) }
        return String(format: "%.0f", f)
    }

    private func timeLabel(_ t: TimeInterval) -> String {
        let total = max(0, Int(t))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

#Preview {
    let mini = MiniPlayerViewModel()
    mini.title = "demo-audio"
    return MiniPlayerView(viewModel: mini)
        .environment(\.theme, .seafoam)
        .padding(40)
        .background(Color.black)
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}