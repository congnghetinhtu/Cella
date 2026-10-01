import SwiftUI

/// Cella Orquesta — half-circle stage in the Config tab.
///
/// The stage doubles as an orchestra: the ten performer seats along the arc
/// are the ten EQ bands (31 Hz → 16 kHz), shown locked per preset.
/// Each curated preset bundles a theme (stage lighting), an EQ curve (seats)
/// and a surround staging — one tap is a full audio mood.
struct OrquestaView: View {
    var viewModel: PlayerViewModel
    @Environment(\.theme) private var theme

    @AppStorage("themeOverride") private var themeOverride: String = "seafoam"
    @AppStorage("surroundMode") private var surroundMode: String = SurroundMode.off.rawValue
    @AppStorage("orquestaPresetID") private var presetID: String = OrquestaPreset.storageKeyEmpty

    /// Luz is locked at brightest — no adjustment.
    /// Pulses subtly via the breathing animation.
    private var glowIntensity: Double {
        1.8 + sin(animPhase * 0.7) * 0.15
    }

    private let cardRadius: CGFloat = 18
    private let cardPadding: CGFloat = 40

    @State private var hoveredSeat: Int?
    @State private var animPhase: Double = 0
    @State private var burstTimer: Timer?
    @State private var pressedPreset: String?
    @State private var stageFlash: Double = 0

    private let bandLift: CGFloat = 0.45
    private let maxGain: Float = 6
    private let minGain: Float = -6

    private var frequencies: [Float] { OrquestaPreset.eqFrequencies }

    private var currentGains: [Float] {
        viewModel.currentPreset.eqBands.map { $0.gain }
    }

    private var cardBorder: some ShapeStyle {
        theme.textSecondary.opacity(0.10)
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            stage
                .frame(minHeight: 260)
                .animation(.smooth, value: viewModel.currentPreset)
                .onTapGesture { } // absorb tap-through on empty stage space

            presetRow

            Divider().background(cardBorder)

            surroundRow
        }
        .padding(cardPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .aeroCard(radius: cardRadius, wash: 0.08)
        .clipShape(RoundedRectangle(cornerRadius: cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cardRadius)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        )
        .onAppear {
            syncStoredSurround()
            syncStoredPreset()
            startBreathing()
        }
        .onChange(of: surroundMode) { _, _ in
            triggerBurst()
        }
        .onChange(of: viewModel.currentPreset.id) { _, _ in
            triggerBurst()
            withAnimation(.easeOut(duration: 0.6)) {
                stageFlash = 1.0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                withAnimation(.easeIn(duration: 0.4)) {
                    stageFlash = 0
                }
            }
        }
        .onDisappear {
            stopBreathing()
        }
    }

    // MARK: - Breathing Animation

