import AVFoundation

/// A lens the user can pick. `zoom` is relative to the main (wide) camera.
struct LensOption: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let kind: LensKind
    let zoom: Double

    var isFront: Bool { kind == .front }
    var buttonText: String { LensMath.buttonText(for: zoom) }
}

/// Discovers the physical lenses once (§8) and computes their real zoom labels, so the
/// telephoto shows 4× or 5× (or anything else) depending on the phone.
final class DeviceCatalog: @unchecked Sendable {

    let backLenses: [LensOption]
    let frontLens: LensOption?
    private let devices: [String: AVCaptureDevice]

    init() {
        let back = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
            mediaType: .video,
            position: .back
        ).devices
        let front = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .front
        ).devices.first

        var lookup: [String: AVCaptureDevice] = [:]
        for device in back { lookup[device.uniqueID] = device }
        if let front { lookup[front.uniqueID] = front }
        devices = lookup

        let zooms = Self.zoomFactors(for: back)
        backLenses = back.compactMap { device -> LensOption? in
            guard let kind = Self.kind(of: device) else { return nil }
            return LensOption(id: device.uniqueID, kind: kind, zoom: zooms[device.uniqueID] ?? 1)
        }
        .sorted { $0.zoom < $1.zoom }

        frontLens = front.map { LensOption(id: $0.uniqueID, kind: .front, zoom: 1) }
    }

    var allLenses: [LensOption] {
        backLenses + (frontLens.map { [$0] } ?? [])
    }

    /// The main camera, or whatever exists.
    var defaultLens: LensOption? {
        backLenses.first(where: { $0.kind == .wide }) ?? backLenses.first ?? frontLens
    }

    func device(for lens: LensOption) -> AVCaptureDevice? {
        devices[lens.id]
    }

    func lens(withID id: String) -> LensOption? {
        allLenses.first(where: { $0.id == id })
    }

    /// The first lens of `kind`, used when restoring a saved lens (unique IDs can change).
    func lens(kind: LensKind) -> LensOption? {
        allLenses.first(where: { $0.kind == kind })
    }

    // MARK: - Zoom labels

    private static func kind(of device: AVCaptureDevice) -> LensKind? {
        if device.position == .front { return .front }
        switch device.deviceType {
        case .builtInUltraWideCamera: return .ultraWide
        case .builtInWideAngleCamera: return .wide
        case .builtInTelephotoCamera: return .telephoto
        default: return nil
        }
    }

    /// Reads the virtual device's switch-over factors, which match the labels in Apple's Camera app.
    /// Falls back to the field-of-view ratio when no suitable virtual device exists.
    private static func zoomFactors(for lenses: [AVCaptureDevice]) -> [String: Double] {
        var result: [String: Double] = [:]
        let byType = Dictionary(lenses.map { ($0.deviceType, $0) }, uniquingKeysWith: { first, _ in first })

        let candidates: [(AVCaptureDevice.DeviceType, [AVCaptureDevice.DeviceType], Bool)] = [
            (.builtInTripleCamera, [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera], true),
            (.builtInDualWideCamera, [.builtInUltraWideCamera, .builtInWideAngleCamera], true),
            (.builtInDualCamera, [.builtInWideAngleCamera, .builtInTelephotoCamera], false)
        ]
        for (virtualType, constituents, hasUltraWide) in candidates {
            guard let virtual = AVCaptureDevice.default(virtualType, for: .video, position: .back) else { continue }
            let factors = virtual.virtualDeviceSwitchOverVideoZoomFactors.map { $0.doubleValue }
            let labels = LensMath.zoomLabels(switchOverFactors: factors, hasUltraWide: hasUltraWide)
            guard labels.count == constituents.count else { continue }
            for (type, label) in zip(constituents, labels) {
                if let device = byType[type], result[device.uniqueID] == nil {
                    result[device.uniqueID] = label
                }
            }
        }

        // Anything still unlabelled: field-of-view heuristic against the wide camera.
        if let wide = byType[.builtInWideAngleCamera] {
            let wideFOV = Double(wide.activeFormat.videoFieldOfView)
            for device in lenses where result[device.uniqueID] == nil {
                result[device.uniqueID] = LensMath.zoomFromFieldOfView(
                    lensFOV: Double(device.activeFormat.videoFieldOfView),
                    wideFOV: wideFOV
                )
            }
        }
        return result
    }
}
