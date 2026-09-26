//
//  CellaMotionsView.swift
//  Cella
//
//  Cella Motions — create Instagram boomerang videos.
//  Mark-based trimmer: scrub to the moment, tap to mark in/out.
//  Precision from the big video frame, not tiny filmstrip handles.
//  Editor state lives in `MotionsViewModel` so it survives tab switches and
//  can be paused (and flagged Unsaved) from the nav layer.
//

import SwiftUI
import AVKit
import UniformTypeIdentifiers

/// Preset boomerang clip durations (seconds).
private let presetDurations: [Double] = [0.3, 0.5, 1.0, 2.0]

struct CellaMotionsView: View {
    @ObservedObject var viewModel: MotionsViewModel
    @Environment(\.theme) private var theme

    @State private var isDragOver: Bool = false

    private var cardBorder: some ShapeStyle {
        theme.textSecondary.opacity(CardStyle.borderOpacity)
    }

    private let cardRadius: CGFloat = CardStyle.radius
    private let gridSpacing: CGFloat = 28

    /// True while a text field owns the field editor (e.g. artist name in the
    /// save sheet) — block editor shortcuts so typing stays typing.
    private var isEditingText: Bool {
        NSApp.keyWindow?.firstResponder is NSTextView
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.sourceURL != nil {
                editor
            } else {
                dropZone
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.smooth, value: viewModel.sourceURL != nil)
        .onKeyPress(.space) { if isEditingText { return .ignored }; viewModel.playPause(); return .handled }
        .onKeyPress(.leftArrow) { if isEditingText { return .ignored }; viewModel.stepFrame(by: -1); return .handled }
        .onKeyPress(.rightArrow) { if isEditingText { return .ignored }; viewModel.stepFrame(by: 1); return .handled }
        .onKeyPress("i") { if isEditingText { return .ignored }; viewModel.markIn(); return .handled }
        .onKeyPress("o") { if isEditingText { return .ignored }; viewModel.markOut(); return .handled }
        .onKeyPress("l") { if isEditingText { return .ignored }; viewModel.toggleLoopPreview(); return .handled }
        .onKeyPress("[") { if isEditingText { return .ignored }; viewModel.nudgeTrimStart(-0.1); return .handled }
        .onKeyPress("]") { if isEditingText { return .ignored }; viewModel.nudgeTrimEnd(0.1); return .handled }
        .onChange(of: viewModel.trimStart) { _, _ in viewModel.noteClipChanged() }
        .onChange(of: viewModel.trimEnd) { _, _ in viewModel.noteClipChanged() }
        .onChange(of: viewModel.loopCount) { _, _ in viewModel.noteClipChanged() }
        .onChange(of: viewModel.targetDuration) { _, _ in viewModel.noteClipChanged() }
        .sheet(isPresented: Binding(
            get: { viewModel.pendingExportURL != nil },
            set: { if !$0 { viewModel.discardExport() } }
        )) {
            if let exportURL = viewModel.pendingExportURL {
                BoomerangSaveSheet(viewModel: viewModel, exportURL: exportURL)
            }
        }
    }

    // MARK: - Editor (canvas + split inspector, no scroll)

    private var editor: some View {
        GeometryReader { geo in
            bentoCard
                .padding(.horizontal, 96)
                .padding(.vertical, 64)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.appBackground)
        .overlay(alignment: .bottom) { toastOverlay }
    }

