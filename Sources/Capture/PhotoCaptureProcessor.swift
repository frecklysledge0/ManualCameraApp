import Foundation

/// The parts of `AVCapturePhoto` the processor needs. `AVCapturePhoto` conforms in
/// `PhotoCaptureProcessor+AVFoundation.swift`; tests pass fakes.
protocol CapturedPhotoPayload {
    var isRawPhoto: Bool { get }
    func fileDataRepresentation() -> Data?
}

/// Saves one finished shot. The Photos implementation lives in `PhotoLibrarySaver.swift`.
protocol PhotoLibrarySaving: AnyObject {
    func save(_ item: CaptureItem, completion: @escaping (Result<SaveDestination, Error>) -> Void)
}

enum CaptureOutcome {
    /// Saved. `thumbnailSource` is the processed image, used for the gallery button; `bytes` is the
    /// shot's total size (for the shots-left estimate).
    case saved(SaveDestination, thumbnailSource: Data?, bytes: Int)
    /// Captured but saving failed. The files are kept on disk for "Retry save".
    case savePending(Error)
    /// Nothing usable was captured.
    case failed(Error)
}

enum CaptureError: LocalizedError {
    case noPhotoData
    case rawWriteFailed(Error)

    var errorDescription: String? {
        switch self {
        case .noPhotoData: return "The camera returned no image."
        case .rawWriteFailed(let error): return "Could not write the RAW file: \(error.localizedDescription)"
        }
    }
}

/// One instance per shutter press (F4, §6.3). It collects the RAW and processed halves of a
/// capture and saves them as **one** Photos item, then reports exactly one outcome. The engine
/// keeps it in a dictionary keyed by `uniqueID` and removes it in `onFinish`, which is called on
/// every path (success, save failure, capture failure), so processors can't leak.
final class PhotoCaptureProcessor {

    let uniqueID: Int64
    let id: UUID
    let expectsRaw: Bool
    /// `systemUptime` at the shutter press, for press-to-capture latency logging.
    let pressTime: TimeInterval

    /// Called when the sensor exposure starts (`willCapturePhoto`): drives the screen flash.
    var onWillCapture: (() -> Void)?
    /// Called exactly once with the final outcome.
    var onFinish: ((PhotoCaptureProcessor, CaptureOutcome) -> Void)?
    /// Optional development step that replaces the processed image (used by the Edition in Slice 3).
    /// It runs on the photo output's callback queue; errors fall back to the unmodified item.
    var develop: ((CaptureItem) throws -> CaptureItem)?

    private let saver: PhotoLibrarySaving
    private let store: CaptureFileStoring
    private var item: CaptureItem
    private var firstError: Error?
    private var finished = false
    private let lock = NSLock()

    init(
        uniqueID: Int64,
        expectsRaw: Bool,
        processedType: String,
        pressTime: TimeInterval,
        saver: PhotoLibrarySaving,
        store: CaptureFileStoring,
        id: UUID = UUID()
    ) {
        self.uniqueID = uniqueID
        self.expectsRaw = expectsRaw
        self.pressTime = pressTime
        self.saver = saver
        self.store = store
        self.id = id
        self.item = CaptureItem(id: id, processedData: nil, processedType: processedType, rawFileURL: nil)
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    // MARK: - Delegate events (forwarded by the AVFoundation extension)

    func handleWillCapture() {
        onWillCapture?()
    }

    func handleProcessedPhoto(_ photo: CapturedPhotoPayload?, error: Error?) {
        if let error {
            recordError(error)
        }
        guard let photo, let data = photo.fileDataRepresentation() else {
            if error == nil { recordError(CaptureError.noPhotoData) }
            return
        }
        if photo.isRawPhoto {
            do {
                // Write the DNG straight to disk and let the large Data go out of scope.
                item.rawFileURL = try store.writeRaw(data, for: id)
            } catch {
                recordError(CaptureError.rawWriteFailed(error))
            }
        } else {
            item.processedData = data
        }
    }

    func handleCaptureFinished(error: Error?) {
        if let error { recordError(error) }

        guard !item.isEmpty else {
            store.remove(id)
            finish(.failed(firstError ?? CaptureError.noPhotoData))
            return
        }

        var toSave = item
        if let develop {
            do {
                toSave = try develop(item)
            } catch {
                toSave = item
            }
        }
        item = toSave
        let bytes = Self.size(of: toSave)

        saver.save(toSave) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let destination):
                if destination == .photoLibrary {
                    self.store.remove(self.id)
                }
                self.finish(.saved(destination, thumbnailSource: toSave.processedData, bytes: bytes))
            case .failure(let saveError):
                do {
                    try self.store.persistPending(toSave)
                } catch {
                    // Nothing more can be done; the original error is reported.
                }
                self.finish(.savePending(saveError))
            }
        }
    }

    // MARK: - Private

    /// Processed bytes plus the DNG's size on disk (read before Photos moves the file).
    static func size(of item: CaptureItem) -> Int {
        var total = item.processedData?.count ?? 0
        if let url = item.rawFileURL,
           let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attributes[.size] as? NSNumber {
            total += size.intValue
        }
        return total
    }

    private func recordError(_ error: Error) {
        lock.lock()
        if firstError == nil { firstError = error }
        lock.unlock()
    }

    private func finish(_ outcome: CaptureOutcome) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()

        // Release the image data held by this processor.
        item = CaptureItem(id: id, processedData: nil, processedType: item.processedType, rawFileURL: nil)
        let callback = onFinish
        onFinish = nil
        onWillCapture = nil
        develop = nil
        callback?(self, outcome)
    }
}
