import Foundation

/// The physical lenses the app can switch between.
enum LensKind: String, Codable, CaseIterable, Sendable {
    case ultraWide
    case wide
    case telephoto
    case front
}

/// Pure zoom-label maths used by `DeviceCatalog`.
enum LensMath {

    /// Converts `virtualDeviceSwitchOverVideoZoomFactors` of a virtual multi-camera into
    /// per-lens zoom labels where the wide camera is 1×.
    ///
    /// The virtual device measures zoom relative to its widest constituent, so for a triple camera
    /// with factors `[2, 10]` the constituents sit at 1, 2 and 10. Dividing by the wide camera's factor
    /// gives `[0.5, 1, 5]`.
    ///
    /// - Parameters:
    ///   - switchOverFactors: The factors in ascending order (one fewer than the constituents).
    ///   - hasUltraWide: Whether the first constituent is an ultra-wide (true for triple and dual-wide).
    /// - Returns: One label per constituent, widest first, or an empty array when the input is unusable.
    static func zoomLabels(switchOverFactors: [Double], hasUltraWide: Bool) -> [Double] {
        let factors = switchOverFactors.filter { $0.isFinite && $0 > 0 }
        guard !factors.isEmpty, factors == factors.sorted() else { return [] }
        let constituents = [1.0] + factors
        let wideFactor = hasUltraWide ? constituents[1] : constituents[0]
        guard wideFactor > 0 else { return [] }
        return constituents.map { roundLabel($0 / wideFactor) }
    }

    /// Focal-length heuristic used when no virtual device is available:
    /// `zoom = tan(fovWide / 2) / tan(fovLens / 2)` with horizontal fields of view in degrees.
    static func zoomFromFieldOfView(lensFOV: Double, wideFOV: Double) -> Double {
        guard lensFOV > 0, lensFOV < 180, wideFOV > 0, wideFOV < 180 else { return 1 }
        let wide = tan(wideFOV * .pi / 360)
        let lens = tan(lensFOV * .pi / 360)
        guard lens > 0 else { return 1 }
        return roundLabel(wide / lens)
    }

    /// Rounds a zoom factor to one decimal and snaps values within 0.05 of an integer.
    static func roundLabel(_ zoom: Double) -> Double {
        guard zoom.isFinite, zoom > 0 else { return 1 }
        let nearestInteger = zoom.rounded()
        if nearestInteger >= 1, abs(zoom - nearestInteger) < 0.05 { return nearestInteger }
        return (zoom * 10).rounded() / 10
    }

    /// Text shown on a lens button: `.5`, `1`, `2`, `5`, `2.5`.
    static func buttonText(for zoom: Double) -> String {
        guard zoom.isFinite, zoom > 0 else { return "1" }
        if zoom < 1 {
            let tenths = Int((zoom * 10).rounded())
            return ".\(tenths)"
        }
        if abs(zoom - zoom.rounded()) < 0.05 {
            return "\(Int(zoom.rounded()))"
        }
        return String(format: "%.1f", zoom)
    }
}