    private var bentoCard: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: cardRadius)
                .fill(theme.screenBackground)
            RoundedRectangle(cornerRadius: cardRadius)
                .stroke(cardBorder, lineWidth: 1)

            HStack(spacing: 0) {
                canvasColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider().background(theme.textSecondary.opacity(0.06))

                inspectorColumn
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Canvas Column (video + filmstrip + scrub)

    private var canvasColumn: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                headerRow
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    .padding(.bottom, 10)

                videoPlayer(maxVideoHeight: max(200, geo.size.height - 272))
                    .padding(.horizontal, 24)

                Divider().background(theme.textSecondary.opacity(0.06))
                    .padding(.vertical, 12)

                filmStrip
                    .padding(.horizontal, 24)

                Divider().background(theme.textSecondary.opacity(0.06))
                    .padding(.vertical, 12)

                scrubBar
                    .padding(.horizontal, 24)

                Spacer(minLength: 0)
                    .frame(height: 14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Header Row

    private var headerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "film")
                .font(.system(size: 13))
                .foregroundStyle(theme.dotActive)
            Text(viewModel.sourceURL?.lastPathComponent ?? "Video")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text("BOOMERANG")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.dotActive)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(theme.dotActive.opacity(0.15)))
            Button {
                viewModel.clearVideo()
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.textSecondary)
            .help("Clear and start over")
        }
    }

    // MARK: - Video Player (scales to card width, capped by viewport)

    private func videoPlayer(maxVideoHeight: CGFloat) -> some View {
        VideoPlayer(player: viewModel.player)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .aspectRatio(16/9, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: maxVideoHeight)
            .background(theme.appBackground)
    }

    // MARK: - Scrub Bar

    private var scrubBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Text(viewModel.formatTime(viewModel.currentTime))
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(theme.textPrimary)
                    .frame(minWidth: 60, alignment: .trailing)

                ThinScrubBar(
                    duration: viewModel.videoDuration,
                    currentTime: viewModel.currentTime,
                    theme: theme,
                    onSeek: { viewModel.seekTo($0) },
                    onSeekStarted: { viewModel.beginScrub() }
                )
                .frame(height: 28)

                Text(viewModel.formatTime(viewModel.videoDuration))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
                    .frame(minWidth: 60, alignment: .leading)
            }

            HStack(spacing: 16) {
                readoutCell("In", viewModel.formatTime(viewModel.trimStart))
                readoutCell("Dur", String(format: "%.2fs", viewModel.trimEnd - viewModel.trimStart))
                readoutCell("Out", viewModel.formatTime(viewModel.trimEnd))
            }
        }
    }

    private func readoutCell(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(theme.textSecondary.opacity(0.7))
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.tabBarBackground))
    }

    // MARK: - Filmstrip

    private var filmStrip: some View {
        VStack(spacing: 4) {
            HStack {
                Text(viewModel.zoomed ? "Detail view" : "Tap or drag to scrub")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(theme.textSecondary.opacity(0.8))
                Spacer()

                Button {
                    viewModel.toggleZoom()
                } label: {
                    Image(systemName: viewModel.zoomed ? "arrow.up.left.and.arrow.down.right" : "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.dotActive)
                }
                .buttonStyle(.plain)
                .help(viewModel.zoomed ? "Zoom out" : "Zoom in to selection")

                Text("\(viewModel.formatTime(viewModel.trimStart)) — \(viewModel.formatTime(viewModel.trimEnd))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.dotActive)
            }

            FilmstripBar(
                duration: viewModel.zoomed ? viewModel.zoomDuration : viewModel.videoDuration,
                trimStart: $viewModel.trimStart,
                trimEnd: $viewModel.trimEnd,
                currentTime: viewModel.currentTime,
                thumbnails: viewModel.zoomed ? viewModel.zoomThumbs : viewModel.overviewThumbs,
                theme: theme,
                visibleRange: viewModel.zoomed ? viewModel.zoomRange : nil,
                onScrub: { viewModel.seekTo($0) },
                onMoveSelectionTo: { viewModel.placeClip(at: $0, keepDuration: true) }
            )
            .frame(height: 64)
        }
    }

    // MARK: - Inspector Column

    private var inspectorColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            inspectorSectionLabel("MARK")
                .padding(.bottom, 8)
            inspectorMarkRow

            inspectorSpacer
            inspectorSectionLabel("CLIP")
                .padding(.bottom, 8)
            inspectorClipRow

            inspectorSpacer
            inspectorSectionLabel("PRECISION")
                .padding(.bottom, 8)
            inspectorPrecision

            inspectorSpacer
            inspectorSectionLabel("EXPORT")
                .padding(.bottom, 8)
            inspectorExport

            Spacer(minLength: 12)

            Text("I / O mark · Space play · ← → frame · [ ] trim · L loop")
                .font(.system(size: 9, design: .rounded))
                .foregroundStyle(theme.textSecondary.opacity(0.6))
                .lineLimit(2)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .frame(width: 292)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private var inspectorSpacer: some View {
        Divider().background(theme.textSecondary.opacity(0.06))
            .padding(.vertical, 14)
    }

    private func inspectorSectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .kerning(1.2)
            .foregroundStyle(theme.textSecondary.opacity(0.5))
    }

    private var inspectorMarkRow: some View {
        HStack(spacing: 10) {
            Button { viewModel.markIn() } label: {
                Label("In", systemImage: "arrow.left.to.line")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.dotActive)
            .help("Mark start (I)")

            Button { viewModel.markOut() } label: {
                Label("Out", systemImage: "arrow.right.to.line")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.dotActive)
            .help("Mark end (O)")

            Button { viewModel.toggleLoopPreview() } label: {
                Image(systemName: viewModel.isLoopPreviewing ? "stop.fill" : "repeat")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(viewModel.isLoopPreviewing ? theme.dotActive : theme.textSecondary)
            .help("Loop preview (L)")
        }
    }

    private var inspectorClipRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ForEach(presetDurations, id: \.self) { secs in
                    Button(String(format: "%.1fs", secs)) {
                        viewModel.setTargetDuration(secs)
                    }
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .buttonStyle(.bordered)
                    .tint(viewModel.targetDuration == secs ? theme.dotActive : theme.textSecondary)
                    .frame(maxWidth: .infinity)
                }
            }

            HStack(spacing: 10) {
                Text("Repeats")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.textSecondary)

                Button {
                    withAnimation(.snappy) { viewModel.setLoopCount(viewModel.loopCount - 1) }
                } label: {
                    Image(systemName: "minus.circle.fill").font(.system(size: 15))
                }
                .buttonStyle(.plain)
                .foregroundStyle(viewModel.loopCount <= 1 ? theme.textSecondary.opacity(0.3) : theme.textSecondary)
                .disabled(viewModel.loopCount <= 1)

                Text("\(viewModel.loopCount)")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(theme.textPrimary)
                    .frame(width: 22)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: viewModel.loopCount)

                Button {
                    withAnimation(.snappy) { viewModel.setLoopCount(viewModel.loopCount + 1) }
                } label: {
                    Image(systemName: "plus.circle.fill").font(.system(size: 15))
                }
                .buttonStyle(.plain)
                .foregroundStyle(viewModel.loopCount >= 8 ? theme.textSecondary.opacity(0.3) : theme.textSecondary)
                .disabled(viewModel.loopCount >= 8)

                Spacer()
            }
        }
    }

    private var inspectorPrecision: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Frame")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 46, alignment: .leading)

                Button { viewModel.stepFrame(by: -1) } label: {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.bordered).tint(theme.textSecondary)
                .help("Previous frame (←)")

                Button { viewModel.stepFrame(by: 1) } label: {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.bordered).tint(theme.textSecondary)
                .help("Next frame (→)")

                Spacer()
            }

            HStack(spacing: 10) {
                Text("Trim")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 46, alignment: .leading)

                Button { viewModel.nudgeTrimStart(-0.1) } label: {
                    Image(systemName: "chevron.left.2").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.bordered).tint(theme.textSecondary)
                .help("Trim start −0.1s ([)")

                Button { viewModel.nudgeTrimEnd(0.1) } label: {
                    Image(systemName: "chevron.right.2").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.bordered).tint(theme.textSecondary)
                .help("Trim end +0.1s (])")

                Spacer()
            }
        }
    }

    private var inspectorExport: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !viewModel.isExporting {
                Button("Create Boomerang") { viewModel.createBoomerang() }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .buttonStyle(.borderedProminent)
                    .tint(theme.dotActive)
                    .disabled(viewModel.videoDuration <= 0)
                    .frame(maxWidth: .infinity)
            } else {
                ProgressView(value: viewModel.exportProgress).frame(maxWidth: .infinity)
                Text("\(Int(viewModel.exportProgress * 100))%")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
            }

            if viewModel.outputURL != nil {
                Button {
                    if let url = viewModel.outputURL {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(theme.dotActive)
                .help("Show in Finder")
            }
        }
    }

    // MARK: - Toast

    private var toastOverlay: some View {
        Group {
            if let toast = viewModel.toast {
                HStack(spacing: 6) {
                    Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    Text(toast.text)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                }
                .foregroundStyle(toast.isError ? .red : .green)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Capsule().fill(.ultraThinMaterial))
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: viewModel.toast != nil)
    }

    // MARK: - Drop Zone

    private var dropZone: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: gridSpacing) {
                dropCard
            }
            .padding(.horizontal, 96)
            .padding(.vertical, 64)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.appBackground)
    }

    private var dropCard: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: cardRadius)
                .fill(theme.screenBackground)
            RoundedRectangle(cornerRadius: cardRadius)
                .stroke(cardBorder, lineWidth: 1)

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "film")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.dotActive)
                    Text("Boomerang")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    Text("MP4 · MOV")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(theme.dotInactive.opacity(0.25)))
                }
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 16)

                dropTarget
                    .frame(maxHeight: .infinity)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 24)
            }
        }
        .frame(height: 460)
    }

    private var dropTarget: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cardRadius)
                .fill(theme.dotActive.opacity(isDragOver ? 0.06 : 0))
            RoundedRectangle(cornerRadius: cardRadius)
                .stroke(
                    isDragOver ? theme.dotActive : theme.dotActive.opacity(0.35),
                    style: StrokeStyle(lineWidth: isDragOver ? 3 : 2, dash: [8, 6])
                )

            VStack(spacing: 14) {
                Image(systemName: "film")
                    .font(.system(size: 44))
                    .foregroundStyle(theme.dotActive.opacity(0.6))
                Text("Drop video here")
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                Text("Drag a clip in, or browse")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(theme.textSecondary)

                Button("Browse…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        viewModel.loadVideo(url)
                    }
                }
                .buttonStyle(.bordered)
                .tint(theme.dotActive)
            }
            .padding(24)
        }
        .contentShape(RoundedRectangle(cornerRadius: cardRadius))
        .scaleEffect(isDragOver ? 1.01 : 1.0)
        .animation(.snappy, value: isDragOver)
        .onDrop(of: [.fileURL], isTargeted: $isDragOver) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url = url as? URL {
                    DispatchQueue.main.async { viewModel.loadVideo(url) }
                }
            }
            return true
        }
    }
}

