//
//  MusicIndicatorView.swift
//  Cella
//
//  Now-playing widget with track info and playback controls.
//

import SwiftUI

struct MusicIndicatorView: View {
    @Environment(\.theme) private var theme
    var viewModel: PlayerViewModel

    private let cardRadius: CGFloat = 18
    private let cardPadding: CGFloat = 28

    private var cardBorder: some ShapeStyle {
        theme.textSecondary.opacity(0.10)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if viewModel.hasTracks {
                trackInfo
                progressBar
                controls
            } else {
                emptyState
            }
        }
        .padding(.vertical, cardPadding + 6)
        .padding(.horizontal, cardPadding + 4)
        .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
        .background(theme.screenBackground)
        .clipShape(RoundedRectangle(cornerRadius: cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cardRadius)
                .stroke(cardBorder, lineWidth: 1)
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "music.note")
                .font(.system(size: 13))
                .foregroundStyle(theme.dotActive)
            Text("Now Playing")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            Spacer()
            if let track = viewModel.mixQueue?.currentTrack {
                Text(track.artistName ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Track Info

    private var trackInfo: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let track = viewModel.mixQueue?.currentTrack {
                Text(track.trackTitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
            }
            Text(viewModel.statusText ?? "No track")
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
        }
    }

    // MARK: - Progress Bar

    private var progressBar: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(theme.dotInactive.opacity(0.3))
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(theme.dotActive)
                        .frame(width: progressWidth(total: geo.size.width), height: 4)
                }
            }
            .frame(height: 4)

            HStack {
                Text(formatTime(viewModel.currentTime))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                Text(formatTime(viewModel.currentDuration))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 24) {
            Spacer()
            Button {
                viewModel.skipBackward()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(theme.textPrimary)
            }
            .buttonStyle(.plain)

            Button {
                viewModel.togglePlayPause()
            } label: {
                Image(systemName: viewModel.playerState.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(theme.dotActive)
            }
            .buttonStyle(.plain)

            Button {
                viewModel.skipForward()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(theme.textPrimary)
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note.list")
                .font(.system(size: 24))
                .foregroundStyle(theme.textSecondary)
            Text("No music loaded")
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    // MARK: - Helpers

    private func progressWidth(total: CGFloat) -> CGFloat {
        guard viewModel.currentDuration > 0 else { return 0 }
        return total * (viewModel.currentTime / viewModel.currentDuration)
    }

    private func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let mins = Int(time) / 60
        let secs = Int(time) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
