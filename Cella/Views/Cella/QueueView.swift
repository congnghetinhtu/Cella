import SwiftUI
import UniformTypeIdentifiers

struct QueueView: View {
    let viewModel: PlayerViewModel
    @Environment(\.theme) private var theme
    @State private var draggedIndex: Int?
    @State private var dropTargetIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().background(theme.textSecondary.opacity(0.15))

            if let queue = viewModel.mixQueue {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(queue.tracks.enumerated()), id: \.element.id) { index, track in
                            trackRow(track: track, index: index, isPlaying: index == queue.currentIndex)
                                .opacity(draggedIndex == index ? 0.4 : 1)
                                .scaleEffect(draggedIndex == index ? 0.97 : 1)
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
                                    viewModel.requestAlbumPillDelayedReveal()
                                    viewModel.jumpToTrack(at: index)
                                }
                        }
                    }
                    .padding(.horizontal, 8)
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
        .background(theme.screenBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(theme.textSecondary.opacity(0.1), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func trackRow(track: TrackAsset, index: Int, isPlaying: Bool) -> some View {
        HStack(spacing: 10) {
            if isPlaying {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.dotActive)
            } else {
                Text("\(index + 1)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 18)
            }

            Text(track.fileName)
                .font(.system(size: 12))
                .foregroundStyle(isPlaying ? theme.textPrimary : theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            Button {
                viewModel.removeTrack(at: index)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(theme.dotActive)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isPlaying ? theme.dotActive.opacity(0.08) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(dropTargetIndex == index ? theme.dotActive.opacity(0.4) : Color.clear, lineWidth: 1)
                )
        )
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
        withAnimation(.snappy) {
            dropTargetIndex = destinationIndex
        }
    }

    func dropExited(info: DropInfo) {
        withAnimation(.snappy) {
            dropTargetIndex = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