// MARK: - Boomerang Save Sheet

/// Shown after a boomerang finishes exporting. The user picks the target album
/// (.cella pack) and an artist; the file lands in `<album>/cma/<Artist>/videoN.cma`.
struct BoomerangSaveSheet: View {
    @ObservedObject var viewModel: MotionsViewModel
    let exportURL: URL

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var packs: [CellaPack] = []
    @State private var selectedPack: CellaPack?
    @State private var artist: String = ""
    @State private var hasSeeded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "film.stack")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.dotActive)
                Text("Where to save?")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Text("Boomerang ready")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(theme.dotActive)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(theme.dotActive.opacity(0.15)))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("ALBUM")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .kerning(1.2)
                    .foregroundStyle(theme.textSecondary.opacity(0.5))
                if packs.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No .cella albums found")
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(theme.textSecondary)
                        Button("Choose Library…") {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = false
                            panel.canChooseDirectories = true
                            panel.allowsMultipleSelection = false
                            panel.prompt = "Choose Library"
                            if panel.runModal() == .OK, let url = panel.url {
                                UserDefaults.standard.set(url.path, forKey: "clusterLibraryPath")
                                viewModel.libraryURL = url
                                packs = viewModel.exportPacks
                                if let first = packs.first { selectPack(first) }
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(theme.dotActive)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                    }
                } else {
                    Menu {
                        ForEach(packs) { pack in
                            Button(pack.name) {
                                selectPack(pack)
                            }
                        }
                    } label: {
                        HStack {
                            Text(selectedPack?.name ?? "Choose album")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(selectedPack != nil ? theme.textPrimary : theme.textSecondary)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(theme.textSecondary.opacity(0.6))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(theme.tabBarBackground))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.textSecondary.opacity(0.2), lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .buttonStyle(.plain)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("ARTIST")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .kerning(1.2)
                    .foregroundStyle(theme.textSecondary.opacity(0.5))
                TextField("Artist name", text: $artist)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.tabBarBackground))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.textSecondary.opacity(0.2), lineWidth: 1))

                if let selectedPack, !existingArtists.isEmpty {
                    Text("In this album:")
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(theme.textSecondary.opacity(0.6))
                        .padding(.top, 2)
                    FlowCapsules(items: existingArtists, highlight: artist) { name in
                        artist = name
                    }
                }
            }

            Text("Saves to \(selectedPackName)/cma/\(artistName)/videoN.cma")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(theme.textSecondary.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { viewModel.discardExport() }
                    .buttonStyle(.bordered)
                    .tint(theme.textSecondary)
                Button("Save") {
                    if let pack = selectedPack, viewModel.saveExport(to: pack.url, artist: artist) {
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.dotActive)
                .disabled(selectedPack == nil || artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .background(theme.screenBackground)
        .onAppear(perform: seed)
    }

    private var existingArtists: [String] {
        guard let pack = selectedPack else { return [] }
        return viewModel.existingArtists(in: pack.url)
    }

    private var selectedPackName: String {
        selectedPack?.name ?? "…"
    }

    private var artistName: String {
        let trimmed = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "…" : trimmed
    }

    private func selectPack(_ pack: CellaPack) {
        let previous = selectedPack
        selectedPack = pack
        guard let suggested = viewModel.suggestedArtist(for: pack.url) else {
            if previous == nil { artist = "" }
            return
        }
        if previous == nil || artist.isEmpty {
            artist = suggested
        } else if let prevPack = previous,
                  let prevSuggestion = viewModel.suggestedArtist(for: prevPack.url),
                  artist == prevSuggestion {
            artist = suggested
        }
    }

    private func seed() {
        hasSeeded = true
        packs = viewModel.exportPacks
        guard let defaultPack = packs.first(where: {
            viewModel.suggestedArtist(for: $0.url) != nil
        }) ?? packs.first else { return }
        selectPack(defaultPack)
    }
}

// MARK: - Artist Quick-Pick Capsules

private struct FlowCapsules: View {
    let items: [String]
    let highlight: String
    let onPick: (String) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items, id: \.self) { item in
                Button(item) { onPick(item) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(item == highlight ? theme.dotActive : theme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(item == highlight ? theme.dotActive.opacity(0.16) : theme.textSecondary.opacity(0.08)))
                    .overlay(Capsule().stroke(item == highlight ? theme.dotActive.opacity(0.4) : theme.textSecondary.opacity(0.15), lineWidth: 1))
                    .onTapGesture { onPick(item) }
            }
        }
    }
}

