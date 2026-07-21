//
//  MiniReaderView.swift
//  Cella
//
//  Sentence-by-sentence reader with navigation controls.
//

import SwiftUI

struct MiniReaderView: View {
    @Environment(\.theme) private var theme
    var feedsVM: FeedsViewModel
    @State private var slideDirection: SlideDirection = .none

    private let cardRadius: CGFloat = 18
    private let cardPadding: CGFloat = 28

    private var cardBorder: some ShapeStyle {
        theme.textSecondary.opacity(0.10)
    }

    enum SlideDirection {
        case left, right, none
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if feedsVM.hasBook {
                readerContent
                navBar
            } else {
                emptyState
            }
        }
        .padding(.vertical, cardPadding + 6)
        .padding(.horizontal, cardPadding + 4)
        .frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
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
            Image(systemName: "text.alignleft")
                .font(.system(size: 13))
                .foregroundStyle(theme.dotActive)
            Text("Reader")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            Spacer()
            if feedsVM.currentPageNumber > 0 {
                Text("Page \(feedsVM.currentPageNumber)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
            }
            if feedsVM.totalPages > 0 {
                Text("\(feedsVM.currentPageIndex + 1)/\(feedsVM.totalPages)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }

    // MARK: - Reader Content

    private var readerContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let book = feedsVM.currentBook {
                Text(book.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.dotActive)
                    .lineLimit(1)
            }

            GeometryReader { geo in
                let size = geo.size
                ScrollView(.vertical, showsIndicators: false) {
                    Text(feedsVM.currentText)
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(theme.dotActive)
                        .lineSpacing(6)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .frame(width: size.width, height: size.height, alignment: .center)
                }
                .id(feedsVM.currentPageIndex)
                .transition(.asymmetric(
                    insertion: .offset(x: slideDirection == .left ? 60 : -60).combined(with: .opacity),
                    removal: .offset(x: slideDirection == .left ? -60 : 60).combined(with: .opacity)
                ))
                .animation(.easeInOut(duration: 0.25), value: feedsVM.currentPageIndex)
            }
            .frame(maxHeight: .infinity)

            if let book = feedsVM.currentBook, feedsVM.totalPages > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(theme.dotInactive.opacity(0.3))
                            .frame(height: 4)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(theme.dotActive)
                            .frame(width: geo.size.width * book.progress, height: 4)
                    }
                }
                .frame(height: 4)
                .animation(.easeInOut(duration: 0.25), value: feedsVM.currentPageIndex)
            }
        }
    }

    // MARK: - Navigation Bar

    private var navBar: some View {
        HStack(spacing: 12) {
            Button {
                slideDirection = .right
                withAnimation { feedsVM.previousPage() }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(feedsVM.canGoPrevious ? theme.textPrimary : theme.textSecondary)
                    .frame(width: 40, height: 32)
                    .background(theme.dotInactive.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(!feedsVM.canGoPrevious)

            Spacer()

            Text("\(feedsVM.currentPageIndex + 1) of \(feedsVM.totalPages)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.textSecondary)
                .animation(.easeInOut(duration: 0.25), value: feedsVM.currentPageIndex)

            Spacer()

            Button {
                slideDirection = .left
                withAnimation { feedsVM.nextPage() }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(feedsVM.canGoNext ? theme.textPrimary : theme.textSecondary)
                    .frame(width: 40, height: 32)
                    .background(theme.dotInactive.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(!feedsVM.canGoNext)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "book")
                .font(.system(size: 32))
                .foregroundStyle(theme.textSecondary)
            Text("No book selected")
                .font(.system(size: 13))
                .foregroundStyle(theme.textSecondary)
            Text("Drop an .epub file above")
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary.opacity(0.6))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
