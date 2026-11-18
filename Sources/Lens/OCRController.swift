import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers
@preconcurrency import Vision
import KeyboardShortcuts

@MainActor
final class OCRController: ObservableObject {
    static let shared = OCRController()

    enum State: Equatable {
        case idle
        case capturing
        case recognizing
        case done
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastCopiedSnippet: String?

    private var resetWorkItem: DispatchWorkItem?

    func registerHotkey() {
        KeyboardShortcuts.onKeyDown(for: .captureText) { [weak self] in
            self?.captureAndRecognize()
        }
    }

    func captureAndRecognize() {
        guard state != .capturing, state != .recognizing else { return }
        state = .capturing

        let pasteboard = NSPasteboard.general
        let priorChangeCount = pasteboard.changeCount

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -i: interactive region selection (the same marquee UI as ⌘⇧4)
        // -c: write the result to the clipboard as an image instead of a file
        process.arguments = ["-i", "-c"]

        // Set before run(): the process could in principle finish before we'd
        // otherwise get around to assigning the handler.
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.handleCaptureFinished(priorChangeCount: priorChangeCount)
            }
        }

        do {
            try process.run()
        } catch {
            fail("Couldn't launch screencapture: \(error.localizedDescription)")
        }
    }

    private func handleCaptureFinished(priorChangeCount: Int) {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != priorChangeCount,
              let image = pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            // User pressed Esc / cancelled the selection — no new image landed
            // on the pasteboard, so there's nothing to recognize.
            state = .idle
            return
        }

        state = .recognizing
        recognizeText(in: cgImage)
    }

    private func recognizeText(in cgImage: CGImage) {
        Task {
            do {
                deliver(try await Self.recognizeText(in: cgImage))
            } catch {
                fail("Recognition failed: \(error.localizedDescription)")
            }
        }
    }

    /// Copies the text in image or PDF files (from the Downloads grid) to
    /// the clipboard, with the same feedback as a screen capture.
    func copyText(fromFilesAt urls: [URL]) {
        guard !urls.isEmpty, state != .capturing, state != .recognizing else { return }
        state = .recognizing
        Task {
            var parts: [String] = []
            for url in urls {
                if let text = try? await Self.extractText(from: url), !text.isEmpty {
                    parts.append(text)
                }
            }
            deliver(parts.joined(separator: "\n\n"))
        }
    }

    private func deliver(_ text: String) {
        guard !text.isEmpty else {
            fail("No text found")
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        lastCopiedSnippet = Self.snippet(text)
        state = .done
        NSSound(named: "Tink")?.play()
        ToastPresenter.shared.show(systemImage: "checkmark.circle.fill", message: "Text Copied!")
        scheduleReset()
    }

    /// On-device Vision OCR, off the main thread.
    nonisolated static func recognizeText(in cgImage: CGImage) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
            let observations = request.results ?? []
            return observations.isEmpty ? "" : orderedText(from: observations)
        }.value
    }

    /// PDFs use their embedded text when they have it and fall back to OCR
    /// for scans (first 20 pages); images go straight to OCR.
    nonisolated static func extractText(from url: URL) async throws -> String {
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true {
            guard let document = PDFDocument(url: url) else { return "" }
            if let embedded = document.string?.trimmingCharacters(in: .whitespacesAndNewlines), !embedded.isEmpty {
                return embedded
            }
            var pages: [String] = []
            for index in 0..<min(document.pageCount, 20) {
                guard let page = document.page(at: index) else { continue }
                let bounds = page.bounds(for: .mediaBox)
                let image = page.thumbnail(of: NSSize(width: bounds.width * 2, height: bounds.height * 2), for: .mediaBox)
                guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
                let text = try await recognizeText(in: cgImage)
                if !text.isEmpty { pages.append(text) }
            }
            return pages.joined(separator: "\n\n")
        }

        // A transformed thumbnail applies EXIF orientation (iPhone photos)
        // and caps very large images at a size OCR still reads well.
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 4096,
              ] as CFDictionary) else { return "" }
        return try await recognizeText(in: cgImage)
    }

    /// Vision doesn't guarantee top-to-bottom reading order, so cluster
    /// observations into lines by vertical position (normalized coordinates,
    /// origin bottom-left) and sort each line left-to-right.
    nonisolated private static func orderedText(from observations: [VNRecognizedTextObservation]) -> String {
        let averageHeight = observations.map(\.boundingBox.height).reduce(0, +) / CGFloat(observations.count)
        let lineThreshold = max(averageHeight * 0.6, 0.01)

        let sorted = observations.sorted { $0.boundingBox.origin.y > $1.boundingBox.origin.y }

        var lines: [[VNRecognizedTextObservation]] = []
        for observation in sorted {
            if let lastIndex = lines.indices.last,
               let anchor = lines[lastIndex].first,
               abs(anchor.boundingBox.origin.y - observation.boundingBox.origin.y) < lineThreshold {
                lines[lastIndex].append(observation)
            } else {
                lines.append([observation])
            }
        }

        return lines
            .map { line in
                line.sorted { $0.boundingBox.origin.x < $1.boundingBox.origin.x }
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: " ")
            }
            .joined(separator: "\n")
    }

    private static func snippet(_ text: String, limit: Int = 60) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= limit ? trimmed : trimmed.prefix(limit) + "…"
    }

    private func fail(_ message: String) {
        state = .failed(message)
        ToastPresenter.shared.show(systemImage: "exclamationmark.triangle.fill", message: message)
        scheduleReset()
    }

    private func scheduleReset() {
        resetWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.state = .idle }
        resetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: workItem)
    }
}