// MARK: - Thin Scrub Bar

struct ThinScrubBar: View {
    let duration: Double
    let currentTime: Double
    let theme: Theme
    var onSeek: ((Double) -> Void)?
    var onSeekStarted: (() -> Void)?

    @State private var isDragging = false

    private let barHeight: CGFloat = 5
    private let hitHeight: CGFloat = 24
    private let knobSize: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let progress = duration > 0 ? currentTime / duration : 0
            let knobX = CGFloat(progress) * w

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: barHeight / 2)
                    .fill(theme.textSecondary.opacity(0.2))
                    .frame(height: barHeight)
                    .frame(maxHeight: .infinity)

                RoundedRectangle(cornerRadius: barHeight / 2)
                    .fill(theme.dotActive)
                    .frame(width: max(0, knobX), height: barHeight)
                    .frame(maxHeight: .infinity)

                Circle()
                    .fill(.white)
                    .frame(width: knobSize, height: knobSize)
                    .position(x: knobX, y: geo.size.height / 2)
                    .shadow(color: .black.opacity(0.5), radius: 3)
                    .scaleEffect(isDragging ? 1.3 : 1.0)
                    .animation(.snappy, value: isDragging)
            }
            .frame(width: w, height: hitHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDragging { onSeekStarted?() }
                        isDragging = true
                        let p = Double(value.location.x / w) * duration
                        onSeek?(max(0, min(p, duration)))
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
        }
    }
}

