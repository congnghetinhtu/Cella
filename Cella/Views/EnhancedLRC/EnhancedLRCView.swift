import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

struct EnhancedLRCView: View {
    @ObservedObject var viewModel: EnhancedLRCViewModel
    @Binding var pendingAudioURL: URL?
    @Binding var hasAudio: Bool
    @Environment(\.theme) private var theme
    @State private var keyMonitor: Any?
    @State private var isLoading = false
    // First-visit format guide: auto-opens once per install (clarcGuideSeen);
    // clarcGuideUp gates the R/M key monitor while the overlay is up.
    @AppStorage("clarcGuideSeen") private var clarcGuideSeen = false
    @State private var clarcGuideUp = false
    @State private var showBulkPaste = false
    @State private var bulkText = ""
    /// Inline metadata-adjustment panel below the meta bar.
    @State private var showingMetaEditor = false
    /// Last user tap/drag in the lines list — auto-follow pauses 8s after.
    @State private var lastListInteraction = Date.distantPast
    /// True while a follow-scroll is in flight (its geometry change must
    /// not count as user interaction).
    @State private var programmaticScroll = false

    private let sectionPadding = EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
    private let contentPadding: CGFloat = 12

    private var cardBorder: some ShapeStyle {
        theme.textSecondary.opacity(CardStyle.borderOpacity)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            Divider().background(cardBorder)

            if let err = viewModel.loadError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                    Text(err)
                        .font(.system(size: 11))
                        .lineLimit(2)
                }
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, CardStyle.horizontalPadding)
                .padding(.vertical, 8)
                Divider().background(cardBorder)
            }

            if viewModel.currentTrackURL != nil {
                playbackControls
                Divider().background(cardBorder)
            }

            if !viewModel.metadata.isEmpty && viewModel.currentTrackURL != nil {
                metadataBar
                if showingMetaEditor {
                    ClarcMetaEditPanel(
                        baseName: viewModel.currentTrackURL.map { $0.deletingPathExtension().lastPathComponent } ?? "",
                        initialTitle: viewModel.metadata.title,
                        initialArtists: ArtistMatcher.splitRaw(viewModel.metadata.artist),
                        initialWriter: viewModel.metadata.author,
                        initialAlbum: viewModel.metadata.album,
                        initialDuration: viewModel.metadata.length,
                        onApply: { title, artists, writer, album, duration in
                            viewModel.applyMetadataAdjustment(
                                title: title, artists: artists,
                                writer: writer, album: album, duration: duration)
                            withAnimation(.snappy) { showingMetaEditor = false }
                        },
                        onCancel: { withAnimation(.snappy) { showingMetaEditor = false } })
                    Divider().background(cardBorder)
                } else {
                    Divider().background(cardBorder)
                }
            }

            if isLoading {
                loadingState
            } else if viewModel.lines.isEmpty && viewModel.currentTrackURL == nil {
                emptyState
            } else if viewModel.lines.isEmpty {
                noLyricsState
            } else {
                linesList
            }

            bottomBar
        }
        .padding(.horizontal, CardStyle.horizontalPadding)
        .padding(.vertical, CardStyle.verticalPadding)
        // Floating launch pill docked at the editor's bottom-right, raised
        // above the tools bar; the card it opens presents full-screen.
        .overlay(alignment: .bottomTrailing) {
            ClarcGuidePill(onTap: { requestClarcGuide() })
                .padding(.trailing, 16)
                .padding(.bottom, 58)
        }
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak viewModel] event in
                guard let viewModel, viewModel.currentTrackURL != nil else { return event }
                // Format guide up at the window root — R/M waits.
                if clarcGuideUp { return event }
                // Typing in paste box / line fields — let R/M type, don't record.
                if NSApp.keyWindow?.firstResponder is NSTextView { return event }
                // Behind the bulk-paste sheet, or with Command held (menu
                // shortcuts like Cmd+R): never record.
                if showBulkPaste { return event }
                if event.modifierFlags.contains(.command) { return event }
                if event.keyCode == 15 {
                    viewModel.toggleRecording()
                    return nil
                }
                if viewModel.isRecording, event.keyCode == 46 {
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
        .onChange(of: pendingAudioURL?.path) { _, newPath in
            guard let newPath,
                  pendingAudioURL != nil else { return }
            let url = URL(fileURLWithPath: newPath)
            pendingAudioURL = nil
            Task {
                isLoading = true
                await viewModel.loadAudio(from: url)
                isLoading = false
            }
        }
        .onChange(of: viewModel.currentTrackURL) { _, url in
            hasAudio = url != nil
        }
        .onAppear {
            hasAudio = viewModel.currentTrackURL != nil
            maybeAutoShowClarcGuide()
        }
        .onReceive(NotificationCenter.default.publisher(for: .clarcGuideRequest)) { note in
            // True/false mirror: the guide overlay retires the R/M swallow
            // exactly when it is dismissed at the window root.
            clarcGuideUp = note.object as? Bool ?? false
        }
        .sheet(item: $viewModel.pendingConversion) { pending in
            ClarcConversionSheet(
                pending: pending,
                onConfirm: { title, artists, writer, album, duration in
                    viewModel.confirmClarcConversion(
                        title: title, artists: artists,
                        writer: writer, album: album, duration: duration)
                },
                onCancel: { viewModel.cancelClarcConversion() })
        }
    }

    // MARK: - Format guide (first visit + "?")

    private func maybeAutoShowClarcGuide() {
        guard !clarcGuideSeen else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard !clarcGuideSeen else { return }
            requestClarcGuide()
        }
    }

    private func requestClarcGuide() {
        clarcGuideSeen = true
        clarcGuideUp = true
        NotificationCenter.default.post(name: .clarcGuideRequest, object: true)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            Button {
                openFilePicker()
            } label: {
                Label("Open Audio", systemImage: "doc.badge.plus")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(AeroButtonStyle(prominent: true))

            if !viewModel.trackName.isEmpty {
                Text(viewModel.trackName)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            if viewModel.isRecording {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 6, height: 6)
                        .overlay(
                            Circle()
                                .fill(Color.red.opacity(0.4))
                                .frame(width: 6, height: 6)
                                .scaleEffect(2.0)
                                .opacity(0)
                                .animation(
                                    .easeOut(duration: 1.0).repeatForever(autoreverses: false),
                                    value: viewModel.isRecording
                                )
                        )
                    Text("Recording")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.red)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.red.opacity(0.1))
                .clipShape(Capsule())
            }

            Button {
                viewModel.toggleRecording()
            } label: {
                Label(
                    viewModel.isRecording ? "Stop (R)" : "Record (R)",
                    systemImage: viewModel.isRecording ? "stop.circle.fill" : "record.circle"
                )
                .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(AeroRecordButtonStyle(recording: viewModel.isRecording))
            .disabled(viewModel.currentTrackURL == nil)
            .opacity(viewModel.currentTrackURL == nil ? 0.4 : 1.0)

            Button {
                viewModel.saveLrc()
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(AeroButtonStyle())
            .disabled(viewModel.currentTrackURL == nil)
            .opacity(viewModel.currentTrackURL == nil ? 0.4 : 1.0)

            Button {
                _ = viewModel.exportLyrics()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(AeroButtonStyle())
            .disabled(viewModel.currentTrackURL == nil)
            .opacity(viewModel.currentTrackURL == nil ? 0.4 : 1.0)

            if viewModel.currentTrackURL != nil {
                Button {
                    viewModel.closeEditor()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Close editor")
            }
        }
        .padding(sectionPadding)
    }

    // MARK: - Playback Controls

    private var playbackControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 24) {
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

            HStack(spacing: 10) {
                Text(formatTime(viewModel.currentTime))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 36, alignment: .trailing)

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
                    .frame(width: 36, alignment: .leading)
            }

            HStack(spacing: 6) {
                Text("Speed")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 36, alignment: .trailing)

                ForEach([Float(0.25), 0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                    Button {
                        viewModel.setSpeed(speed)
                    } label: {
                        Text(speed == 1.0 ? "1x" : String(format: "%.2gx", speed))
                            .font(.system(size: 10, weight: viewModel.playbackSpeed == speed ? .semibold : .medium, design: .monospaced))
                            .foregroundStyle(viewModel.playbackSpeed == speed ? .white : theme.textSecondary)
                            .frame(minWidth: 28)
                            .padding(.vertical, 3)
                            .background(
                                viewModel.playbackSpeed == speed
                                    ? theme.dotActive.opacity(0.9)
                                    : theme.textSecondary.opacity(0.08)
                            )
                            .background(
                                Capsule()
                                    .fill(.ultraThinMaterial.opacity(0.5))
                            )
                            .overlay(
                                Capsule()
                                    .fill(
                                        LinearGradient(
                                            colors: [.white.opacity(0.22), .white.opacity(0.02)],
                                            startPoint: .top,
                                            endPoint: .center
                                        )
                                    )
                                    .allowsHitTesting(false)
                            )
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(.white.opacity(0.14), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(CardStyle.padding)
        .aeroCard(radius: CardStyle.radius, wash: 0.08)
        .clipShape(RoundedRectangle(cornerRadius: CardStyle.radius))
        .overlay(
            RoundedRectangle(cornerRadius: CardStyle.radius)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        )
    }

    // MARK: - Metadata Bar

    private var metadataBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
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
            .padding(.horizontal, CardStyle.padding)
            .padding(.vertical, 8)
        }
        .background(theme.screenBackground.opacity(0.55))
        .background(.ultraThinMaterial)
        .aeroGloss(radius: 10, opacity: 0.10)
        .overlay(alignment: .trailing) {
            Button {
                withAnimation(.snappy) { showingMetaEditor.toggle() }
            } label: {
                Image(systemName: showingMetaEditor ? "xmark" : "slider.horizontal.3")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.dotActive)
                    .padding(8)
                    .background(Capsule().fill(.ultraThinMaterial))
                    .background(Capsule().fill(theme.screenBackground.opacity(0.85)))
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 10)
            .help("Adjust metadata (title, artists, writer, album, duration)")
        }
    }

    private func metaTag(icon: String, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(theme.dotActive)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textSecondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(theme.textSecondary.opacity(0.08))
        .background(Capsule().fill(.ultraThinMaterial.opacity(0.5)))
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
    }

    // MARK: - Loading State

    private var loadingState: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .progressViewStyle(.circular)
                .tint(theme.dotActive)
            Text("Loading audio...")
                .font(.system(size: 13))
                .foregroundStyle(theme.textSecondary)
            Spacer()
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    LinearGradient(
                        colors: [theme.haloPrimary, theme.haloSecondary],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 64, height: 64)
                .overlay(
                    Image(systemName: "doc.text")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                )
                .shadow(color: theme.haloPrimary.opacity(0.35), radius: 8, y: 2)
            Text("Clarc Editor")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.textPrimary)
            Text("Open an audio file to edit lyrics — or drop an .lrc\nanywhere to convert it into .clarc.")
                .font(.system(size: 13))
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                openFilePicker()
            } label: {
                Label("Open Audio", systemImage: "doc.badge.plus")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(AeroButtonStyle(prominent: true))
            Spacer()
        }
    }

    // MARK: - No Lyrics State

    private var noLyricsState: some View {
        VStack(spacing: 16) {
            Spacer()
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    LinearGradient(
                        colors: [theme.haloPrimary, theme.haloSecondary],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 64, height: 64)
                .overlay(
                    Image(systemName: "text.badge.plus")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                )
                .shadow(color: theme.haloPrimary.opacity(0.35), radius: 8, y: 2)
            Text("No Lyrics Found")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.textPrimary)
            Text("No .clarc/.lrc file found for this track.\nTap 'Add Line' below to create lyrics from scratch.")
                .font(.system(size: 13))
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
    }

    // MARK: - Lines List

    /// Row builder — split out of `linesList` so the big `LrcLineRow`
    /// expression type-checks in reasonable time.
    private func editRow(_ index: Int, _ line: EditableLrcLine) -> some View {
        LrcLineRow(
            line: line,
            index: index,
            isCurrent: index == viewModel.currentLineIndex,
            isRecordingTarget: viewModel.isRecording && index == viewModel.recordingCursorIndex,
            vocalistNames: viewModel.vocalistNames,
            onVocalistTap: { artistNumber, command, shift in
                viewModel.setVocalist(
                    lineIndex: index,
                    artistNumber: artistNumber,
                    command: command,
                    shift: shift)
            },
            onHarmonyToggle: { isHarmony in
                viewModel.setHarmony(lineIndex: index, isHarmony: isHarmony)
            },
            onTimestampTap: {
                viewModel.setTimestampForLine(at: index)
            },
            onDuplicate: {
                viewModel.duplicateLine(at: index)
            },
            onDuoDrop: {
                viewModel.applyDuoMarker(at: index)
            },
            onTextChange: { text in
                viewModel.updateLineText(at: index, text: text)
            },
            onDelete: {
                viewModel.removeLine(at: index)
            }
        )
    }

    private var linesList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(Array(viewModel.lines.enumerated()), id: \.element.id) { index, line in
                    editRow(index, line)
                        .id(line.id)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: contentPadding, bottom: 0, trailing: contentPadding))
                }
                .onMove { source, destination in
                    viewModel.moveLine(from: source, to: destination)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(theme.screenBackground.opacity(0.45))
            )
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(.ultraThinMaterial)
            )
            .aeroGloss(radius: 14, opacity: 0.10)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(.white.opacity(0.13), lineWidth: 1)
            )
            .onChange(of: viewModel.currentLineIndex) { _, newIndex in
                // Don't yank the list while the user is scrolled away —
                // follow resumes 8s after their last manual scroll.
                guard Date().timeIntervalSince(lastListInteraction) > 8 else { return }
                if newIndex >= 0, newIndex < viewModel.lines.count {
                    programmaticScroll = true
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(viewModel.lines[newIndex].id, anchor: .center)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        programmaticScroll = false
                    }
                }
            }
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { _, _ in
                if !programmaticScroll {
                    lastListInteraction = Date()
                }
            }
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button {
                viewModel.addLine()
            } label: {
                Label("Add Line", systemImage: "plus")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(AeroButtonStyle())

            Button {
                bulkText = ""
                showBulkPaste = true
            } label: {
                Label("Paste Lines", systemImage: "doc.on.clipboard")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(AeroButtonStyle())
            .help("Paste many lines — each gets [00:00.00]")
            .sheet(isPresented: $showBulkPaste) {
                bulkPasteSheet
            }

            // The [DUO] split marker as a drag handle: haul it onto any
            // lyric row and the line splits about evenly (lead ▸ tail).
            HStack(spacing: 4) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text("DUO")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
            }
            .foregroundStyle(theme.dotActive)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(theme.dotActive.opacity(0.14)))
            .background(Capsule().fill(.ultraThinMaterial.opacity(0.4)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 1))
            .draggable(EnhancedLRCViewModel.duoDragPayload)
            .help("Drag onto a lyric line to split it into a [DUO] duo row — double-click a split line to move the marker")

            Button {
                viewModel.previewFromTop()
            } label: {
                Label("Preview", systemImage: "play.circle")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(AeroButtonStyle(prominent: true))
            .disabled(viewModel.currentTrackURL == nil || viewModel.lines.isEmpty)
            .opacity(viewModel.currentTrackURL == nil || viewModel.lines.isEmpty ? 0.4 : 1.0)
            .help("Spread untimed lines across the song and play from top")

            Spacer()

            Text("\(viewModel.lineCount) lines")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.textSecondary)

            Button {
                viewModel.undo()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(AeroButtonStyle())
            .disabled(!viewModel.canUndo)
            .opacity(viewModel.canUndo ? 1.0 : 0.4)

            Button {
                requestClarcGuide()
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(AeroButtonStyle())
            .help("How CLARC works — open the format guide")
        }
        .padding(sectionPadding)
        .background(theme.screenBackground.opacity(0.55))
        .background(.ultraThinMaterial)
        .aeroGloss(radius: 14, opacity: 0.12)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(.white.opacity(0.13), lineWidth: 1)
        )
    }

    // MARK: - Bulk Paste Sheet

    private var bulkLineCount: Int {
        bulkText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .count
    }

    private var bulkPasteSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Paste Lyrics")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.textPrimary)
                    Text("One line per row · [mm:ss.xx] kept, plain lines get [00:00.00]")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer()
                // Listen while pasting — audio keeps rolling behind the sheet.
                Button {
                    viewModel.togglePlayback()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 14))
                        Text(formatTime(viewModel.currentTime))
                            .font(.system(size: 11, design: .monospaced))
                    }
                    .foregroundStyle(theme.dotActive)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(theme.dotActive.opacity(0.12)))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(viewModel.currentTrackURL == nil)
                .opacity(viewModel.currentTrackURL == nil ? 0.4 : 1.0)
                .help(viewModel.currentTrackURL == nil ? "Open audio first" : "Preview audio while pasting")
            }
            // Scrub while pasting — jump the song without leaving the sheet.
            HStack(spacing: 8) {
                Text(formatTime(viewModel.currentTime))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 34, alignment: .trailing)
                Slider(
                    value: Binding(
                        get: { viewModel.currentTime },
                        set: { viewModel.seek(to: $0) }
                    ),
                    in: 0...max(audioDuration, 1)
                )
                .disabled(viewModel.currentTrackURL == nil)
                Text(formatTime(audioDuration))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 34, alignment: .leading)
            }
            TextEditor(text: $bulkText)
                .font(.system(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(theme.textSecondary.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.12), lineWidth: 1))
                .frame(minHeight: 260)
            HStack {
                Text("\(bulkLineCount) lines")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                Button("Cancel") { showBulkPaste = false }
                    .buttonStyle(AeroButtonStyle())
                Button("Add \(bulkLineCount) lines") {
                    let texts = bulkText.components(separatedBy: .newlines)
                    viewModel.appendLines(texts)
                    bulkText = ""
                    showBulkPaste = false
                }
                .buttonStyle(AeroButtonStyle(prominent: true))
                .disabled(bulkLineCount == 0)
            }
        }
        .padding(20)
        .frame(width: 520, height: 440)
    }

    // MARK: - Helpers

    private var audioDuration: TimeInterval {
        guard let url = viewModel.currentTrackURL else { return 0 }
        let asset = AVURLAsset(url: url)
        return CMTimeGetSeconds(asset.duration)
    }

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.mp3, .wav, .aiff]
            + ["flac", "m4a", "caf", "ogg", "aac", "lrc", "clarc"].compactMap { UTType(filenameExtension: $0) }
        // .cluster/.cella are app-owned packages — descend like folders so the
        // library contents (audio + lrc/) stay reachable.
        panel.treatsFilePackagesAsDirectories = true
        // Start inside the defined cluster library when one exists.
        if let libPath = UserDefaults.standard.string(forKey: "clusterLibraryPath"),
           FileManager.default.fileExists(atPath: libPath) {
            panel.directoryURL = URL(fileURLWithPath: libPath)
        }
        panel.prompt = "Open Audio File"
        panel.message = "Select an audio file (or .lrc/.clarc) to edit lyrics"

        guard panel.runModal() == .OK, let picked = panel.url else { return }
        let audioURL = resolveAudioURL(from: picked)
        if let audioURL {
            Task {
                isLoading = true
                await viewModel.loadAudio(from: audioURL)
                isLoading = false
            }
        } else {
            // Bare lyric pick without a matching audio file.
            if picked.pathExtension.lowercased() == "clarc" {
                viewModel.adoptClarcFile(picked)
            } else if picked.pathExtension.lowercased() == "lrc" {
                viewModel.beginClarcConversion(from: picked)
            }
        }
    }

    /// Maps a picked .lrc/.clarc to its sibling audio file (same dir,
    /// same basename). Audio picks pass through unchanged.
    private func resolveAudioURL(from url: URL) -> URL? {
        let ext = url.pathExtension.lowercased()
        guard ext == "lrc" || ext == "clarc" else { return url }
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let audioExts = ["mp3", "wav", "m4a", "flac", "aac", "caf", "ogg", "aif"]
        let contents = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return contents.first {
            $0.deletingPathExtension().lastPathComponent == base
                && audioExts.contains($0.pathExtension.lowercased())
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Conversion Confirm Sheet

/// Shown for a dropped .lrc: the header extracted from the source is
/// presented as editable fields. Confirming writes the .clarc sibling and
/// trashes the source; nothing is written while this sheet is open.
private struct ClarcConversionSheet: View {
    let pending: EnhancedLRCViewModel.PendingClarcConversion
    let onConfirm: (_ title: String, _ artists: [String], _ writer: String, _ album: String, _ duration: String) -> Void
    let onCancel: () -> Void

    @Environment(\.theme) private var theme
    @State private var title = ""
    @State private var artists: [String] = []
    @State private var writer = ""
    @State private var album = ""
    @State private var duration = ""

    var body: some View {
        VStack(spacing: 14) {
            // Header
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath.doc")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.dotActive)
                    Text("Convert to Clarc")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.textPrimary)
                }
                Text("\(pending.sourceURL.lastPathComponent) → \(base + ".clarc")")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            // Fields
            VStack(spacing: 10) {
                field(label: "TITLE", text: $title, placeholder: "Song title")
                HStack(spacing: 10) {
                    field(label: "WRITER", text: $writer, placeholder: "Songwriter")
                    field(label: "ALBUM", text: $album, placeholder: "Album")
                    field(label: "DURATION", text: $duration, placeholder: "mm:ss")
                }
                artistsBlock
            }
            .padding(.horizontal, 2)

            if !pending.hadMeta {
                Text("Source had no header tags — lines only.")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.textSecondary)
            }

            HStack(spacing: 10) {
                Button {
                    onCancel()
                } label: {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AeroButtonStyle())

                Button {
                    onConfirm(title, artists, writer, album, duration)
                } label: {
                    Label("Convert", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AeroButtonStyle(prominent: true))
            }
        }
        .padding(18)
        .background(theme.screenBackground.opacity(0.92))
        .background(.ultraThinMaterial)
        .aeroGloss(radius: 18, opacity: 0.12)
        .onAppear {
            title = pending.title
            artists = pending.artists.isEmpty ? [""] : pending.artists
            writer = pending.writer
            album = pending.album
            duration = pending.duration
        }
    }

    private var base: String {
        pending.sourceURL.deletingPathExtension().lastPathComponent
    }

    private func field(label: String, text: Binding<String>, placeholder: String) -> some View {
        clarcField(label, text: text, placeholder: placeholder, theme: theme)
    }

    private var artistsBlock: some View {
        clarcArtistRows(artists: $artists, theme: theme)
    }
}

