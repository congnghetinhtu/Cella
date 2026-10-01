import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// CueLab sheet: build a per-album .cue inside the Cluster library.
struct CueLabView: View {
    @StateObject private var draft = CueLabViewModel()
    var libraryURL: URL?
    var packs: [CellaPack] = []
    var onDone: () -> Void = {}

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var newAlbumName = ""
    @State private var showSuccess = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(theme.textSecondary.opacity(0.12))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sourceSection
                    targetSection
                    tracksSection
                    renameSection
                    optionsSection
                    if let err = draft.error {
                        Text(err).font(.system(size: 12)).foregroundStyle(.red)
                    }
                    if showSuccess, let url = draft.didExportURL {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text("Wrote \(url.lastPathComponent)").font(.system(size: 12, weight: .medium, design: .rounded))
                            Spacer()
                            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                .buttonStyle(AeroButtonStyle(prominent: true))
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(theme.textSecondary.opacity(0.08)))
                    }
                }
                .padding(20)
            }
            footer
        }
        .frame(width: 680, height: 620)
        .background(theme.appBackground.opacity(0.72))
        .background(.ultraThinMaterial)
        .aeroGloss(radius: 18, opacity: 0.10)
        .onAppear {
            if let lib = libraryURL {
                let packs = ClusterLibrary.scan(lib).packs
                if let first = packs.first, draft.targetPackURL == nil {
                    draft.targetPackURL = first.url
                    draft.targetAlbumName = ""
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "list.bullet.rectangle.fill").font(.system(size: 14)).foregroundStyle(theme.dotActive)
            VStack(alignment: .leading, spacing: 1) {
                Text("CueLab").font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(theme.textPrimary)
                Text("By CueLab, Cella 2026 • REM DATE \(draft.year)")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.textSecondary)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(theme.textSecondary)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    // MARK: - Source

    private var sourceSection: some View {
        GroupBox("1 · Source files") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("Add files…") { pickSources() }.buttonStyle(AeroButtonStyle(prominent: true))
                    Button("Clear") { draft.clear() }.buttonStyle(.plain).foregroundStyle(theme.textSecondary)
                        .disabled(draft.sourceURLs.isEmpty)
                    Spacer()
                    Text("\(draft.sourceURLs.count) files").font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.textSecondary)
                }
                if draft.sourceURLs.isEmpty {
                    Text("Drop audio here or pick from Downloads. Files move into the album on export.")
                        .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                } else {
                    ForEach(draft.tracks) { t in
                        HStack(spacing: 8) {
                            Image(systemName: t.extMismatch ? "exclamationmark.triangle.fill" : "music.note")
                                .font(.system(size: 11)).foregroundStyle(t.extMismatch ? .orange : theme.textSecondary)
                            Text(t.sourceURL.lastPathComponent).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                            Spacer()
                            if t.extMismatch {
                                Text("not \(draft.format.label)").font(.system(size: 10)).foregroundStyle(.orange)
                            }
                        }
                    }
                }
                Divider().background(theme.textSecondary.opacity(0.12))
                HStack(spacing: 10) {
                    if let cover = draft.coverURL, let img = NSImage(contentsOf: cover) {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        RoundedRectangle(cornerRadius: 8).fill(theme.textSecondary.opacity(0.1))
                            .frame(width: 44, height: 44)
                            .overlay(Image(systemName: "photo").font(.system(size: 14)).foregroundStyle(theme.textSecondary))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cover").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(theme.textSecondary)
                        Text(draft.coverURL?.lastPathComponent ?? "No cover — drop an image or pick one")
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(theme.textPrimary).lineLimit(1)
                    }
                    Spacer()
                    Button("Pick…") { pickCover() }.buttonStyle(AeroButtonStyle(prominent: true))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                    if draft.coverURL != nil {
                        Button { draft.setCover(nil) } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: .constant(false)) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url = url as? URL {
                        DispatchQueue.main.async { draft.addSources([url]) }
                    }
                }
            }
            return true
        }
    }

    // MARK: - Target

    private var targetSection: some View {
        GroupBox("2 · Playlist, album, format") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text("Playlist").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(theme.textSecondary).frame(width: 70, alignment: .leading)
                    Menu {
                        ForEach(packs) { pack in
                            Button(pack.name) {
                                draft.targetPackURL = pack.url
                                draft.targetAlbumName = ""
                            }
                        }
                    } label: {
                        HStack {
                            Text(packName ?? "Choose playlist").lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
                        }
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(theme.textSecondary.opacity(0.08)))
                    }
                    .menuStyle(.borderlessButton).buttonStyle(.plain)
                }
                HStack(spacing: 10) {
                    Text("Album").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(theme.textSecondary).frame(width: 70, alignment: .leading)
                    Menu {
                        ForEach(existingAlbums, id: \.self) { name in
                            Button(name) { draft.targetAlbumName = name }
                        }
                    } label: {
                        HStack {
                            Text(draft.targetAlbumName.isEmpty ? "Choose or type below" : draft.targetAlbumName).lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
                        }
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(theme.textSecondary.opacity(0.08)))
                    }
                    .menuStyle(.borderlessButton).buttonStyle(.plain)
                }
                HStack(spacing: 10) {
                    Text("").frame(width: 70)
                    TextField("New album folder name", text: $newAlbumName)
                        .textFieldStyle(.plain).font(.system(size: 12, weight: .medium, design: .rounded))
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(theme.textSecondary.opacity(0.08)))
                        .onChange(of: newAlbumName) { _, v in
                            if !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                draft.targetAlbumName = v
                            }
                        }
                    Button("Re-edit") {
                        guard let packURL = draft.targetPackURL else {
                            draft.error = "Choose a playlist first."
                            return
                        }
                        let album = draft.targetAlbumName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !album.isEmpty else {
                            draft.error = "Choose an existing album to re-edit."
                            return
                        }
                        do {
                            try draft.loadAlbum(packURL: packURL, albumName: album)
                            newAlbumName = ""
                        } catch {
                            draft.error = error.localizedDescription
                        }
                    }
                    .buttonStyle(AeroButtonStyle(prominent: true))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .help("Load existing album cue + files for re-edit")
                }
                HStack(spacing: 10) {
                    Text("Format").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(theme.textSecondary).frame(width: 70, alignment: .leading)
                    Picker("Format", selection: $draft.format) {
                        ForEach(CueLabViewModel.Format.allCases) { f in Text(f.label).tag(f) }
                    }
                    .pickerStyle(.segmented).frame(width: 260)
                    .onChange(of: draft.format) { _, _ in draft.rebuildTracks() }
                    Spacer()
                    Text("linked in FILE lines").font(.system(size: 10)).foregroundStyle(theme.textSecondary)
                }
                HStack(spacing: 10) {
                    Text("TITLE").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(theme.textSecondary).frame(width: 70, alignment: .leading)
                    TextField("Album title for cue", text: $draft.albumTitle)
                        .textFieldStyle(.plain).font(.system(size: 12, weight: .medium, design: .rounded))
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(theme.textSecondary.opacity(0.08)))
                    TextField("Year", text: $draft.year)
                        .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                        .frame(width: 70)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(theme.textSecondary.opacity(0.08)))
                }
            }
        }
    }

    // MARK: - Tracks

    private var tracksSection: some View {
        GroupBox("3 · Songs — FILE, TRACK, TITLE, PERFORMER (editable)") {
            VStack(spacing: 6) {
                if draft.tracks.isEmpty {
                    Text("No tracks yet.").font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                } else {
                    ForEach($draft.tracks) { $track in
                        HStack(spacing: 8) {
                            Text(String(format: "%02d", (draft.tracks.firstIndex(where: { $0.id == track.id }) ?? 0) + 1))
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.textSecondary).frame(width: 24)
                            VStack(alignment: .leading, spacing: 4) {
                                TextField("FILE name", text: $track.fileName)
                                    .textFieldStyle(.plain).font(.system(size: 11, design: .monospaced))
                                    .onChange(of: track.fileName) { _, v in draft.updateFileName(id: track.id, fileName: v) }
                                HStack(spacing: 6) {
                                    TextField("TITLE (diacritics ok)", text: $track.title)
                                        .textFieldStyle(.plain).font(.system(size: 12, weight: .medium, design: .rounded))
                                        .onChange(of: track.title) { _, v in draft.updateTitle(id: track.id, title: v) }
                                    TextField("PERFORMER", text: $track.performer)
                                        .textFieldStyle(.plain).font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                                        .onChange(of: track.performer) { _, v in draft.updatePerformer(id: track.id, performer: v) }
                                }
                                if let s = track.suggestedName, s != track.fileName {
                                    Text("→ \(s)")
                                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.dotActive)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(theme.textSecondary.opacity(0.06)))
                    }
                }
            }
        }
    }

    // MARK: - Rename

    private var renameSection: some View {
        GroupBox("4 · Bulk rename — Track_01.wav → bolero “NN - Title”") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Type TITLE with diacritics; FILE becomes ascii-folded like bolero (“Tình Yêu Vỗ Cánh” → “01 - Tinh Yeu Vo Canh.wav”). Number comes from the filename (Track_01 → 01).")
                    .font(.system(size: 11)).foregroundStyle(theme.textSecondary)
                if draft.renameSuggestions.isEmpty {
                    Text("No renames pending — filenames already match.")
                        .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                } else {
                    ForEach(draft.renameSuggestions, id: \.from) { item in
                        HStack {
                            Text(item.from).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.textSecondary).lineLimit(1)
                            Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(theme.dotActive)
                            Text(item.to).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.textPrimary).lineLimit(1)
                        }
                    }
                    Button("Apply renames") { draft.applySuggestedRenames() }
                        .buttonStyle(AeroButtonStyle(prominent: true))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                if !draft.loadedCueFileNames.isEmpty {
                    Divider().background(theme.textSecondary.opacity(0.12))
                    Text("From loaded cue FILE names (pairs by track order)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(theme.textSecondary)
                    if draft.cueRenameSuggestions.isEmpty {
                        Text("Files already match the cue names.")
                            .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                    } else {
                        ForEach(draft.cueRenameSuggestions, id: \.from) { item in
                            HStack {
                                Text(item.from).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.textSecondary).lineLimit(1)
                                Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(theme.dotActive)
                                Text(item.to).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.textPrimary).lineLimit(1)
                            }
                        }
                        Button("Rename files to cue names") { draft.applyCueFileNames() }
                            .buttonStyle(AeroButtonStyle(prominent: true))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                }
            }
        }
    }

    // MARK: - Options

    private var optionsSection: some View {
        GroupBox("5 · Folders") {
            Toggle("Add lrc folder if the album lacks it", isOn: $draft.ensureLrc)
                .font(.system(size: 12)).tint(theme.dotActive)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if let err = draft.validationError {
                Text(err).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2)
            }
            Spacer()
            Button("Cancel") { dismiss() }.buttonStyle(.plain).foregroundStyle(theme.textSecondary)
            Button("Create Cue") {
                do {
                    draft.error = nil
                    _ = try draft.export()
                    showSuccess = true
                    onDone()
                } catch {
                    draft.error = error.localizedDescription
                }
            }
            .buttonStyle(AeroButtonStyle(prominent: true))
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .disabled(draft.validationError != nil)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    // MARK: - Helpers

    private var packName: String? {
        packs.first(where: { $0.url == draft.targetPackURL })?.name
    }

    private var existingAlbums: [String] {
        guard let packURL = draft.targetPackURL else { return [] }
        return ClusterLibrary.albums(in: packURL).map { $0.folderName.isEmpty ? $0.name : $0.folderName }
    }

    private func pickSources() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.audio, .folder]
        panel.prompt = "Add"
        if panel.runModal() == .OK {
            draft.addSources(panel.urls)
        }
    }

    private func pickCover() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "Pick cover"
        if panel.runModal() == .OK, let url = panel.url {
            draft.setCover(url)
        }
    }
}

private struct GroupBox<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    @Environment(\.theme) private var theme

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.textSecondary)
            content()
        }
        .padding(14)
        .aeroCard(radius: 14, wash: 0.07)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.13), lineWidth: 1))
    }
}
