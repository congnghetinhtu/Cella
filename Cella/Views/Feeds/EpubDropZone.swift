//
//  EpubDropZone.swift
//  Cella
//
//  Drag-drop bar for epub files with reading progress display.
//

import SwiftUI
import UniformTypeIdentifiers

struct EpubDropZone: View {
    @Environment(\.theme) private var theme
    var feedsVM: FeedsViewModel
    @State private var isDragOver = false

    private let cardRadius: CGFloat = 18
    private let cardPadding: CGFloat = 28

    private var cardBorder: some ShapeStyle {
        theme.textSecondary.opacity(0.10)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "book.closed")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.dotActive)
                Text("Library")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Text("\(feedsVM.books.count) books")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
            }

            if feedsVM.books.isEmpty {
                emptyDropZone
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        compactDropZone
                        ForEach(Array(feedsVM.books.enumerated()), id: \.element.id) { index, book in
                            bookCard(book: book, index: index)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .padding(.vertical, cardPadding + 6)
        .padding(.horizontal, cardPadding + 4)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(theme.screenBackground)
        .clipShape(RoundedRectangle(cornerRadius: cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cardRadius)
                .stroke(cardBorder, lineWidth: 1)
        )
    }

    // MARK: - Empty Drop Zone

    private var emptyDropZone: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(isDragOver ? theme.dotActive.opacity(0.15) : theme.dotInactive.opacity(0.2))
            .frame(height: 80)
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 20))
                        .foregroundStyle(isDragOver ? theme.dotActive : theme.textSecondary)
                    Text("Drop .epub files here")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isDragOver) { providers in
                handleDrop(providers: providers)
            }
            .animation(.easeInOut(duration: 0.2), value: isDragOver)
    }

    // MARK: - Compact Drop Zone

    private var compactDropZone: some View {
        Button {
            browseForEpubs()
        } label: {
            RoundedRectangle(cornerRadius: 12)
                .fill(isDragOver ? theme.dotActive.opacity(0.15) : theme.dotInactive.opacity(0.2))
                .frame(width: 100, height: 100)
                .overlay {
                    VStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(isDragOver ? theme.dotActive : theme.textSecondary)
                        Text("Add")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textSecondary)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: isDragOver)
        }
        .buttonStyle(.plain)
        .onDrop(of: [.fileURL], isTargeted: $isDragOver) { providers in
            handleDrop(providers: providers)
        }
    }

    // MARK: - Book Card

    private func bookCard(book: BookAsset, index: Int) -> some View {
        Button {
            feedsVM.selectBook(at: index)
        } label: {
            VStack(alignment: .center, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.dotInactive.opacity(0.3))
                        .frame(width: 76, height: 76)

                    if book.hasCover, let coverImage = loadCoverImage(for: book) {
                        Image(nsImage: coverImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 76, height: 76)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        Image(systemName: "book")
                            .font(.system(size: 24))
                            .foregroundStyle(theme.textSecondary)
                    }

                    progressRing(percent: book.progressPercent)
                        .frame(width: 76, height: 76)
                }

                Text(book.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Text("\(book.progressPercent)%")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.textSecondary)
            }
            .frame(width: 84)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Remove", role: .destructive) {
                feedsVM.removeBook(at: index)
            }
        }
    }

    private func loadCoverImage(for book: BookAsset) -> NSImage? {
        guard let coverFileName = book.coverFileName else { return nil }
        let coverURL = BookStorage.bookURL(for: coverFileName)
        return NSImage(contentsOf: coverURL)
    }

    // MARK: - Progress Ring

    private func progressRing(percent: Int) -> some View {
        ZStack {
            Circle()
                .stroke(theme.dotInactive.opacity(0.3), lineWidth: 3)
            Circle()
                .trim(from: 0, to: CGFloat(percent) / 100.0)
                .stroke(theme.dotActive, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(percent)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(theme.textPrimary)
        }
    }

    // MARK: - Drop Handler

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        isDragOver = false
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async {
                    feedsVM.importEpub(from: url)
                }
            }
        }
        return true
    }

    // MARK: - File Browser

    private func browseForEpubs() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "epub")].compactMap { $0 }
        panel.prompt = "Add Books"
        panel.message = "Select epub files to add to your library"

        let result = panel.runModal()
        if result == .OK {
            for url in panel.urls {
                feedsVM.importEpub(from: url)
            }
        }
    }
}