// MARK: - Filmstrip Bar

struct FilmstripBar: View {
    let duration: Double
    @Binding var trimStart: Double
    @Binding var trimEnd: Double
    let currentTime: Double
    let thumbnails: [NSImage]
    let theme: Theme
    var visibleRange: ClosedRange<Double>?
    var onScrub: ((Double) -> Void)?
    var onMoveSelectionTo: ((Double) -> Void)?

    @State private var dragOrigin: Double?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let sx = x(trimStart, w)
            let ex = x(trimEnd, w)
            let px = x(currentTime, w)
            let selWidth = max(8, ex - sx)

            ZStack(alignment: .leading) {
                if thumbnails.isEmpty {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(theme.dotInactive.opacity(0.3))
                } else {
                    HStack(spacing: 0) {
                        ForEach(thumbnails.indices, id: \.self) { i in
                            Image(nsImage: thumbnails[i])
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: max(1, w / CGFloat(thumbnails.count)), height: h)
                                .clipped()
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                if sx > 0 {
                    Rectangle().fill(.black.opacity(0.55)).frame(width: sx, height: h)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                if ex < w {
                    Rectangle().fill(.black.opacity(0.55)).frame(width: w - ex, height: h)
                        .offset(x: ex).clipShape(RoundedRectangle(cornerRadius: 4))
                }

                RoundedRectangle(cornerRadius: 4)
                    .stroke(theme.dotActive, lineWidth: 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(theme.dotActive.opacity(0.1)))
                    .frame(width: selWidth, height: h)
                    .position(x: (sx + ex) / 2, y: h / 2)

                if selWidth > 60 {
                    Text(String(format: "%.1fs", trimEnd - trimStart))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(theme.dotActive)
                        .position(x: (sx + ex) / 2, y: h / 2)
                        .allowsHitTesting(false)
                }

                edgeMarker(x: sx, h: h)
                edgeMarker(x: ex, h: h)

                // Left handle
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .frame(width: 18, height: h).position(x: sx, y: h / 2)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        let wd = visibleRange.map { $0.upperBound - $0.lowerBound } ?? duration
                        trimStart = max(0, min(trimStart + Double(value.translation.width) * wd / max(Double(w), 1), trimEnd - 0.05))
                    })

                // Right handle
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .frame(width: 18, height: h).position(x: ex, y: h / 2)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        let wd = visibleRange.map { $0.upperBound - $0.lowerBound } ?? duration
                        trimEnd = min(duration, max(trimEnd + Double(value.translation.width) * wd / max(Double(w), 1), trimStart + 0.05))
                    })

