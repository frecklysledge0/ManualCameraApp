import XCTest
@testable import ManualCameraApp

/// F4 and §6.3: one shutter press → exactly one Photos item with both resources, the temp DNG is
/// cleaned up, and the processor reports exactly once and is released on every path.
final class PhotoCaptureProcessorTests: XCTestCase {

    private func makeProcessor(saver: FakeSaver, store: FakeStore, expectsRaw: Bool = true) -> PhotoCaptureProcessor {
        PhotoCaptureProcessor(
            uniqueID: 42,
            expectsRaw: expectsRaw,
            processedType: "public.heic",
            pressTime: 0,
            saver: saver,
            store: store
        )
    }

    func testRawPlusHEIFSavesOneItemWithBothResources() throws {
        let saver = FakeSaver()
        let store = FakeStore()
        let processor = makeProcessor(saver: saver, store: store)
        var outcomes: [CaptureOutcome] = []
        processor.onFinish = { _, outcome in outcomes.append(outcome) }

        processor.handleProcessedPhoto(FakePhoto(isRawPhoto: true, data: Data([1, 2, 3])), error: nil)
        processor.handleProcessedPhoto(FakePhoto(isRawPhoto: false, data: Data([9, 9])), error: nil)
        processor.handleCaptureFinished(error: nil)

        XCTAssertEqual(saver.savedItems.count, 1, "Exactly one asset request")
        let item = try XCTUnwrap(saver.savedItems.first)
        XCTAssertEqual(item.processedData, Data([9, 9]))
        XCTAssertEqual(item.processedType, "public.heic")
        let rawURL = try XCTUnwrap(item.rawFileURL)
        XCTAssertEqual(rawURL.pathExtension, "dng")

        XCTAssertEqual(outcomes.count, 1)
        guard case .saved(.photoLibrary, let thumbnailSource, let bytes) = outcomes.first else {
            return XCTFail("Expected a saved outcome")
        }
        XCTAssertEqual(thumbnailSource, Data([9, 9]))
        XCTAssertEqual(bytes, 5, "2 processed bytes + 3 RAW bytes")
        XCTAssertEqual(store.removed, [processor.id], "Temp folder removed after a successful save")
        XCTAssertFalse(FileManager.default.fileExists(atPath: rawURL.path), "Temp DNG removed")
        XCTAssertTrue(processor.isFinished)
    }

    func testHEIFOnly() throws {
        let saver = FakeSaver()
        let store = FakeStore()
        let processor = makeProcessor(saver: saver, store: store, expectsRaw: false)
        processor.handleProcessedPhoto(FakePhoto(isRawPhoto: false, data: Data([7])), error: nil)
        processor.handleCaptureFinished(error: nil)
        let item = try XCTUnwrap(saver.savedItems.first)
        XCTAssertNil(item.rawFileURL)
        XCTAssertEqual(item.processedData, Data([7]))
    }

    func testSaveFailureKeepsFilesForRetry() {
        let saver = FakeSaver()
        saver.result = .failure(FakeError())
        let store = FakeStore()
        let processor = makeProcessor(saver: saver, store: store)
        var outcomes: [CaptureOutcome] = []
        processor.onFinish = { _, outcome in outcomes.append(outcome) }

        processor.handleProcessedPhoto(FakePhoto(isRawPhoto: true, data: Data([1])), error: nil)
        processor.handleProcessedPhoto(FakePhoto(isRawPhoto: false, data: Data([2])), error: nil)
        processor.handleCaptureFinished(error: nil)

        XCTAssertEqual(outcomes.count, 1)
        guard case .savePending = outcomes.first else { return XCTFail("Expected savePending") }
        XCTAssertEqual(store.persisted.count, 1)
        XCTAssertEqual(store.persisted.first?.processedData, Data([2]))
        XCTAssertTrue(store.removed.isEmpty, "Files are kept when saving fails")
    }

