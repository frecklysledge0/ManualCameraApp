import XCTest
@testable import ManualCameraApp

final class CaptureFileStoreTests: XCTestCase {

    private var root: URL!
    private var documents: URL!
    private var store: CaptureFileStore!

    override func setUp() {
        super.setUp()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("StoreTests-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("Captures", isDirectory: true)
        documents = base.appendingPathComponent("Documents", isDirectory: true)
        store = CaptureFileStore(rootURL: root, documentsURL: documents)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        super.tearDown()
    }

    func testPendingRoundTrip() throws {
        let id = UUID()
        let rawURL = try store.writeRaw(Data([1, 2, 3]), for: id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rawURL.path))

        let item = CaptureItem(id: id, processedData: Data([4, 5]), processedType: "public.heic", rawFileURL: rawURL)
        try store.persistPending(item)

        let pending = store.pendingItems()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.id, id)
        XCTAssertEqual(pending.first?.processedData, Data([4, 5]))
        XCTAssertEqual(pending.first?.rawFileURL?.lastPathComponent, "raw.dng")

        store.remove(id)
        XCTAssertTrue(store.pendingItems().isEmpty)
    }

    func testOrphansAreRemovedButPendingKept() throws {
        let orphan = UUID()
        _ = try store.writeRaw(Data([1]), for: orphan)
        let pendingID = UUID()
        try store.persistPending(CaptureItem(id: pendingID, processedData: Data([2]), processedType: "public.jpeg", rawFileURL: nil))

        store.orphanAge = 600
        store.removeOrphans()
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(orphan.uuidString).path), "Recent folders are kept")

        store.orphanAge = -1
        store.removeOrphans()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(orphan.uuidString).path))
        XCTAssertEqual(store.pendingItems().map(\.id), [pendingID])
    }

    func testExportToDocumentsMovesFiles() throws {
        let id = UUID()
        let rawURL = try store.writeRaw(Data([1]), for: id)
        let item = CaptureItem(id: id, processedData: Data([2]), processedType: "public.heic", rawFileURL: rawURL)
        let exported = try store.exportToDocuments(item)
        XCTAssertEqual(exported.pathExtension, "heic")
        let files = try FileManager.default.contentsOfDirectory(atPath: documents.path)
        XCTAssertEqual(files.filter { $0.hasSuffix(".heic") }.count, 1)
        XCTAssertEqual(files.filter { $0.hasSuffix(".dng") }.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rawURL.path))
    }

    func testFileNames() {
        XCTAssertEqual(CaptureFileStore.fileExtension(for: "public.jpeg"), "jpg")
        XCTAssertEqual(CaptureFileStore.fileExtension(for: "public.heic"), "heic")
        XCTAssertEqual(CaptureFileStore.processedFileName(for: "public.jpeg"), "photo.jpg")
    }
}
