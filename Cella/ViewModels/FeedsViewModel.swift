//
//  FeedsViewModel.swift
//  Cella
//
//  Book management, reading state, water reminder timer.
//

import Foundation
import UserNotifications

@Observable
final class FeedsViewModel {

    // MARK: - Books

    var books: [BookAsset] = []
    var currentBookIndex: Int? = nil
    var currentPages: [String] = []
    var currentPageNumbers: [Int] = []
    var currentPageIndex: Int = 0

    var currentBook: BookAsset? {
        guard let index = currentBookIndex, books.indices.contains(index) else { return nil }
        return books[index]
    }

    var currentText: String {
        guard currentPages.indices.contains(currentPageIndex) else { return "" }
        return currentPages[currentPageIndex]
    }

    var currentPageNumber: Int {
        guard currentPageNumbers.indices.contains(currentPageIndex) else { return 0 }
        return currentPageNumbers[currentPageIndex]
    }

    var totalPages: Int {
        return currentPages.count
    }

    var hasBook: Bool { currentBook != nil }
    var canGoPrevious: Bool { currentPageIndex > 0 }
    var canGoNext: Bool { currentPageIndex < currentPages.count - 1 }

    // MARK: - Water Reminder

    var waterIntervalMinutes: Int = 60
    var waterTimerActive: Bool = false
    var waterTimeRemaining: TimeInterval = 0

    private var waterTimer: Timer?

    // MARK: - Init

    init() {
        books = BookStorage.loadLibrary()
        requestNotificationPermission()
    }

    // MARK: - Book Management

    func importEpub(from sourceURL: URL) {
        guard sourceURL.pathExtension.lowercased() == "epub" else { return }
        guard !books.contains(where: { $0.fileName == sourceURL.lastPathComponent }) else { return }

        do {
            let destURL = try BookStorage.copyToLibrary(from: sourceURL)
            if let parsed = EpubParser.parse(url: destURL) {
                var coverFileName: String? = nil
                if let coverURL = parsed.coverURL {
                    coverFileName = saveCoverImage(from: coverURL, for: destURL.lastPathComponent)
                }

                var book = BookAsset(
                    fileName: destURL.lastPathComponent,
                    title: parsed.title,
                    author: parsed.author,
                    totalSentences: parsed.pages.count,
                    coverFileName: coverFileName
                )
                books.append(book)
                BookStorage.saveLibrary(books)

                if currentBookIndex == nil {
                    selectBook(at: books.count - 1)
                }
            }
        } catch {
            print("Failed to import epub: \(error)")
        }
    }

    private func saveCoverImage(from sourceURL: URL, for bookFileName: String) -> String? {
        guard let imageData = try? Data(contentsOf: sourceURL) else { return nil }
        let coverName = bookFileName.replacingOccurrences(of: ".epub", with: "_cover")
        let ext = sourceURL.pathExtension.isEmpty ? "jpg" : sourceURL.pathExtension
        let coverFileName = "\(coverName).\(ext)"
        let coverURL = BookStorage.bookURL(for: coverFileName)
        do {
            try imageData.write(to: coverURL)
            return coverFileName
        } catch {
            return nil
        }
    }

    func selectBook(at index: Int) {
        guard books.indices.contains(index) else { return }
        currentBookIndex = index
        currentPageIndex = books[index].lastSentenceIndex

        let url = BookStorage.bookURL(for: books[index].fileName)
        if let parsed = EpubParser.parse(url: url) {
            currentPages = parsed.pages
            currentPageNumbers = parsed.pageNumbers
        } else {
            currentPages = []
            currentPageNumbers = []
        }
    }

    func nextPage() {
        guard canGoNext else { return }
        currentPageIndex += 1
        saveProgress()
    }

    func previousPage() {
        guard canGoPrevious else { return }
        currentPageIndex -= 1
        saveProgress()
    }

    func removeBook(at index: Int) {
        guard books.indices.contains(index) else { return }
        let book = books[index]
        let url = BookStorage.bookURL(for: book.fileName)
        try? FileManager.default.removeItem(at: url)
        if let coverFileName = book.coverFileName {
            let coverURL = BookStorage.bookURL(for: coverFileName)
            try? FileManager.default.removeItem(at: coverURL)
        }
        books.remove(at: index)
        BookStorage.saveLibrary(books)

        if currentBookIndex == index {
            currentBookIndex = books.isEmpty ? nil : 0
            if let idx = currentBookIndex {
                selectBook(at: idx)
            } else {
                currentPages = []
                currentPageNumbers = []
                currentPageIndex = 0
            }
        } else if let idx = currentBookIndex, idx > index {
            currentBookIndex = idx - 1
        }
    }

    private func saveProgress() {
        guard let index = currentBookIndex, books.indices.contains(index) else { return }
        books[index].lastSentenceIndex = currentPageIndex
        BookStorage.saveLibrary(books)
    }

    // MARK: - Water Reminder

    func startWaterTimer() {
        stopWaterTimer()
        waterTimerActive = true
        waterTimeRemaining = TimeInterval(waterIntervalMinutes * 60)

        waterTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickWaterTimer()
            }
        }
    }

    func stopWaterTimer() {
        waterTimer?.invalidate()
        waterTimer = nil
        waterTimerActive = false
        waterTimeRemaining = 0
    }

    func drinkWater() {
        stopWaterTimer()
    }

    private func tickWaterTimer() {
        guard waterTimeRemaining > 0 else {
            sendWaterNotification()
            waterTimeRemaining = TimeInterval(waterIntervalMinutes * 60)
            return
        }
        waterTimeRemaining -= 1
    }

    private func sendWaterNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Time to hydrate"
        content.body = "Drink some water to stay healthy."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "water-reminder",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}
