import SwiftUI
import UniformTypeIdentifiers

struct QueueView: View {
    let viewModel: PlayerViewModel
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draggedIndex: Int?
    @State private var dropTargetIndex: Int?
    @State private var tappedIndex: Int?

    private let rowHPadding: CGFloat = 10
    private let listHPadding: CGFloat = 10
    private let rowHeight: CGFloat = 28
    private let joySpring: Animation = .spring(response: 0.35, dampingFraction: 0.65)
    private let popSpring: Animation = .spring(response: 0.25, dampingFraction: 0.55)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(theme.textSecondary.opacity(0.15))
            content
        }
        .background(theme.screenBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(theme.textSecondary.opacity(0.1), lineWidth: 1)
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "list.bullet")
                .font(.system(size: 12))
                .foregroundStyle(theme.dotActive)
            Text("Queue")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            Spacer()
            Text("\(viewModel.playlistCount)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.textSecondary)
        }
        .padding(.horizontal, listHPadding)
        .padding(.vertical, 10)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let queue = viewModel.mixQueue {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(queue.tracks.enumerated()), id: \.element.id) { index, track in
                        trackRow(track: track, index: index, isPlaying: index == queue.currentIndex)
                            .opacity(draggedIndex == index ? 0.4 : 1)
                            .scaleEffect(draggedIndex == index ? 0.95 : 1)
                            .offset(x: draggedIndex == index ? 8 : 0)
                            .onDrag {
                                draggedIndex = index
                                return NSItemProvider(object: "\(index)" as NSString)
                            }
                            .onDrop(of: [.text], delegate: TrackDropDelegate(
                                destinationIndex: index,
                                draggedIndex: $draggedIndex,
                                dropTargetIndex: $dropTargetIndex,
                                viewModel: viewModel
                            ))
                            .onTapGesture {
                                withAnimation(reduceMotion ? .none : popSpring) {
                                    tappedIndex = index
                                }
                                viewModel.requestAlbumPillDelayedReveal()
                                viewModel.jumpToTrack(at: index)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    withAnimation(reduceMotion ? .none : joySpring) {
                                        tappedIndex = nil
                                    }
                                }
                            }
                    }
                }
                .padding(.horizontal, listHPadding)
                .padding(.vertical, 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Spacer()
            Text("No tracks")
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary.opacity(0.5))
                .frame(maxWidth: .infinity)
            Spacer()
        }
    }

    // MARK: - Track Row

    @ViewBuilder
    private func trackRow(track: TrackAsset, index: Int, isPlaying: Bool) -> some View {
        HStack(spacing: 8) {
            if isPlaying {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.dotActive)
                    .symbolEffect(.variableColor.iterative)
                    .frame(width: 18)
            } else {
                Text("\(index + 1)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 18, alignment: .trailing)
            }

            Text(track.fileName)
                .font(.system(size: 12))
                .foregroundStyle(isPlaying ? theme.textPrimary : theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            RemoveButton {
                withAnimation(reduceMotion ? .none : joySpring) {
                    viewModel.removeTrack(at: index)
                }
            }
        }
        .frame(height: rowHeight)
        .padding(.horizontal, rowHPadding)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    tappedIndex == index
                    ? theme.dotActive.opacity(0.15)
                    : isPlaying
                        ? theme.dotActive.opacity(0.08)
                        : Color.clear
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(dropTargetIndex == index ? theme.dotActive.opacity(0.4) : Color.clear, lineWidth: 1)
                )
        )
        .animation(reduceMotion ? .none : joySpring, value: isPlaying)
        .animation(reduceMotion ? .none : popSpring, value: tappedIndex == index)
    }
}

struct TrackDropDelegate: DropDelegate {
    let destinationIndex: Int
    @Binding var draggedIndex: Int?
    @Binding var dropTargetIndex: Int?
    let viewModel: PlayerViewModel

    func performDrop(info: DropInfo) -> Bool {
        if let source = draggedIndex, source != destinationIndex {
            viewModel.moveTrack(from: IndexSet(integer: source), to: destinationIndex > source ? destinationIndex + 1 : destinationIndex)
        }
        draggedIndex = nil
        dropTargetIndex = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let dragged = draggedIndex, dragged != destinationIndex else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) {
            dropTargetIndex = destinationIndex
        }
    }

    func dropExited(info: DropInfo) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) {
            dropTargetIndex = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

// MARK: - Remove Button (joyful)

private struct RemoveButton: View {
    var action: () -> Void
    @Environment(\.theme) private var theme
    @State private var isHovering = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(isHovering ? theme.dotActive : theme.dotActive.opacity(0.6))
                .frame(width: 20, height: 20)
                .rotationEffect(.degrees(isPressed ? 90 : 0))
                .scaleEffect(isHovering ? 1.3 : 1.0)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isHovering)
        .animation(.spring(response: 0.2, dampingFraction: 0.5), value: isPressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
}
