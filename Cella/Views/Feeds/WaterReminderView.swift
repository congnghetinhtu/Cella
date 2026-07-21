//
//  WaterReminderView.swift
//  Cella
//
//  Drinking water reminder with countdown timer.
//

import SwiftUI

struct WaterReminderView: View {
    @Environment(\.theme) private var theme
    var feedsVM: FeedsViewModel

    private let cardRadius: CGFloat = 18
    private let cardPadding: CGFloat = 28
    private let intervals = [15, 30, 45, 60, 90]

    private var cardBorder: some ShapeStyle {
        theme.textSecondary.opacity(0.10)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if feedsVM.waterTimerActive {
                activeTimer
            } else {
                setupView
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
            Image(systemName: "drop.fill")
                .font(.system(size: 13))
                .foregroundStyle(theme.dotActive)
            Text("Water Reminder")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            Spacer()
        }
    }

    // MARK: - Setup View

    private var setupView: some View {
        let intervalBinding = Binding(
            get: { feedsVM.waterIntervalMinutes },
            set: { feedsVM.waterIntervalMinutes = $0 }
        )
        return VStack(spacing: 12) {
            Picker("Interval", selection: intervalBinding) {
                ForEach(intervals, id: \.self) { min in
                    Text("\(min)m").tag(min)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Button {
                feedsVM.startWaterTimer()
            } label: {
                HStack {
                    Image(systemName: "play.fill")
                    Text("Start")
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(theme.dotActive)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Active Timer

    private var activeTimer: some View {
        VStack(spacing: 12) {
            Text(formatTime(feedsVM.waterTimeRemaining))
                .font(.system(size: 32, weight: .light, design: .monospaced))
                .foregroundStyle(theme.textPrimary)

            ZStack {
                Circle()
                    .stroke(theme.dotInactive.opacity(0.3), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: timerProgress)
                    .stroke(theme.dotActive, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "drop.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(theme.dotActive)
            }
            .frame(width: 60, height: 60)

            HStack(spacing: 10) {
                Button {
                    feedsVM.drinkWater()
                } label: {
                    HStack {
                        Image(systemName: "checkmark")
                        Text("Drank")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .background(theme.dotActive)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    feedsVM.stopWaterTimer()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(theme.dotInactive.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers

    private var timerProgress: CGFloat {
        let total = TimeInterval(feedsVM.waterIntervalMinutes * 60)
        guard total > 0 else { return 0 }
        return 1.0 - (feedsVM.waterTimeRemaining / total)
    }

    private func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let mins = Int(time) / 60
        let secs = Int(time) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}