    func testCaptureErrorWithoutDataFailsWithoutSaving() {
        let saver = FakeSaver()
        let store = FakeStore()
        let processor = makeProcessor(saver: saver, store: store)
        var outcomes: [CaptureOutcome] = []
        processor.onFinish = { _, outcome in outcomes.append(outcome) }

        processor.handleProcessedPhoto(nil, error: FakeError(code: 7))
        processor.handleCaptureFinished(error: FakeError(code: 8))

        XCTAssertTrue(saver.savedItems.isEmpty)
        XCTAssertEqual(outcomes.count, 1)
        guard case .failed(let error) = outcomes.first else { return XCTFail("Expected failed") }
        XCTAssertEqual(error as? FakeError, FakeError(code: 7), "The first error is reported")
        XCTAssertEqual(store.removed, [processor.id])
    }

    func testRawHalfStillSavedWhenProcessedHalfFails() throws {
        let saver = FakeSaver()
        let store = FakeStore()
        let processor = makeProcessor(saver: saver, store: store)
        processor.handleProcessedPhoto(FakePhoto(isRawPhoto: true, data: Data([1])), error: nil)
        processor.handleProcessedPhoto(nil, error: FakeError())
        processor.handleCaptureFinished(error: nil)
        let item = try XCTUnwrap(saver.savedItems.first)
        XCTAssertNotNil(item.rawFileURL)
        XCTAssertNil(item.processedData)
    }

    func testRawWriteFailureStillSavesProcessed() throws {
        let saver = FakeSaver()
        let store = FakeStore()
        store.failRawWrites = true
        let processor = makeProcessor(saver: saver, store: store)
        processor.handleProcessedPhoto(FakePhoto(isRawPhoto: true, data: Data([1])), error: nil)
        processor.handleProcessedPhoto(FakePhoto(isRawPhoto: false, data: Data([2])), error: nil)
        processor.handleCaptureFinished(error: nil)
        let item = try XCTUnwrap(saver.savedItems.first)
        XCTAssertNil(item.rawFileURL)
        XCTAssertEqual(item.processedData, Data([2]))
    }

    func testFinishIsReportedOnlyOnce() {
        let saver = FakeSaver()
        let store = FakeStore()
        let processor = makeProcessor(saver: saver, store: store)
        var count = 0
        processor.onFinish = { _, _ in count += 1 }
        processor.handleProcessedPhoto(FakePhoto(isRawPhoto: false, data: Data([1])), error: nil)
        processor.handleCaptureFinished(error: nil)
        processor.handleCaptureFinished(error: nil)
        XCTAssertEqual(count, 1)
    }

    func testProcessorIsReleasedOnSuccessAndOnError() {
        for failing in [false, true] {
            let saver = FakeSaver()
            if failing { saver.result = .failure(FakeError()) }
            let store = FakeStore()
            weak var weakProcessor: PhotoCaptureProcessor?
            do {
                let processor = makeProcessor(saver: saver, store: store)
                weakProcessor = processor
                processor.onFinish = { finished, _ in _ = finished.uniqueID }
                processor.handleProcessedPhoto(FakePhoto(isRawPhoto: true, data: Data([1])), error: nil)
                processor.handleProcessedPhoto(FakePhoto(isRawPhoto: false, data: Data([2])), error: nil)
                processor.handleCaptureFinished(error: nil)
            }
            XCTAssertNil(weakProcessor, "Processor leaked (failing: \(failing))")
        }
    }

    func testDevelopHookReplacesProcessedImage() throws {
        let saver = FakeSaver()
        let store = FakeStore()
        let processor = makeProcessor(saver: saver, store: store)
        processor.develop = { item in
            var developed = item
            developed.processedData = Data([0xAA])
            return developed
        }
        processor.handleProcessedPhoto(FakePhoto(isRawPhoto: false, data: Data([1])), error: nil)
        processor.handleCaptureFinished(error: nil)
        XCTAssertEqual(try XCTUnwrap(saver.savedItems.first).processedData, Data([0xAA]))
    }

    func testFailingDevelopFallsBackToOriginal() throws {
        let saver = FakeSaver()
        let store = FakeStore()
        let processor = makeProcessor(saver: saver, store: store)
        processor.develop = { _ in throw FakeError() }
        processor.handleProcessedPhoto(FakePhoto(isRawPhoto: false, data: Data([1])), error: nil)
        processor.handleCaptureFinished(error: nil)
        XCTAssertEqual(try XCTUnwrap(saver.savedItems.first).processedData, Data([1]))
    }
}
