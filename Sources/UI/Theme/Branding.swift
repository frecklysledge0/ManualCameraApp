import Foundation

/// Every user-facing product name lives here (roadmap "Naming and trademarks"). App Store builds
/// must keep these original. A personal build can change the strings freely.
enum Branding {
    static let appName = "ManualCameraApp"
    /// The default pro interface (inspired by Alpha-series camera bodies).
    static let standardThemeName = "Pro"
    /// The one-tap medium-format mode (Slice 3).
    static let editionName = "Medium Format Edition"
    static let editionShortName = "MF Edition"
    /// The Edition's colour look. An original look, not a reproduction of any vendor's science.
    static let lookName = "MF Natural Colour"
    /// EXIF `Software` tag for developed Edition photos.
    static let editionSoftwareTag = "ManualCameraApp — MF Natural Colour"
}
