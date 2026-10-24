//
//  IOSNowPlayingBar.swift
//  CellaIOS
//
//  The bottom controls: the transport icons sit above the progress bar, with
//  the playing pill — a soft glass card with the small cover, title and
//  artist — underneath. Tapping the pill flips the screen between the blue
//  glass look and the white day look.
//

import SwiftUI

/// The three transport icons, plain and unstyled, like the system player.
struct IOSTransportRow: View {
    let isPlaying: Bool
    let canPlay: Bool
    var accent: AnyShapeStyle
    var onPlayPause: () -> Void
    var onPrev: () -> Void
    var onNext: () -> Void

    var body: some View {
        HStack(spacing: 34) {
            icon("backward.fill", size: 21, action: onPrev)
            icon(isPlaying ? "pause.fill" : "play.fill", size: 27, action: onPlayPause)
            icon("forward.fill", size: 21, action: onNext)
        }
        .frame(maxWidth: .infinity)
    }

    private func icon(_ name: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(accent)
                .frame(width: 46, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canPlay)
        .opacity(canPlay ? 1 : 0.35)
        .animation(.snappy, value: isPlaying)
    }
}

/// The playing pill: soft glass card, small cover, title and artist. A tap
/// toggles the white flip (handled by the screen).
struct IOSNowPlayingRow: View {
    let artwork: UIImage?
    let title: String
    let subtitle: String

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 11) {
            artworkThumb

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(theme.textPrimary.opacity(0.05))
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var artworkThumb: some View {
        ZStack {
            if let artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [theme.dotActive.opacity(0.5), theme.dotInactiveDeep],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "music.note")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(width: 42, height: 42)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.textPrimary.opacity(0.20), lineWidth: 1)
        )
    }
}
