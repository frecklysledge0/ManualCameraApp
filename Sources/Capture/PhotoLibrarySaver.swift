import AVFoundation
import ImageIO
import Photos
import UIKit

/// Saves a `CaptureItem` as **one** Photos asset (F4). The DNG is moved, not copied, into the
/// library. When Photos add access is denied the files go to the app's Documents folder (§11).
final class PhotoLibrarySaver: PhotoLibrarySaving {

  private let store: CaptureFileStoring

  init(store: CaptureFileStoring) {
    self.store = store
  }

  static var canAddToLibrary: Bool {
    let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    return status == .authorized || status == .limited
  }

  func save(_ item: CaptureItem, completion: @escaping (Result<SaveDestination, Error>) -> Void) {
    guard Self.canAddToLibrary else {
      do {
        let url = try store.exportToDocuments(item)
        completion(.success(.documents(url)))
      } catch {
        completion(.failure(error))
      }
      return
    }

    let processedData = item.processedData
    let processedType = item.processedType
    let rawURL = item.rawFileURL
    PHPhotoLibrary.shared().performChanges(
      {
        let request = PHAssetCreationRequest.forAsset()
        // PhotoKit's rules: the `.photo` resource is what Photos displays. A RAW-only shot
        // therefore uses the DNG as `.photo` (it then shows as a RAW / ProRAW photo, exactly like
        // Apple's Camera). A RAW+HEIF pair uses the HEIF as `.photo` and the DNG as
        // `.alternatePhoto` — the documented RAW+JPEG/HEIF pairing.
        let rawOptions = PHAssetResourceCreationOptions()
        rawOptions.shouldMoveFile = true
        rawOptions.uniformTypeIdentifier = "com.adobe.raw-image"
        switch (processedData, rawURL) {
        case (.some(let data), .some(let url)):
          let options = PHAssetResourceCreationOptions()
          options.uniformTypeIdentifier = processedType
          request.addResource(with: .photo, data: data, options: options)
          request.addResource(with: .alternatePhoto, fileURL: url, options: rawOptions)
        case (.none, .some(let url)):
          request.addResource(with: .photo, fileURL: url, options: rawOptions)
        case (.some(let data), .none):
          let options = PHAssetResourceCreationOptions()
          options.uniformTypeIdentifier = processedType
          request.addResource(with: .photo, data: data, options: options)
        case (.none, .none):
          break
        }
      },
      completionHandler: { success, error in
        if success {
          completion(.success(.photoLibrary))
        } else {
          completion(.failure(error ?? CocoaError(.fileWriteUnknown)))
        }
      })
  }
}

/// Small, correctly oriented thumbnails straight from encoded image data (no full decode).
enum ThumbnailMaker {
  static func thumbnail(from data: Data, maxPixelSize: Int = 180) -> UIImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      return nil
    }
    return UIImage(cgImage: image)
  }

  /// Thumbnail from a DNG on disk. Uses the embedded preview, so the RAW is never decoded.
  static func thumbnail(fromFileURL url: URL, maxPixelSize: Int = 180) -> UIImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      return nil
    }
    return UIImage(cgImage: image)
  }
}
