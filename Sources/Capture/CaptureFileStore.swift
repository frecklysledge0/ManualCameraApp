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

/// What one shutter press saves (Fn › Format).
enum CaptureFormat: String, Codable, CaseIterable, Sendable {
    /// Processed HEIF only (fastest).
    case heif
    /// Apple ProRAW (or Bayer RAW) DNG only — shows as a RAW / ProRAW photo in Photos.
    case raw
    /// A HEIF and a DNG from the same shot, saved as two separate photos.
    case rawPlusHEIF

    var includesRaw: Bool { self != .heif }
    var includesProcessed: Bool { self != .raw }

    var label: String {
        switch self {
        case .heif: return "HEIF"
        case .raw: return "RAW"
        case .rawPlusHEIF: return "RAW+HEIF"
        }
    }
}

/// Resolution of processed (HEIF) photos. RAW is always captured at the sensor's full resolution.
enum PhotoSize: String, Codable, CaseIterable, Sendable {
    case mp12
    case mp24
    case mp48

    var label: String {
        switch self {
        case .mp12: return "12 MP"
        case .mp24: return "24 MP"
        case .mp48: return "48 MP"
        }
    }

    /// Nominal pixel count (4032×3024, 5712×4284, 8064×6048).
    var pixels: Int {
        switch self {
        case .mp12: return 4032 * 3024
        case .mp24: return 5712 * 4284
        case .mp48: return 8064 * 6048
        }
    }
}

/// Picks capture dimensions and quality prioritization from the format's supported sizes
/// (WWDC26 "Implement high resolution photo capture"):
/// - 12 MP works at every prioritization; 48 MP needs `.balanced` or `.quality`; the fused 24 MP
///   needs `.quality`.
/// - A locked (custom) exposure is honoured exactly only with `.speed`, which caps photos at 12 MP.
///   By default the app keeps the resolution (24/48 MP) and lets iOS fine-tune a manual exposure;
///   "Exact manual exposure" chooses 12 MP with the exact values instead.
enum PhotoResolution {

    struct Choice: Equatable {
        var width: Int32
        var height: Int32
        var prioritization: Prioritization

        var pixels: Int { Int(width) * Int(height) }
    }

    /// Mirrors `AVCapturePhotoOutput.QualityPrioritization` (testable without AVFoundation).
    enum Prioritization: Int, Comparable, Sendable {
        case speed = 1
        case balanced = 2
        case quality = 3

        static func < (lhs: Prioritization, rhs: Prioritization) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// - Parameters:
    ///   - supported: the active format's `supportedMaxPhotoDimensions` as (width, height).
    ///   - format: what is captured. `.raw` and `.rawPlusHEIF` capture at full resolution
    ///     (a RAW+HEIF's HEIF is scaled to `heifSize` afterwards).
    ///   - bayerRaw: Bayer RAW is a single unfused frame at 12 MP.
    ///   - maxPrioritization: the output's `maxPhotoQualityPrioritization`.
    static func choose(
        supported: [(width: Int32, height: Int32)],
        format: CaptureFormat,
        heifSize: PhotoSize,
        customExposure: Bool,
        exactManualExposure: Bool,
        bayerRaw: Bool,
        maxPrioritization: Prioritization
    ) -> Choice {
        let sizes = supported.sorted { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }
        guard let smallest = sizes.first, let largest = sizes.last else {
            return Choice(width: 4032, height: 3024, prioritization: min(.balanced, maxPrioritization))
        }
        let twelve = sizes.last(where: { Int($0.width) * Int($0.height) <= PhotoSize.mp12.pixels + PhotoSize.mp12.pixels / 10 }) ?? smallest

        if bayerRaw && format.includesRaw {
            return Choice(width: twelve.width, height: twelve.height, prioritization: .speed)
        }
        if customExposure && exactManualExposure {
            return Choice(width: twelve.width, height: twelve.height, prioritization: .speed)
        }

        let target: (width: Int32, height: Int32)
        if format.includesRaw {
            target = largest
        } else {
            // The largest supported size up to the wanted one, so 24 MP falls back to 12 MP on
            // phones without the fused 24 MP size (never silently up to 48 MP files).
            let wanted = heifSize.pixels + heifSize.pixels / 10
            target = sizes.last(where: { Int($0.width) * Int($0.height) <= wanted }) ?? smallest
        }
        let pixels = Int(target.width) * Int(target.height)
        let isTwelve = pixels <= Int(twelve.width) * Int(twelve.height)
        let isFusedMid = !isTwelve && pixels < Int(largest.width) * Int(largest.height)
        var prioritization: Prioritization
        if isTwelve {
            prioritization = customExposure ? .speed : .balanced
        } else if isFusedMid {
            prioritization = .quality
        } else {
            prioritization = format.includesRaw ? .balanced : .quality
        }
        if prioritization > maxPrioritization {
            prioritization = maxPrioritization
        }
        // What the prioritization allows decides the size (48 MP needs ≥ balanced, 24 MP quality).
        if prioritization == .speed || (isFusedMid && prioritization < .quality) {
            return Choice(width: twelve.width, height: twelve.height, prioritization: prioritization)
        }
        return Choice(width: target.width, height: target.height, prioritization: prioritization)
    }
}