    private func startBreathing() {
        stopBreathing()
        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
            withAnimation(.linear(duration: 1.0 / 30.0)) {
                animPhase += 0.065
            }
        }
    }

    private func stopBreathing() {
        animTimer?.invalidate()
        animTimer = nil
    }

    /// Fast burst on mode switch — runs at 3× speed for 0.8s, then settles.
    private func triggerBurst() {
        burstTimer?.invalidate()
        var elapsed = 0.0
        burstTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { timer in
            elapsed += 1.0 / 60.0
            withAnimation(.linear(duration: 1.0 / 60.0)) {
                animPhase += 0.195  // 3× normal speed
            }
            if elapsed >= 0.8 {
                timer.invalidate()
            }
        }
    }

    @State private var animTimer: Timer?

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "music.quarternote.3")
                .font(.system(size: 13))
                .foregroundStyle(theme.dotActive)
            Text("Cella Orquesta")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            Text("TUNED BY CELLA")
                .font(.system(size: 8, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(theme.dotActive)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(theme.dotActive.opacity(0.12)))
                .overlay(Capsule().stroke(theme.dotActive.opacity(0.35), lineWidth: 0.5))
            Spacer()
            HStack(spacing: 10) {
                Text(viewModel.currentPreset.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.dotActive)
                    .contentTransition(.numericText())
            }
        }
    }

    // MARK: - Stage

    private var stage: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let cx = w / 2
            let baseY = h - 22
            let arcR = min(w * 0.44, h * 0.62)
            let lift = arcR * bandLift

            ZStack {
                stageFloor(cx: cx, baseY: baseY, arcR: arcR)
                    .shadow(color: theme.haloPrimary.opacity(0.18 * glowIntensity), radius: 22 * glowIntensity)

                arcLine(baseline: arcR, padded: false, cx: cx, baseY: baseY, lift: lift, arcR: arcR)

                glowVeil(cx: cx, baseY: baseY, arcR: arcR, lift: lift)

                // Performer seats — the EQ bands.
                ForEach(frequencies.indices, id: \.self) { i in
                    let angle = seatAngle(i)
                    let gain = currentGains[safe: i] ?? 0
                    let pos = seatPosition(index: i, angle: angle, gain: gain, cx: cx, baseY: baseY, arcR: arcR, lift: lift)
                    let basePoint = CGPoint(
                        x: cx + arcR * cos(angle),
                        y: baseY - arcR * sin(angle)
                    )
                    seatStem(from: basePoint, to: pos, gain: gain, index: i)
                    seat(
                        index: i,
                        angle: angle,
                        position: pos,
                        gain: gain
                    )
                    frequencyLabel(i, angle: angle, from: basePoint)
                }

                resetSeat(cx: cx, baseY: baseY, arcR: arcR, lift: lift)

                podium(cx: cx, baseY: baseY)
            }
            .frame(width: w, height: h)
            .contentShape(Rectangle())
        }
    }

    private func seatAngle(_ i: Int) -> Double {
        let n = frequencies.count
        guard n > 1 else { return Double.pi / 2 }
        return Double.pi - Double.pi * Double(i) / Double(n - 1)
    }

    private func seatPosition(index: Int, angle: Double, gain: Float, cx: CGFloat, baseY: CGFloat, arcR: CGFloat, lift: CGFloat) -> CGPoint {
        let norm = CGFloat((clampGain(gain) + maxGain) / (maxGain - minGain))
        let radius = arcR + lift * norm
        return CGPoint(
            x: cx + radius * CGFloat(cos(angle)),
            y: baseY - radius * CGFloat(sin(angle))
        )
    }

    private func clampGain(_ gain: Float) -> Float {
        min(maxGain, max(minGain, gain))
    }

    private func arcLine(baseline: CGFloat, padded: Bool, cx: CGFloat, baseY: CGFloat, lift: CGFloat, arcR: CGFloat) -> some View {
        let radius = baseline + (padded ? lift : 0)
        return Path { path in
            path.addArc(center: CGPoint(x: cx, y: baseY), radius: radius, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        }
        .stroke(
            theme.textSecondary.opacity(padded ? 0.12 : 0.30),
            style: StrokeStyle(lineWidth: padded ? 1 : 1.5, dash: padded ? [3, 6] : [])
        )
    }

    private func baselineArc(cx: CGFloat, baseY: CGFloat, arcR: CGFloat) -> Path {
        Path { path in
            path.addArc(center: CGPoint(x: cx, y: baseY), radius: arcR, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        }
    }

    private func stageFloor(cx: CGFloat, baseY: CGFloat, arcR: CGFloat) -> some View {
        let t = animPhase * 0.3
        let c1 = theme.haloPrimary.opacity(0.28 * glowIntensity)
        let c2 = theme.haloSecondary.opacity(0.12 * glowIntensity)

        let arcPath = Path { path in
            path.move(to: CGPoint(x: cx - arcR, y: baseY))
            path.addQuadCurve(
                to: CGPoint(x: cx + arcR, y: baseY),
                control: CGPoint(x: cx, y: baseY - arcR * 0.95)
            )
        }

        // Pulsing glow — breathes between dim and bright.
        let pulse = 0.35 + 0.3 * (0.5 + 0.5 * sin(animPhase * 1.5))

        return ZStack {
            // Base floor fill.
            Path { path in
                path.move(to: CGPoint(x: cx - arcR, y: baseY))
                path.addQuadCurve(
                    to: CGPoint(x: cx + arcR, y: baseY),
                    control: CGPoint(x: cx, y: baseY - arcR * 0.95)
                )
                path.addLine(to: CGPoint(x: cx - arcR, y: baseY))
                path.closeSubpath()
            }
            .fill(
                RadialGradient(
                    colors: [c1, c2, theme.screenBackground.opacity(0)],
                    center: UnitPoint(x: 0.5 + sin(t) * 0.1, y: 0.7 + cos(t * 0.7) * 0.05),
                    startRadius: 0,
                    endRadius: arcR * 1.6
                )
            )

            // Pulsing glow border on the arc — hidden for Natural preset.
            if viewModel.currentPreset.id != OrquestaPreset.natural.id {
                arcPath
                    .stroke(Color.white.opacity(pulse), lineWidth: 2)
                    .shadow(color: .white.opacity(pulse * 0.7), radius: 6)
                    .shadow(color: .white.opacity(pulse * 0.35), radius: 12)
            }
        }
    }

    private func glowVeil(cx: CGFloat, baseY: CGFloat, arcR: CGFloat, lift: CGFloat) -> some View {
        let twinkle = glowIntensity
        let arc = baselineArc(cx: cx, baseY: baseY, arcR: arcR)
        return ZStack {
            arc.stroke(
                LinearGradient(
                    colors: [
                        theme.haloWarm.opacity(0.8),
                        theme.haloPrimary.opacity(0.9),
                        theme.haloSecondary.opacity(0.9),
                        theme.haloAccent.opacity(0.8)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                style: StrokeStyle(lineWidth: 4)
            )
            .blur(radius: 8 * twinkle)
            .opacity(0.55 * twinkle)

            arc.stroke(Color.white.opacity(0.25 * twinkle), lineWidth: 1)
        }
    }

    private func seatStem(from base: CGPoint, to pos: CGPoint, gain: Float, index: Int) -> some View {
        let boosted = gain > 0
        let dim = hoveredSeat == index
        return Path { p in
            p.move(to: base)
            p.addLine(to: pos)
        }
        .stroke(
            (boosted ? theme.dotActive : theme.textSecondary).opacity(dim ? 0.9 : 0.35),
            style: StrokeStyle(lineWidth: 2, dash: boosted ? [] : [2, 4])
        )
    }

    @ViewBuilder
    private func seat(index: Int, angle: Double, position: CGPoint, gain: Float) -> some View {
        // Locked display seat: hover readout only, no drag, no solo.
        let isHover = hoveredSeat == index
        let size: CGFloat = isHover ? 13 : 10
        let boosted = gain > 0

        Circle()
            .fill(
                RadialGradient(
                    colors: boosted
                        ? [Color.white, theme.dotActive.opacity(0.95)]
                        : [theme.textPrimary.opacity(0.7), theme.textSecondary.opacity(0.5)],
                    center: .center,
                    startRadius: 0,
                    endRadius: size
                )
            )
            .frame(width: size, height: size)
            .overlay(
                Circle()
                    .stroke(
                        isHover ? theme.dotActive : Color.clear,
                        lineWidth: 1
                    )
            )
            .shadow(
                color: (isHover ? theme.haloPrimary : theme.dotActive).opacity(0.8 * glowIntensity),
                radius: 6
            )
            .position(position)
            .onHover { hovering in
                withAnimation(.snappy(duration: 0.12)) {
                    hoveredSeat = hovering ? index : nil
                }
            }
            .overlay(
                Group {
                    if isHover {
                        Text("\(gainLabel(gain)) dB")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(theme.textPrimary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(theme.tabBarBackground))
                            .overlay(Capsule().stroke(cardBorder, lineWidth: 1))
                            .offset(y: -16)
                            .transition(.opacity)
                    }
                },
                alignment: .center
            )
    }

    private func frequencyLabel(_ i: Int, angle: Double, from base: CGPoint) -> some View {
        Text(frequencies[i].shortLabel)
            .font(.system(size: 8, weight: .medium, design: .monospaced))
            .foregroundStyle(hoveredSeat == i ? theme.textPrimary : theme.textSecondary.opacity(0.6))
            .offset(y: 14)
            .position(x: base.x, y: base.y)
    }

    private func resetSeat(cx: CGFloat, baseY: CGFloat, arcR: CGFloat, lift: CGFloat) -> some View {
        let pos = CGPoint(x: cx - arcR - lift * 0.9, y: baseY)
        return Circle()
            .stroke(
                theme.textSecondary.opacity(0.4),
                style: StrokeStyle(lineWidth: 1.5, dash: [2, 4])
            )
            .frame(width: 18, height: 18)
            .overlay(
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.textSecondary)
            )
            .position(pos)
            .help("Reset everything (curve, surround, lighting)")
            .onTapGesture { resetAll() }
    }

    private func podium(cx: CGFloat, baseY: CGFloat) -> some View {
        let mode = currentSurround
        let isActive = mode != .off
        let t = animPhase

        // Pulse ring — expands and fades when surround is active.
        let pulseScale: CGFloat = isActive ? 1.0 + sin(t * 2.0) * 0.15 : 1.0
        let pulseOpacity: Double = isActive ? 0.3 + sin(t * 2.0) * 0.15 : 0

        return VStack(spacing: 3) {
            Image(systemName: mode.iconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .rotationEffect(.degrees(isActive ? sin(t * 0.8) * 8 : 0))
            Text(mode.displayName)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
        }
        .frame(width: 46, height: 46)
        .background(
            ZStack {
                // Pulse ring.
                Circle()
                    .stroke(theme.dotActive, lineWidth: 1)
                    .scaleEffect(pulseScale)
                    .opacity(pulseOpacity)

                Circle().fill(theme.dotActive.opacity(0.25))

                // Rotating angular gradient border.
                Circle().stroke(
                    AngularGradient(
                        colors: [
                            theme.haloPrimary,
                            theme.haloSecondary,
                            theme.haloAccent,
                            theme.haloWarm,
                            theme.haloPrimary
                        ],
                        center: .center,
                        angle: .degrees(isActive ? t * 40 : 0)
                    ),
                    lineWidth: 1.5
                )

                if isActive {
                    Circle()
                        .fill(theme.dotActive.opacity(0.35))
                        .frame(width: 52, height: 52)
                        .blur(radius: 10)
                        .scaleEffect(1.0 + sin(t * 1.5) * 0.08)
                }
            }
        )
        .position(x: cx, y: baseY + 10)
    }

    // MARK: - Presets

    private var allPresets: [OrquestaPreset] {
        OrquestaPreset.factoryPresets
    }

    private var presetRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(allPresets, id: \.id) { preset in
                    presetChip(preset)
                }
            }
        }
    }

    private func presetChip(_ preset: OrquestaPreset) -> some View {
        let isSelected = preset.id == viewModel.currentPreset.id
        return Button {
            applyPreset(preset)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: preset.iconName)
                    .font(.system(size: 11))
                Text(preset.displayName)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
            }
            .foregroundStyle(isSelected ? .white : theme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(isSelected ? preset.accentColor.opacity(0.85) : theme.dotInactive.opacity(0.25))
            )
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(.ultraThinMaterial.opacity(isSelected ? 0.35 : 0.0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(isSelected ? 0.28 : 0.10), .white.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                    .allowsHitTesting(false)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(isSelected ? .white.opacity(0.35) : .white.opacity(0.10), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Surround

    private var currentSurround: SurroundMode {
        SurroundMode(rawValue: surroundMode) ?? .off
    }

    private var surroundRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            rowLabel(icon: "dot.radiowaves.left.and.right", title: "Surround", accent: theme.haloAccent)

            HStack(spacing: 8) {
                ForEach(SurroundMode.allCases, id: \.self) { mode in
                    let isSelected = mode == currentSurround
                    Button {
                        withAnimation(.snappy) {
                            surroundMode = mode.rawValue
                            viewModel.applySurround(mode)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: mode.iconName)
                                .font(.system(size: 12))
                            Text(mode.displayName)
                                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        }
                        .foregroundStyle(isSelected ? .white : theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(isSelected ? theme.dotActive.opacity(0.85) : theme.dotInactive.opacity(0.22))
                        )
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(.ultraThinMaterial.opacity(isSelected ? 0.35 : 0.0))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(
                                    LinearGradient(
                                        colors: [.white.opacity(isSelected ? 0.28 : 0.10), .white.opacity(0.02)],
                                        startPoint: .top,
                                        endPoint: .center
                                    )
                                )
                                .allowsHitTesting(false)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(isSelected ? .white.opacity(0.35) : .white.opacity(0.10), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Row label helper

    private func rowLabel(icon: String, title: String, accent: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(accent)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
        }
    }

    // MARK: - Actions

    private func applyPreset(_ preset: OrquestaPreset) {
        withAnimation(.smooth) {
            viewModel.setSoloBand(nil)
            presetID = preset.id
            viewModel.selectPreset(preset)
            themeOverride = preset.themeID
            surroundMode = preset.surround.rawValue
            viewModel.applySurround(preset.surround)
        }
    }

    private func resetAll() {
        withAnimation(.smooth) {
            OrquestaPreset.resetCustomGains()
            applyPreset(.natural)
        }
    }

    private func syncStoredSurround() {
        if let mode = SurroundMode(rawValue: surroundMode), mode != viewModel.surroundMode {
            viewModel.applySurround(mode)
        }
    }

    private func syncStoredPreset() {
        let target = OrquestaPreset.resolve(presetID == OrquestaPreset.storageKeyEmpty ? nil : presetID)
        guard target.id != viewModel.currentPreset.id else { return }
        withAnimation(.smooth) {
            viewModel.selectPreset(target)
        }
    }

    private func gainLabel(_ gain: Float) -> String {
        String(format: "%+.1f", gain)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension Float {
    var shortLabel: String {
        let v = self
        if v >= 1000 { return String(format: "%.0fK", v / 1000) }
        return String(format: "%.0f", v)
    }
}

#Preview {
    OrquestaView(viewModel: PlayerViewModel())
        .environment(\.theme, .seafoam)
        .padding(40)
        .frame(width: 560)
}