// MARK: - Clarc Field Builders (shared: convert sheet + meta edit panel)

private func clarcField(
    _ label: String,
    text: Binding<String>,
    placeholder: String,
    theme: Theme
) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(label)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(theme.textSecondary.opacity(0.8))
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: .rounded))
            .foregroundStyle(theme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(theme.textSecondary.opacity(0.08))
            .background(Capsule().fill(.ultraThinMaterial.opacity(0.5)))
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
    }
}

private func clarcArtistRows(artists: Binding<[String]>, theme: Theme) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
            Text("ARTISTS")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(theme.textSecondary.opacity(0.8))
            Text("(one per artist.N row)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(theme.textSecondary.opacity(0.5))
        }
        ForEach(artists.wrappedValue.indices, id: \.self) { index in
            HStack(spacing: 8) {
                Text("artist.\(index + 1)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.dotActive)
                    .frame(width: 56, alignment: .trailing)
                TextField("Artist \(index + 1)", text: artists[index])
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(theme.textSecondary.opacity(0.08))
                    .background(Capsule().fill(.ultraThinMaterial.opacity(0.5)))
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
                Button {
                    guard artists.wrappedValue.count > 1 else { artists.wrappedValue[0] = ""; return }
                    artists.wrappedValue.remove(at: index)
                } label: {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Remove artist")
            }
        }
        Button {
            artists.wrappedValue.append("")
        } label: {
            Label("Add artist", systemImage: "plus.circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.dotActive)
        }
        .buttonStyle(.plain)
        .padding(.leading, 64)
    }
}

// MARK: - Metadata Adjustment Panel

/// Inline edit panel shown under the meta bar (pencil toggle). Confirming
/// updates the editor header (undoable); the .clarc file persists on Save.
private struct ClarcMetaEditPanel: View {
    let baseName: String
    let initialTitle: String
    let initialArtists: [String]
    let initialWriter: String
    let initialAlbum: String
    let initialDuration: String
    let onApply: (_ title: String, _ artists: [String], _ writer: String, _ album: String, _ duration: String) -> Void
    let onCancel: () -> Void

    @Environment(\.theme) private var theme
    @State private var title = ""
    @State private var artists: [String] = []
    @State private var writer = ""
    @State private var album = ""
    @State private var duration = ""

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.dotActive)
                    Text("Adjust Metadata")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.textPrimary)
                    Text("\(baseName).clarc")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.textSecondary.opacity(0.7))
                }
                clarcField("TITLE", text: $title, placeholder: "Song title", theme: theme)
                clarcArtistRows(artists: $artists, theme: theme)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 10) {
                clarcField("WRITER", text: $writer, placeholder: "Songwriter", theme: theme)
                clarcField("ALBUM", text: $album, placeholder: "Album name", theme: theme)
                clarcField("DURATION", text: $duration, placeholder: "mm:ss", theme: theme)
                HStack(spacing: 8) {
                    Button {
                        onCancel()
                    } label: {
                        Text("Cancel")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AeroButtonStyle())

                    Button {
                        onApply(title, artists, writer, album, duration)
                    } label: {
                        Label("Apply", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AeroButtonStyle(prominent: true))
                }
                Text("Apply marks unsaved — Save writes the .clarc")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(theme.textSecondary.opacity(0.6))
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
            .frame(width: 260)
        }
        .padding(14)
        .background(theme.screenBackground.opacity(0.55))
        .background(.ultraThinMaterial)
        .aeroGloss(radius: 12, opacity: 0.10)
        .onAppear {
            title = initialTitle
            artists = initialArtists.isEmpty ? [""] : initialArtists
            writer = initialWriter
            album = initialAlbum
            duration = initialDuration
        }
    }
}

