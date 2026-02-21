# ManualCameraApp 📸

A high-performance iOS camera application built with **SwiftUI**, **AVFoundation**, and **Metal-accelerated CoreImage**. ManualCameraApp provides photographers with granular control over hardware optics, mirroring professional DSLR capabilities in a sleek, responsive interface.

## 🌟 Key Features

### 🎛 Full Manual Control
- **ISO:** Seamless dialing from deep shadows to high-gain physical hardware limits.
- **Shutter Speed:** Precise fraction-and-second adjustment (e.g., `1/120`, `0.5s`) for motion locking or long-exposure blurs.
- **Focus Depth:** Granular `.lensPosition` mapping with a true manual override that persists even through physical lens changes.
- **Exposure Target Bias (EV):** Live `.continuousAutoExposure` overrides for dynamic lighting scenarios ranging from `-2.0` to `+2.0`.
- **White Balance (WB):** Active hardware temperature clamping, scaling seamlessly from 3000K (Tungsten) up to 8000K (Shade).

### 🔍 Pro Overlays & Analytics
- **Live 3-Channel RGB Histogram:** The camera stream is ripped at 60fps and analyzed directly via `CIFilter.areaHistogram`. The custom-built processor dynamically renders discrete Red, Green, and Blue frequency bins overlapping each other via `blendMode(.screen)` to visualize accurate color-clipping limits live in the viewfinder.
- **Focus Peaking:** Sharp subject edges are highlighted in bright green by passing the frame buffer through a Custom Metal-backed CoreImage kernel (`CIFilter.edges()`). Offloaded exclusively onto a background `AVCaptureVideoDataOutput` thread to maintain 60FPS UI performance.
- **Rule of Thirds Grid:** A classic symmetrical 9-block grid overlay tracking device orientation vectors using CoreMotion.

### ⚡ Performance & UX
- **Zero-Latency Capture:** Optimized async threads capture raw 48MP ProRAW buffers without halting the main SwiftUI UI thread.
- **Haptic & Visual Feedback:** Immersive shutter captures triggered by a localized UI white-flash and dual-layer haptics (a firm `.medium` physical click, followed by a `.success` burst upon safely rendering the buffer into the `PHPhotoLibrary`).
- **Lens Persistence:** Seamless switching between the `0.5x` Ultra-Wide, `1x` Wide, and `5x` Telephoto hardware lenses while mathematically transferring the user's manual ISO, Shutter, Focus, and WB states.

## 🏗 Architecture & Code Structure

The app's logic is aggressively decoupled to ensure main-thread zero-lag UI responsiveness:

1. **`CameraView.swift`:** The pure SwiftUI frontend. Renders the interactive layout, overlays, slider rulers, and gesture logic.
2. **`CameraManager.swift`:** The hardware anchor. Manages `AVCaptureSession`, lifecycle queues, lens mutations, state snapshots, and pure camera hardware mutation protocols.
3. **`Overlays.swift (ImagePipelineProcessor)`:** Real-time data processing. Consumes the massive `CVPixelBuffer` stream completely off the main thread. Metal-accelerated instances analyze pixels for Focus Peaking masks and RGB Histogram values before bubbling them back up natively to `CameraView`.

## 🛠 Compilation Requirements
- **Xcode Version:** 15.0+
- **iOS Target:** iOS 17.0+
- **Access Profiles:** App must be dynamically granted `NSCameraUsageDescription` and `NSPhotoLibraryAddUsageDescription` capabilities via the info.plist (currently handled at app launch).
