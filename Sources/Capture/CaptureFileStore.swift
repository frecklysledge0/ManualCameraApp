import Foundation

/// One shot on its way to the photo library.
struct CaptureItem: Sendable {
    let id: UUID
    /// Processed image (HEIF, or JPEG when HEVC is unavailable).
    var processedData: Data?
    /// Uniform type identifier of `processedData`, e.g. `public.heic`.
    var processedType: String
    /// DNG written to disk so the large RAW `Data` does not stay in memory.
    var rawFileURL: URL?

    var isEmpty: Bool { processedData == nil && rawFileURL == nil }
}

/// Where a saved shot ended up.
enum SaveDestination: Equatable, Sendable {
    case photoLibrary
    /// Photos access was denied, so the files went to the app's Documents folder (§11).
    case documents(URL)
}

/// Owns the on-disk staging area for captures: `Application Support/Captures/<id>/`.
///
/// - The DNG is written here as soon as it arrives.
/// - On a successful save the folder is deleted (Photos moved the DNG out with `shouldMoveFile`).
/// - When a save fails the processed data is written beside it with a manifest, so the shot can be
///   retried later, even after a relaunch.
protocol CaptureFileStoring: AnyObject {
    func writeRaw(_ data: Data, for id: UUID) throws -> URL
    func persistPending(_ item: CaptureItem) throws
    func remove(_ id: UUID)
    func pendingItems() -> [CaptureItem]
    /// Deletes folders left behind by a crash mid-capture (no manifest, older than a few minutes).
    func removeOrphans()
    /// Copies a shot into the user-visible Documents folder (Photos access denied).
    func exportToDocuments(_ item: CaptureItem) throws -> URL
}

final class CaptureFileStore: CaptureFileStoring {

    private let fileManager: FileManager
    let rootURL: URL
    let documentsURL: URL
    private static let manifestName = "manifest.json"
    /// Folders without a manifest older than this are leftovers from a crash.
    var orphanAge: TimeInterval = 600

    private struct Manifest: Codable {
        var id: UUID
        var processedType: String
        var hasProcessed: Bool
        var hasRaw: Bool
        var createdAt: Date
    }

    init(fileManager: FileManager = .default, rootURL: URL? = nil, documentsURL: URL? = nil) {
        self.fileManager = fileManager
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.rootURL = rootURL ?? support.appendingPathComponent("Captures", isDirectory: true)
        self.documentsURL = documentsURL
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
    }

    private func folder(for id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func ensureFolder(for id: UUID) throws -> URL {
        let url = folder(for: id)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func writeRaw(_ data: Data, for id: UUID) throws -> URL {
        let url = try ensureFolder(for: id).appendingPathComponent("raw.dng")
        try data.write(to: url, options: .atomic)
        return url
    }

    func persistPending(_ item: CaptureItem) throws {
        let folderURL = try ensureFolder(for: item.id)
        if let data = item.processedData {
            try data.write(to: folderURL.appendingPathComponent(Self.processedFileName(for: item.processedType)), options: .atomic)
        }
        let manifest = Manifest(
            id: item.id,
            processedType: item.processedType,
            hasProcessed: item.processedData != nil,
            hasRaw: item.rawFileURL.map { fileManager.fileExists(atPath: $0.path) } ?? false,
            createdAt: Date()
        )
        let encoded = try JSONEncoder().encode(manifest)
        try encoded.write(to: folderURL.appendingPathComponent(Self.manifestName), options: .atomic)
    }

    func remove(_ id: UUID) {
        try? fileManager.removeItem(at: folder(for: id))
    }

    func pendingItems() -> [CaptureItem] {
        guard let folders = try? fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) else {
            return []
        }
        var items: [CaptureItem] = []
        for folderURL in folders {
            let manifestURL = folderURL.appendingPathComponent(Self.manifestName)
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { continue }
            let processedURL = folderURL.appendingPathComponent(Self.processedFileName(for: manifest.processedType))
            let rawURL = folderURL.appendingPathComponent("raw.dng")
            var processedData: Data?
            if manifest.hasProcessed {
                processedData = try? Data(contentsOf: processedURL)
            }
            let item = CaptureItem(
                id: manifest.id,
                processedData: processedData,
                processedType: manifest.processedType,
                rawFileURL: fileManager.fileExists(atPath: rawURL.path) ? rawURL : nil
            )
            if item.isEmpty {
                remove(manifest.id)
            } else {
                items.append(item)
            }
        }
        return items
    }

    func removeOrphans() {
        guard let folders = try? fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) else {
            return
        }
        let cutoff = Date().addingTimeInterval(-orphanAge)
        for folderURL in folders where !fileManager.fileExists(atPath: folderURL.appendingPathComponent(Self.manifestName).path) {
            // Leave recent folders alone: a capture may be writing into them right now.
            let created = (try? folderURL.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if created < cutoff {
                try? fileManager.removeItem(at: folderURL)
            }
        }
    }

    func exportToDocuments(_ item: CaptureItem) throws -> URL {
        try fileManager.createDirectory(at: documentsURL, withIntermediateDirectories: true)
        let stamp = Self.fileStamp(Date())
        let base = "IMG_\(stamp)_\(item.id.uuidString.prefix(4))"
        var firstURL: URL?
        if let data = item.processedData {
            let url = documentsURL.appendingPathComponent(base).appendingPathExtension(Self.fileExtension(for: item.processedType))
            try data.write(to: url, options: .atomic)
            firstURL = url
        }
        if let rawURL = item.rawFileURL, fileManager.fileExists(atPath: rawURL.path) {
            let destination = documentsURL.appendingPathComponent(base).appendingPathExtension("dng")
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: rawURL, to: destination)
            firstURL = firstURL ?? destination
        }
        remove(item.id)
        guard let result = firstURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        return result
    }

    static func fileExtension(for type: String) -> String {
        switch type {
        case "public.jpeg": return "jpg"
        case "public.heic", "public.heif": return "heic"
        default: return "heic"
        }
    }

    static func processedFileName(for type: String) -> String {
        "photo." + fileExtension(for: type)
    }

    static func fileStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: date)
    }
}
