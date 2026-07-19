import AppKit
import Foundation
import Quartz

@MainActor
final class ClipboardHistoryService {
    private let pasteboard = NSPasteboard.general
    private var timer: Timer?
    private var screenshotRefreshTask: Task<Void, Never>?
    private var lastChangeCount = -1
    private var screenshotScanTick = 0
    private var isScreenshotDiscoveryEnabled = false
    private var knownScreenshotURLs: Set<URL> = []
    private(set) var entries: [ClipboardEntry] = []

    var onEntriesChange: (([ClipboardEntry]) -> Void)?

    func start() {
        guard timer == nil else { return }
        captureIfChanged()
        timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.captureIfChanged()
                self.screenshotScanTick += 1
                if self.isScreenshotDiscoveryEnabled,
                   self.screenshotScanTick >= 5 {
                    self.screenshotScanTick = 0
                    self.refreshRecentScreenshots()
                }
            }
        }
    }

    func enableScreenshotDiscovery() {
        guard !isScreenshotDiscoveryEnabled else { return }
        isScreenshotDiscoveryEnabled = true
        screenshotScanTick = 0
        refreshRecentScreenshots()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        screenshotRefreshTask?.cancel()
        screenshotRefreshTask = nil
        isScreenshotDiscoveryEnabled = false
        screenshotScanTick = 0
        knownScreenshotURLs.removeAll()
        lastChangeCount = -1
        guard !entries.isEmpty else { return }
        entries.removeAll()
        onEntriesChange?(entries)
    }

    func copy(_ entries: [ClipboardEntry]) {
        guard !entries.isEmpty else { return }
        pasteboard.clearContents()
        let objects: [any NSPasteboardWriting] = entries.flatMap { entry -> [any NSPasteboardWriting] in
            switch entry.payload {
            case .text(let text):
                return [text as NSString]
            case .image(let data):
                guard let image = NSImage(data: data) else { return [] }
                return [image]
            case .files(let urls):
                return urls.map { $0 as NSURL }
            }
        }
        pasteboard.writeObjects(objects)
        lastChangeCount = pasteboard.changeCount
    }

    func deleteTextEntries(withIDs ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let previousCount = entries.count
        entries.removeAll { ids.contains($0.id) && $0.isText }
        guard entries.count != previousCount else { return }
        onEntriesChange?(entries)
    }

    func clearTextHistory() {
        let previousCount = entries.count
        entries.removeAll { $0.isText }
        guard entries.count != previousCount else { return }
        onEntriesChange?(entries)
    }

    private func captureIfChanged() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard let payload = readPayload() else { return }

        if entries.first?.payload == payload { return }
        entries.insert(ClipboardEntry(id: UUID(), payload: payload, createdAt: .now), at: 0)
        if entries.count > 30 {
            entries.removeLast(entries.count - 30)
        }
        onEntriesChange?(entries)
    }

    private func refreshRecentScreenshots() {
        guard screenshotRefreshTask == nil else { return }
        let directory = screenshotDirectory
        screenshotRefreshTask = Task { [weak self] in
            let screenshots = await Task.detached(priority: .utility) {
                Self.discoverRecentScreenshots(in: directory)
            }.value

            guard let self else { return }
            self.screenshotRefreshTask = nil
            guard !Task.isCancelled else { return }
            self.mergeRecentScreenshots(screenshots)
        }
    }

    nonisolated static func discoverRecentScreenshots(in directory: URL) -> [(URL, Date)] {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .creationDateKey,
            .contentModificationDateKey
        ]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return Array(urls.compactMap { url -> (URL, Date)? in
            let name = url.deletingPathExtension().lastPathComponent.lowercased()
            let supportedExtension = ["png", "jpg", "jpeg", "heic", "tif", "tiff"]
                .contains(url.pathExtension.lowercased())
            guard supportedExtension,
                  name.hasPrefix("screenshot") || name.hasPrefix("screen shot"),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { return nil }
            return (url.standardizedFileURL, values.creationDate ?? values.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.1 > $1.1 }
        .prefix(15))
    }

    private func mergeRecentScreenshots(_ screenshots: [(URL, Date)]) {
        var didChange = false
        for (url, date) in screenshots.reversed() where !knownScreenshotURLs.contains(url) {
            knownScreenshotURLs.insert(url)
            entries.insert(
                ClipboardEntry(id: UUID(), payload: .files([url]), createdAt: date),
                at: 0
            )
            didChange = true
        }

        guard didChange else { return }
        entries.sort { $0.createdAt > $1.createdAt }
        if entries.count > 30 {
            entries.removeLast(entries.count - 30)
        }
        onEntriesChange?(entries)
    }

    private var screenshotDirectory: URL {
        let preference = UserDefaults.standard
            .persistentDomain(forName: "com.apple.screencapture")?["location"] as? String
        if let preference, !preference.isEmpty {
            return URL(filePath: (preference as NSString).expandingTildeInPath, directoryHint: .isDirectory)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Desktop", directoryHint: .isDirectory)
    }

    private func readPayload() -> ClipboardPayload? {
        let fileOptions: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: fileOptions) as? [URL],
           !urls.isEmpty {
            return .files(Array(urls.prefix(20)))
        }

        if let image = pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage,
           let data = image.tiffRepresentation,
           data.count <= 20_000_000 {
            return .image(data)
        }

        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            return .text(String(text.prefix(100_000)))
        }

        return nil
    }
}

@MainActor
final class ClipboardQuickLookService: NSObject, @preconcurrency QLPreviewPanelDataSource {
    private let previewDirectory: URL
    private var previewURLs: [URL] = []

    override init() {
        previewDirectory = FileManager.default.temporaryDirectory
            .appending(path: "Ledge-QuickLook-\(UUID().uuidString)", directoryHint: .isDirectory)
        super.init()
        try? FileManager.default.createDirectory(
            at: previewDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: previewDirectory)
    }

    func preview(_ entries: [ClipboardEntry]) {
        previewURLs = entries.flatMap(materialize)
        guard !previewURLs.isEmpty else { return }

        let panel = QLPreviewPanel.shared()
        panel?.dataSource = self
        panel?.currentPreviewItemIndex = 0
        panel?.reloadData()
        panel?.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURLs.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        guard previewURLs.indices.contains(index) else { return nil }
        return previewURLs[index] as NSURL
    }

    private func materialize(_ entry: ClipboardEntry) -> [URL] {
        switch entry.payload {
        case .files(let urls):
            return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        case .image(let data):
            let url = previewDirectory.appending(path: "Screenshot-\(entry.id.uuidString).tiff")
            do {
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: url.path
                )
                return [url]
            } catch {
                return []
            }
        case .text(let text):
            let url = previewDirectory.appending(path: "Clipboard-\(entry.id.uuidString).txt")
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: url.path
                )
                return [url]
            } catch {
                return []
            }
        }
    }
}
