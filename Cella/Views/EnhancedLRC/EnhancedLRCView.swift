import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

struct EnhancedLRCView: View {
    @StateObject private var viewModel = EnhancedLRCViewModel()
    @Environment(\.theme) private var theme
    @State private var keyMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            Divider().background(theme.textSecondary.opacity(0.2))

            if viewModel.currentTrackURL != nil {
                playbackControls
                Divider().background(theme.textSecondary.opacity(0.2))
            }

            if !viewModel.metadata.isEmpty && viewModel.currentTrackURL != nil {
                metadataBar
                Divider().background(theme.textSecondary.opacity(0.2))
            }

            if viewModel.lines.isEmpty && viewModel.currentTrackURL == nil {
                emptyState
            } else if viewModel.lines.isEmpty {
                noLyricsState
            } else {
                linesList
            }

            bottomBar
        }
        .background(theme.appBackground)
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak viewModel] event in
                guard let viewModel, viewModel.currentTrackURL != nil else { return event }
                if event.keyCode == 15 { // "R" — toggle recording
                    viewModel.toggleRecording()
                    return nil
                }
                if viewModel.isRecording, event.keyCode == 46 { // "M" — mark line at current time
                    viewModel.recordLine()
                    return nil
                }
                return event
            }
        }
        .onDisappear {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
            }
            keyMonitor = nil
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Button {
                openFilePicker()
            } label: {
                Label("Open Audio", systemImage: "doc.badge.plus")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)

            if !viewModel.trackName.isEmpty {
                Text(viewModel.trackName)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                viewModel.toggleRecording()
            } label: {
                Label(
                    viewModel.isRecording ? "Recording — M to mark (R to stop)" : "Record LRC (R)",
                    systemImage: viewModel.isRecording ? "record.circle.fill" : "record.circle"
                )
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(viewModel.isRecording ? .red : theme.textPrimary)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.currentTrackURL == nil)

            Button {
                viewModel.saveLrc()
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
            .disabled(viewModel.currentTrackURL == nil)

            Button {
                _ = viewModel.exportLrc()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Playback Controls

    private var playbackControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                Button {
                    viewModel.seek(to: max(0, viewModel.currentTime - 5))
                } label: {
                    Image(systemName: "gobackward.5")
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)

                Button {
                    viewModel.togglePlayback()
                } label: {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 24))
                }
                .buttonStyle(.plain)

                Button {
                    viewModel.seek(to: min(audioDuration, viewModel.currentTime + 5))
                } label: {
                    Image(systemName: "goforward.5")
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
            }

            HStack {
                Text(formatTime(viewModel.currentTime))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)

                Slider(
                    value: Binding(
                        get: { viewModel.currentTime },
                        set: { viewModel.seek(to: $0) }
                    ),
                    in: 0...max(audioDuration, 1)
                )

                Text(formatTime(audioDuration))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
            }

            HStack(spacing: 4) {
                Text("Speed")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.textSecondary)

                ForEach([Float(0.25), 0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                    Button {
                        viewModel.setSpeed(speed)
                    } label: {
                        Text(speed == 1.0 ? "1x" : String(format: "%.2gx", speed))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(viewModel.playbackSpeed == speed ? .white : theme.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                viewModel.playbackSpeed == speed
                                    ? theme.dotActive
                                    : theme.textSecondary.opacity(0.1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Metadata Bar

    private var metadataBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                if !viewModel.metadata.title.isEmpty {
                    metaTag(icon: "music.note", label: viewModel.metadata.title)
                }
                if !viewModel.metadata.artist.isEmpty {
                    metaTag(icon: "person.fill", label: viewModel.metadata.artist)
                }
                if !viewModel.metadata.album.isEmpty {
                    metaTag(icon: "square.stack", label: viewModel.metadata.album)
                }
                if !viewModel.metadata.author.isEmpty {
                    metaTag(icon: "pencil", label: viewModel.metadata.author)
                }
                if !viewModel.metadata.length.isEmpty {
                    metaTag(icon: "clock", label: viewModel.metadata.length)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    private func metaTag(icon: String, label: String) -> some View {
        Label(label, systemImage: icon)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(theme.textSecondary.opacity(0.1))
            .clipShape(Capsule())
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "doc.text")
                .font(.system(size: 48))
                .foregroundStyle(theme.textSecondary)
            Text("Enhanced LRC Editor")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            Text("Open an audio file to start editing lyrics")
                .font(.system(size: 13))
                .foregroundStyle(theme.textSecondary)
            Button {
                openFilePicker()
            } label: {
                Label("Open Audio", systemImage: "doc.badge.plus")
                    .font(.system(size: 14, weight: .medium))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(theme.tabSelectedBackground)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }

    // MARK: - No Lyrics State

    private var noLyricsState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "text.badge.plus")
                .font(.system(size: 48))
                .foregroundStyle(theme.textSecondary)
            Text("No Lyrics Found")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            Text("No .lrc file found for this track.\nTap 'Add Line' to create lyrics from scratch.")
                .font(.system(size: 13))
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
    }

    // MARK: - Lines List

    private var linesList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(Array(viewModel.lines.enumerated()), id: \.element.id) { index, line in
                    LrcLineRow(
                        line: line,
                        index: index,
                        isCurrent: index == viewModel.currentLineIndex,
                        isRecordingTarget: viewModel.isRecording && index == viewModel.recordingCursorIndex,
                        onTimestampTap: {
                            viewModel.setTimestampForLine(at: index)
                        },
                        onTextChange: { text in
                            viewModel.updateLineText(at: index, text: text)
                        },
                        onDelete: {
                            viewModel.removeLine(at: index)
                        }
                    )
                    .id(line.id)
                }
                .onMove { source, destination in
                    viewModel.moveLine(from: source, to: destination)
                }
            }
            .listStyle(.plain)
            .onChange(of: viewModel.currentLineIndex) { _, newIndex in
                if newIndex >= 0, newIndex < viewModel.lines.count {
                    withAnimation {
                        proxy.scrollTo(viewModel.lines[newIndex].id, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            Button {
                viewModel.addLine()
            } label: {
                Label("Add Line", systemImage: "plus")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                viewModel.undo()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canUndo)

            Text("\(viewModel.lineCount) lines")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(theme.appBackground)
    }

    // MARK: - Helpers

    private var audioDuration: TimeInterval {
        guard let url = viewModel.currentTrackURL,
              let player = try? AVAudioPlayer(contentsOf: url) else { return 0 }
        return player.duration
    }

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.mp3, .wav, .aiff]
            + ["flac", "m4a", "caf", "ogg", "aac"].compactMap { UTType(filenameExtension: $0) }
        panel.prompt = "Open Audio File"
        panel.message = "Select an audio file to edit lyrics"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        print("[EnhancedLRC] Selected audio URL: \(url)")
        print("[EnhancedLRC] Path: \(url.path)")
        print("[EnhancedLRC] Deleting last path: \(url.deletingLastPathComponent().path)")

        Task {
            await viewModel.loadAudio(from: url)
            print("[EnhancedLRC] After load - trackName: \(viewModel.trackName), lines: \(viewModel.lines.count)")
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Line Row

struct LrcLineRow: View {
    let line: EditableLrcLine
    let index: Int
    let isCurrent: Bool
    let isRecordingTarget: Bool
    let onTimestampTap: () -> Void
    let onTextChange: (String) -> Void
    let onDelete: () -> Void

    @Environment(\.theme) private var theme
    @State private var editText: String = ""
    @State private var isEditing = false

    var body: some View {
        HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 24, alignment: .trailing)

            Button {
                onTimestampTap()
            } label: {
                Text(line.timestampString)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(isRecordingTarget || isCurrent ? .white : theme.dotActive)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        isRecordingTarget
                            ? Color.red.opacity(0.5)
                            : isCurrent
                                ? theme.dotActive.opacity(0.3)
                                : theme.textSecondary.opacity(0.1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)

            if isEditing {
                TextField("Lyrics", text: $editText)
                    .font(.system(size: 14))
                    .onSubmit {
                        onTextChange(editText)
                        isEditing = false
                    }
                    .onExitCommand {
                        isEditing = false
                    }
            } else {
                Text(line.text.isEmpty ? "—" : line.text)
                    .font(.system(size: 14))
                    .foregroundStyle(line.text.isEmpty ? theme.textSecondary : theme.textPrimary)
                    .lineLimit(1)
                    .onTapGesture(count: 2) {
                        editText = line.text
                        isEditing = true
                    }
            }

            Spacer()

            if isCurrent {
                Circle()
                    .fill(theme.dotActive)
                    .frame(width: 6, height: 6)
            }

            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
        .listRowBackground(
            isCurrent
                ? theme.dotActive.opacity(0.08)
                : Color.clear
        )
    }
}

#Preview {
    EnhancedLRCView()
}
