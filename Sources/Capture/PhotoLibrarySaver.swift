import AVFoundation
import ImageIO
import Photos
import UIKit

/// Saves a `CaptureItem` as **one** Photos asset: the processed image is the `.photo` resource and
/// the DNG is the `.alternatePhoto`, moved (not copied) into the library (F4). When Photos add access
/// is denied the files go to the app's Documents folder instead (§11).
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
        if let rawURL {
          // In PhotoKit, for a RAW+processed asset, .photo represents the RAW image
          // and .alternatePhoto represents the companion JPEG/HEIF preview image.
          // This ensures Photos app displays the RAW badge and treats it as a RAW photo.
          let rawOptions = PHAssetResourceCreationOptions()
          rawOptions.shouldMoveFile = true
          rawOptions.uniformTypeIdentifier = "com.adobe.raw-image"
          request.addResource(with: .photo, fileURL: rawURL, options: rawOptions)

          if let processedData {
            let processedOptions = PHAssetResourceCreationOptions()
            processedOptions.uniformTypeIdentifier = processedType
            request.addResource(
              with: .alternatePhoto, data: processedData, options: processedOptions)
          }
        } else if let processedData {
          let options = PHAssetResourceCreationOptions()
          options.uniformTypeIdentifier = processedType
          request.addResource(with: .photo, data: processedData, options: options)
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
}