                // Selection move
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .frame(width: selWidth, height: h)
                    .position(x: (sx + ex) / 2, y: h / 2)
                    .gesture(moveDrag(width: w))

                // Playhead
                VStack(spacing: 0) {
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: 0))
                        p.addLine(to: CGPoint(x: 8, y: 0))
                        p.addLine(to: CGPoint(x: 4, y: 6))
                        p.closeSubpath()
                    }
                    .fill(.white).frame(width: 8, height: 6)
                    Rectangle().fill(.white).frame(width: 1.5, height: h - 6)
                }
                .position(x: px, y: h / 2)
                .shadow(color: .black.opacity(0.7), radius: 2)
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    onScrub?(timeFromPixel(value.location.x, w))
                })
                .allowsHitTesting(true)
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .onTapGesture { location in
                onScrub?(timeFromPixel(location.x, w))
            }
        }
    }

    private func edgeMarker(x: CGFloat, h: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3).fill(theme.dotActive)
            .frame(width: 3, height: h).position(x: x, y: h / 2)
    }

    private func moveDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragOrigin == nil { dragOrigin = trimStart }
                let wd = visibleRange.map { $0.upperBound - $0.lowerBound } ?? duration
                let delta = Double(value.translation.width) * wd / max(Double(width), 1)
                let sel = trimEnd - trimStart
                let s = max(0, min((dragOrigin ?? 0) + delta, duration - sel))
                trimStart = s; trimEnd = s + sel
            }
            .onEnded { _ in dragOrigin = nil; onMoveSelectionTo?(trimStart) }
    }

    private func x(_ time: Double, _ w: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        if let range = visibleRange {
            let d = range.upperBound - range.lowerBound
            guard d > 0 else { return 0 }
            return CGFloat((time - range.lowerBound) / d) * w
        }
        return CGFloat(time / duration) * w
    }

    private func timeFromPixel(_ px: CGFloat, _ w: CGFloat) -> Double {
        guard w > 0 else { return 0 }
        let f = Double(px / w)
        if let range = visibleRange {
            let lo = range.lowerBound, hi = range.upperBound
            return max(lo, min(lo + f * (hi - lo), hi))
        }
        return max(0, min(f * duration, duration))
    }
}