// MARK: - Line Row

struct LrcLineRow: View {
    let line: EditableLrcLine
    let index: Int
    let isCurrent: Bool
    let isRecordingTarget: Bool
    /// Artist names in v-index order — chips render only for lyric rows
    /// when the song has 2+ artists (CLARC [vN] attribution).
    let vocalistNames: [String]
    let onVocalistTap: (Int, Bool, Bool) -> Void
    let onHarmonyToggle: (Bool) -> Void
    let onTimestampTap: () -> Void
    let onDuplicate: () -> Void
    /// Dragging the bottom-bar `[DUO]` handle onto this row splits it.
    let onDuoDrop: () -> Void
    let onTextChange: (String) -> Void
    let onDelete: () -> Void

    @Environment(\.theme) private var theme
    @State private var editText: String = ""
    @State private var isEditing = false
    /// Highlight while a dragged `[DUO]` handle hovers over the row.
    @State private var duoTargeted = false
    @FocusState private var fieldFocused: Bool

    private var timestampForeground: Color {
        if isRecordingTarget || isCurrent { return .white }
        return theme.dotActive
    }

    private var timestampFill: Color {
        if isRecordingTarget { return Color.red.opacity(0.55) }
        if isCurrent { return theme.dotActive.opacity(0.35) }
        return theme.textSecondary.opacity(0.1)
    }

