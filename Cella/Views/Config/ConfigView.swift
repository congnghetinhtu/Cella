import SwiftUI
import AppKit

struct ConfigView: View {
    var viewModel: PlayerViewModel
    @Environment(\.theme) private var theme
    @AppStorage("themeOverride") private var themeOverride: String = "seafoam"

    @State private var guidePage: Int? = 0

    private let cardRadius: CGFloat = CardStyle.radius
    private let cardPadding: CGFloat = 40
    private let gridSpacing: CGFloat = 28

    private var cardBorder: some ShapeStyle {
        theme.textSecondary.opacity(CardStyle.borderOpacity)
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: gridSpacing) {
                orquestaCard
                    .frame(minHeight: 420)

                // Bento row: Guide + About equal split, equal height
                HStack(alignment: .top, spacing: gridSpacing) {
                    quickGuideCard
                        .frame(maxWidth: .infinity)
                        .frame(height: 300, alignment: .top)
                    aboutCard
                        .frame(maxWidth: .infinity)
                        .frame(height: 300, alignment: .top)
                }

                if let error = viewModel.importError {
                    errorCard(error)
                        .transition(.move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.97)))
                }
            }
            .padding(.horizontal, 96)
            .padding(.vertical, 64)
            .frame(maxWidth: .infinity)
            .animation(.smooth, value: viewModel.hasTracks)
            .animation(.smooth, value: viewModel.importError)
        }
    }

    // MARK: - Orquesta Card

    private var orquestaCard: some View {
        OrquestaView(viewModel: viewModel)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Quick Guide Card (paging carousel)

    private var quickGuideCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "lightbulb")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.haloWarm)
                Text("Quick Guide")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Text("Swipe")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(theme.dotInactive.opacity(0.25)))
            }
            .padding(.horizontal, cardPadding)
            .padding(.top, cardPadding)
            .padding(.bottom, 12)

            guideCarousel
        }
        .padding(.bottom, cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.screenBackground)
        .clipShape(RoundedRectangle(cornerRadius: cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cardRadius)
                .stroke(cardBorder, lineWidth: 1)
        )
    }

    private var guideCarousel: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                guideSlide(
                    icon: "folder.fill",
                    step: 1,
                    title: "Import a Library",
                    text: "Play any .cella playlist from Cluster. The mood engine takes over.",
                    tint: theme.dotActive
                )
                .containerRelativeFrame(.horizontal)
                .id(0)

                guideSlide(
                    icon: "waveform",
                    step: 2,
                    title: "Pick a Preset",
                    text: "Natural, Cálido, Océano, Aurora — one tap sets the whole mood.",
                    tint: theme.haloPrimary
                )
                .containerRelativeFrame(.horizontal)
                .id(1)

                guideSlide(
                    icon: "slider.horizontal.3",
                    step: 3,
                    title: "Shape the Curve",
                    text: "Drag the ten seats to boost or cut each band. Your curve turns Custom.",
                    tint: theme.haloSecondary
                )
                .containerRelativeFrame(.horizontal)
                .id(2)

                guideSlide(
                    icon: "dot.radiowaves.left.and.right",
                    step: 4,
                    title: "Stage the Sound",
                    text: "Ampliado widens. Teatro widens and warms the low end.",
                    tint: theme.haloAccent
                )
                .containerRelativeFrame(.horizontal)
                .id(3)
            }
            .scrollTargetLayout()
        }
        .scrollPosition(id: $guidePage, anchor: .center)
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: 190)
        .overlay(alignment: .bottom) {
            HStack(spacing: 6) {
                ForEach(0..<4, id: \.self) { index in
                    Capsule()
                        .fill(index == guidePage ? theme.dotActive : theme.textSecondary.opacity(0.25))
                        .frame(width: index == guidePage ? 18 : 6, height: 6)
                        .animation(.snappy, value: guidePage)
                        .contentShape(Capsule())
                        .onTapGesture {
                            withAnimation(.snappy) { guidePage = index }
                        }
                }
            }
            .padding(.bottom, 8)
        }
    }

    private func guideSlide(icon: String, step: Int, title: String, text: String, tint: Color) -> some View {
        HStack(spacing: 20) {
            RoundedRectangle(cornerRadius: 16)
                .fill(tint.opacity(0.15))
                .frame(width: 64, height: 64)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(tint)
                )

            VStack(alignment: .leading, spacing: 6) {
                Text("\(step) of 4")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2, reservesSpace: true)
            }
        }
        .padding(.horizontal, cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // MARK: - About Card

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        LinearGradient(
                            colors: [theme.haloPrimary, theme.haloSecondary],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 44, height: 44)
                    .overlay(
                        Image(systemName: "waveform")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                    )
                    .shadow(color: theme.haloPrimary.opacity(0.35), radius: 6, y: 2)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Cella")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.textPrimary)
                    Text("Music player")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                }

                Spacer(minLength: 8)

                Text("v1.0")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(theme.dotInactive.opacity(0.25)))
            }
            .padding(.top, cardPadding)
            .padding(.bottom, 14)

            aboutGroup {
                aboutRow(icon: "shippingbox.fill", label: "Version", value: "Cella 1.0")
                aboutRow(icon: "waveform.path", label: "Engine", value: "Real-Time")
                aboutRow(icon: "doc.text", label: "License", value: "MIT")
            }

            Spacer(minLength: 10)
                .frame(height: 10)

            aboutGroup {
                aboutRow(icon: "person.fill", label: "Developer", value: "Thanh Solar NEXT")
                aboutRow(icon: "building.2.fill", label: "Publisher", value: "Tic")
            }

            Spacer(minLength: 0)

            Text("Built with Swift and SwiftUI.")
                .font(.system(size: 10))
                .foregroundStyle(theme.textSecondary.opacity(0.6))
                .lineLimit(1)
                .fixedSize()
                .padding(.top, 8)
        }
        .padding(.bottom, cardPadding)
        .padding(.horizontal, cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.screenBackground)
        .clipShape(RoundedRectangle(cornerRadius: cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cardRadius)
                .stroke(cardBorder, lineWidth: 1)
        )
    }

    private func aboutGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.textSecondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(cardBorder, lineWidth: 1)
        )
    }

    private func aboutRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(theme.dotActive)
                .frame(width: 16)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textSecondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
    }

    // MARK: - Error Card

    private func errorCard(_ error: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.red)
            Text(error)
                .font(.system(size: 12))
                .foregroundStyle(.red)
                .lineLimit(3)
        }
        .padding(cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.screenBackground)
        .clipShape(RoundedRectangle(cornerRadius: cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cardRadius)
                .stroke(cardBorder, lineWidth: 1)
        )
    }
}