    private var timestampShadow: Color {
        if isRecordingTarget { return Color.red.opacity(0.4) }
        if isCurrent { return theme.dotActive.opacity(0.35) }
        return .clear
    }

    private var timestampLabel: some View {
        Text(line.timestampString)
            .font(.system(size: 12, weight: isCurrent ? .medium : .regular, design: .monospaced))
            .foregroundStyle(timestampForeground)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(timestampFill))
            .background(Capsule().fill(.ultraThinMaterial.opacity(0.4)))
            .overlay(timestampGloss)
            .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1))
            .shadow(color: timestampShadow, radius: 4)
    }

    private var timestampGloss: some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: [.white.opacity(0.25), .white.opacity(0.02)],
                    startPoint: .top,
                    endPoint: .center
                )
            )
            .allowsHitTesting(false)
    }

    /// Non-editing label. Duo rows reveal their split in place —
    /// `lead ▸ tail` — with the arrow marking where the row halves on the
    /// Cella screen. Plain rows read as their joined text.
    private var lineText: Text {
        if line.text.isEmpty {
            return Text("—").foregroundStyle(theme.textSecondary.opacity(0.5))
        }
        guard line.isDuo, !(line.duoLead.isEmpty && line.duoTail.isEmpty) else {
            return Text(line.text).foregroundStyle(theme.textPrimary)
        }
        var result = Text("")
        var hasLead = false
        if !line.duoLead.isEmpty {
            result = Text(line.duoLead).foregroundStyle(theme.textPrimary)
            hasLead = true
        }
        if !line.duoLead.isEmpty && !line.duoTail.isEmpty {
            result = result + Text("  ▸  ").foregroundStyle(theme.textSecondary.opacity(0.55))
        }
        if !line.duoTail.isEmpty {
            let tail = Text(line.duoTail).foregroundStyle(theme.textPrimary)
            result = hasLead ? result + tail : tail
        }
        return result
    }

    /// Static [DUO] badge — mirrors the [har] badge styling but in the
    /// accent shade, signalling the row is split into lead ▸ tail.
    private var duoBadge: some View {
        Text("DUO")
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(theme.dotActive)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(Capsule().fill(theme.dotActive.opacity(0.14)))
            .background(Capsule().fill(.ultraThinMaterial.opacity(0.4)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 1))
            .help("DUO split — lead ▸ tail. Double-click the line to move or remove the split; drag the DUO handle from the bottom bar onto another line.")
    }

    /// One v-chip: marked = filled accent; hover shows the artist name.
    /// Modifier-aware: plain tap = single mark, ⌘tap = toggle in the set,
    /// ⇧tap = range paint. Modifier routes go through explicit
    /// `TapGesture().modifiers(...)` gestures — an unmodified
    /// `.onTapGesture` can't be trusted to see ⌘/⇧ at action time on
    /// macOS List rows, which is why multi-marking used to fail.
    private func vocalistChip(_ artistNumber: Int, artistName: String) -> some View {
        let marked = line.vocalists.contains(artistNumber)
        return Text("v\(artistNumber)")
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(marked ? Color.white : theme.textSecondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(Capsule().fill(marked ? theme.dotActive : theme.textSecondary.opacity(0.08)))
            .background(Capsule().fill(.ultraThinMaterial.opacity(0.4)))
            .overlay(Capsule().strokeBorder(.white.opacity(marked ? 0.3 : 0.14), lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture { chipPlainTapped(artistNumber) }
            .simultaneousGesture(
                TapGesture().modifiers(.command).onEnded {
                    // ⌘⇧ together: let the shift-range route win.
                    guard !(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false) else { return }
                    onVocalistTap(artistNumber, true, false)
                }
            )
            .simultaneousGesture(
                TapGesture().modifiers(.shift).onEnded {
                    onVocalistTap(artistNumber, false, true)
                }
            )
            .help("\(artistName) [v\(artistNumber)] — click: single · ⌘click: multi · ⇧click: range")
    }

    /// Plain-tap route. Bails out when ⌘/⇧ are held — SwiftUI fires the
    /// unmodified gesture alongside the modifier-aware ones above, so this
    /// keeps every click resolved to exactly one marking action.
    private func chipPlainTapped(_ artistNumber: Int) {
        let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.ModifierFlags()
        guard flags.intersection([.command, .shift]).isEmpty else { return }
        onVocalistTap(artistNumber, false, false)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 24, alignment: .trailing)

            Button {
                onTimestampTap()
            } label: {
                timestampLabel
            }
            .buttonStyle(.plain)

            // Vocalist chips (lyric rows, 2+ artist songs): plain tap marks
            // that singer, ⌘+tap toggles a duo/trio [v1&v2…] mark. Harmony
            // [har] rows show a static har badge instead (no chips).
            if !line.isHarmony, vocalistNames.count >= 2 {
                HStack(spacing: 3) {
                    ForEach(Array(vocalistNames.enumerated()), id: \.offset) { vIndex, name in
                        vocalistChip(vIndex + 1, artistName: name)
                    }
                }
            }

            if line.isHarmony {
                Text("har")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(theme.textSecondary.opacity(0.08)))
                    .background(Capsule().fill(.ultraThinMaterial.opacity(0.4)))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
                    .help("Harmony backing part — right-click the row to convert to lyric")
            }

            if line.isDuo {
                duoBadge
            }

            if isEditing {
                TextField("Lyrics", text: $editText)
                    .font(.system(size: 14))
                    .focused($fieldFocused)
                    .onSubmit {
                        onTextChange(editText)
                        isEditing = false
                    }
                    .onExitCommand {
                        isEditing = false
                    }
                    .onChange(of: isEditing) { _, editing in
                        // Grab focus on open so the first keystroke types
                        // instead of hitting the R/M recorder shortcuts.
                        if editing {
                            DispatchQueue.main.async { fieldFocused = true }
                        }
                    }
            } else {
                lineText
                    .font(.system(size: 14))
                    .lineLimit(1)
                    .onTapGesture(count: 2) {
                        // Duo rows open in their raw `lead [DUO] tail`
                        // form so the marker is right there in the field.
                        editText = line.rawEditText
                        isEditing = true
                    }
            }

            Spacer()

            if isCurrent {
                Circle()
                    .fill(theme.dotActive)
                    .frame(width: 6, height: 6)
                    .transition(.scale.combined(with: .opacity))
            }

            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(.red.opacity(0.8))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.red.opacity(0.1)))
                    .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(
                    isRecordingTarget
                        ? Color.red.opacity(0.10)
                        : isCurrent
                            ? theme.dotActive.opacity(0.10)
                            : theme.textSecondary.opacity(0.04)
                )
        )
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThinMaterial.opacity(isCurrent || isRecordingTarget ? 0.5 : 0.0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    duoTargeted
                        ? theme.dotActive.opacity(0.55)
                        : isRecordingTarget
                            ? Color.red.opacity(0.35)
                            : isCurrent
                                ? theme.dotActive.opacity(0.3)
                                : .white.opacity(0.08),
                    lineWidth: 1
                )
        )
        // Catch the [DUO] handle dragged from the bottom bar — hovering
        // lights the row's border, dropping splits the line.
        .dropDestination(for: String.self) { payload, _ in
            guard payload.contains(EnhancedLRCViewModel.duoDragPayload) else { return false }
            onDuoDrop()
            return true
        } isTargeted: { duoTargeted = $0 }
        .listRowBackground(Color.clear)
        .contextMenu {
            Button {
                onHarmonyToggle(!line.isHarmony)
            } label: {
                Label(
                    line.isHarmony ? "Convert to Lyric" : "Convert to Harmony  [har]",
                    systemImage: line.isHarmony ? "text.line.first.and.line.last" : "music.note")
            }
            if line.isDuo {
                Button {
                    // Submitting the joined text carries no marker —
                    // `apply(text:)` folds the row back to a plain line.
                    onTextChange(line.text)
                } label: {
                    Label("Remove [DUO] Split", systemImage: "arrow.merge")
                }
            }
            Divider()
            Button {
                onDuplicate()
            } label: {
                Label("Clone Line", systemImage: "plus.rectangle.on.rectangle")
            }
            Divider()
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete Line", systemImage: "trash")
            }
        }
        .animation(.snappy, value: isCurrent)
    }
}

#Preview {
    EnhancedLRCView(viewModel: EnhancedLRCViewModel(), pendingAudioURL: .constant(nil), hasAudio: .constant(false))
}
