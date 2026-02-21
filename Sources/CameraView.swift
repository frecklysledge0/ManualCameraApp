import SwiftUI

struct CameraView: View {
    @StateObject private var cameraManager = CameraManager()
    @StateObject private var motionManager = MotionManager()
    @Environment(\.scenePhase) var scenePhase
    
    // UI State
    @State private var activeMode: String = "A" // "M", "WB", "MF", "A"
    @State private var isFrontCamera: Bool = false
    @State private var showingHistogram: Bool = true
    
    // Tap to focus UI state
    @State private var focusPoint: CGPoint? = nil
    @State private var showFocusBox: Bool = false
    @State private var showGrid: Bool = false
    
    // Aesthetic Constants
    let hudColor = Color.black.opacity(0.6)
    let textGray = Color.white.opacity(0.8)
    
    // Computed safe ranges for sliders to prevent 0.0..<0.0 crash
    // Computed safe ranges for sliders to prevent 0.0..<0.0 crash
    private var safeSSRange: ClosedRange<Float> {
        let minSS = Float(max(cameraManager.minExposureDuration.seconds, 0.000001))
        let maxSS = Float(max(cameraManager.maxExposureDuration.seconds, 0.5))
        return minSS < maxSS ? (minSS...maxSS) : (0.001...0.5)
    }
    
    private var safeISORange: ClosedRange<Float> {
        let minISOVal = max(cameraManager.minISO, 1.0)
        let maxISOVal = max(cameraManager.maxISO, 100.0)
        return minISOVal < maxISOVal ? (minISOVal...maxISOVal) : (1.0...100.0)
    }
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            // 1. Viewfinder Layer
            GeometryReader { geometry in
                CameraPreviewView(session: cameraManager.session)
                    .ignoresSafeArea()
                    .gesture(
                        DragGesture(minimumDistance: 0).onEnded { value in
                            let point = value.location
                            let normalizedPoint = CGPoint(
                                x: point.y / geometry.size.height,
                                y: 1.0 - (point.x / geometry.size.width)
                            )
                            cameraManager.focusAtPoint(normalizedPoint)
                            
                            // Show UI Box
                            focusPoint = point
                            showFocusBox = true
                            
                            // Hide after delay
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                showFocusBox = false
                            }
                        }
                    )
                
                // Tap-to-focus box
                if let focusPoint = focusPoint, showFocusBox {
                    Rectangle()
                        .stroke(Color.yellow, lineWidth: 2)
                        .frame(width: 60, height: 60)
                        .position(focusPoint)
                        .animation(.easeOut(duration: 0.2), value: showFocusBox)
                }
            }
            .ignoresSafeArea()
            
            // 2. Optical Overlays
            if showGrid {
                GridOverlayView(motionManager: motionManager)
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
            }
            
            FocusPeakingView(peakingImage: cameraManager.peakingImage, isActive: activeMode == "MF")
                .allowsHitTesting(false)
                .ignoresSafeArea()
            
            // Central Focus Bracket / Reticle (Mimicking ProCamera)
            Image(systemName: "plus.viewfinder")
                .font(.system(size: 60, weight: .ultraLight))
                .foregroundColor(textGray)
                .opacity(0.5)
            
            // 3. HUD Controls Layer
            VStack {
                // --- TOP BAR ---
                HStack {
                    Button(action: { /* Toggle Flash */ }) {
                        Image(systemName: "bolt.slash.fill")
                            .font(.system(size: 20))
                            .foregroundColor(textGray)
                    }
                    
                    Spacer()
                    
                    // Shutter Speed Readout
                    HStack(spacing: 4) {
                        Image(systemName: "timer")
                            .font(.system(size: 12))
                        Text(formatShutterSpeed(cameraManager.currentShutterSpeed))
                            .font(.system(.subheadline, design: .monospaced))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(hudColor)
                    .cornerRadius(6)
                    
                    Spacer()
                    
                    // EV Control (Stub)
                    Button(action: { /* EV slider toggle */ }) {
                        Image(systemName: "plusminus.circle")
                            .font(.system(size: 22))
                            .foregroundColor(textGray)
                    }
                    
                    Spacer()
                    
                    // ISO Readout
                    HStack(spacing: 4) {
                        Text("ISO")
                            .font(.system(size: 10, weight: .bold))
                        Text("\(Int(cameraManager.currentISO))")
                            .font(.system(.subheadline, design: .monospaced))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(hudColor)
                    .cornerRadius(6)
                    
                    Spacer()
                    
                    Button(action: { cameraManager.toggleFrontCamera() }) {
                        Image(systemName: "arrow.triangle.2.circlepath.camera")
                            .font(.system(size: 20))
                            .foregroundColor(textGray)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                
                // --- TOP MIDDLE: Histogram ---
                if showingHistogram {
                    HistogramView(data: cameraManager.histogramData)
                        .frame(width: 80, height: 40)
                        .padding(.top, 8)
                }
                
                Spacer()
                
                // --- BOTTOM CONTROLS STACK ---
                VStack(spacing: 15) {
                    
                    // Row 1: Mode Selectors (A, M, EV, WB, MF)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 30) {
                            Spacer(minLength: 10)
                            TextModeButton(title: "AUTO", mode: "A", current: $activeMode)
                            TextModeButton(title: "MANUAL", mode: "M", current: $activeMode)
                            TextModeButton(title: "EV", mode: "EV", current: $activeMode)
                            TextModeButton(title: "WB", mode: "WB", current: $activeMode)
                            TextModeButton(title: "FOCUS", mode: "MF", current: $activeMode)
                            Spacer(minLength: 10)
                        }
                    }
                    .padding(.bottom, 5)
                    
                    // Row 2: Toggles & Lens
                    HStack(spacing: 20) {
                        CapsuleTextButton(title: "RAW", isSelected: true, color: .white)
                        CapsuleTextButton(title: "HDR", isSelected: false, color: .gray)
                        
                        Spacer()
                        
                        // Lens Switcher (0.5x, 1x, 5x)
                        HStack(spacing: 0) {
                            LensButton(title: ".5", value: 0.5, current: cameraManager.selectedLens) {
                                cameraManager.switchLens(factor: 0.5)
                            }
                            LensButton(title: "1", value: 1.0, current: cameraManager.selectedLens) {
                                cameraManager.switchLens(factor: 1.0)
                            }
                            LensButton(title: "5x", value: 5.0, current: cameraManager.selectedLens) {
                                cameraManager.switchLens(factor: 5.0)
                            }
                        }
                        .background(hudColor)
                        .cornerRadius(15)
                    }
                    .padding(.horizontal, 25)
                    
                    // Row 2: Active Mode Sliders
                    if activeMode == "M" {
                        // Dual scrubbing area representation
                        VStack(spacing: 5) {
                            HorizontalRulerSlider(value: Binding(
                                get: { Float(cameraManager.currentShutterSpeed) },
                                set: { newValue in
                                    cameraManager.currentShutterSpeed = Double(newValue)
                                    cameraManager.updateExposure(iso: cameraManager.currentISO, shutterSpeed: Double(newValue))
                                }
                            ), range: safeSSRange, label: "SS")
                            
                            HorizontalRulerSlider(value: Binding(
                                get: { cameraManager.currentISO },
                                set: { newValue in
                                    cameraManager.currentISO = newValue
                                    cameraManager.updateExposure(iso: newValue, shutterSpeed: cameraManager.currentShutterSpeed)
                                }
                            ), range: safeISORange, label: "ISO")
                        }
                        .padding(.bottom, 10)
                    } else if activeMode == "EV" || activeMode == "A" {
                        HorizontalRulerSlider(value: Binding(
                            get: { cameraManager.currentEV },
                            set: { newValue in
                                cameraManager.currentEV = newValue
                                cameraManager.updateEV(bias: newValue)
                            }
                        ), range: cameraManager.minEV...cameraManager.maxEV, label: "EV")
                        .padding(.bottom, 10)
                    } else if activeMode == "WB" {
                        HorizontalRulerSlider(value: Binding(
                            get: { cameraManager.currentWB },
                            set: { newValue in
                                cameraManager.currentWB = newValue
                                cameraManager.updateWhiteBalance(temperature: newValue)
                            }
                        ), range: 3000.0...8000.0, label: "WB")
                        .padding(.bottom, 10)
                    } else if activeMode == "MF" {
                        HorizontalRulerSlider(value: Binding(
                            get: { cameraManager.currentFocus },
                            set: { newValue in
                                cameraManager.currentFocus = newValue
                                cameraManager.updateFocus(lensPosition: newValue)
                            }
                        ), range: 0.0...1.0, label: "FOCUS")
                        .padding(.bottom, 10)
                    }
                    
                    // --- SHUTTER BAR ---
                    HStack {
                        // Left: Gallery Thumbnail Placeholder
                        Button(action: {
                            if let url = URL(string: "photos-redirect://") {
                                UIApplication.shared.open(url, options: [:], completionHandler: nil)
                            }
                        }) {
                            Rectangle()
                                .fill(Color.gray.opacity(0.3))
                                .frame(width: 50, height: 50)
                                .cornerRadius(8)
                                .overlay(Image(systemName: "photo.on.rectangle").foregroundColor(.white))
                        }
                        
                        Spacer()
                        
                        // Center: Primary Shutter
                        Button(action: {
                            cameraManager.capturePhoto()
                        }) {
                            ZStack {
                                Circle()
                                    .fill(Color.white)
                                    .frame(width: 76, height: 76)
                                Circle()
                                    .stroke(Color.black, lineWidth: 2)
                                    .frame(width: 70, height: 70)
                            }
                        }
                        
                        Spacer()
                        
                        // Right: Settings Grid / Overlays
                        Button(action: { showGrid.toggle() }) {
                            Image(systemName: "circle.grid.3x3.fill")
                                .font(.system(size: 24))
                                .foregroundColor(showGrid ? .yellow : textGray)
                                .frame(width: 50, height: 50)
                        }
                    }
                    .padding(.horizontal, 30)
                    .padding(.bottom, 20)
                }
                .background(
                    LinearGradient(gradient: Gradient(colors: [Color.black.opacity(0.0), Color.black.opacity(0.8)]), startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea()
                )
            }
        }
        .onAppear {
            if !cameraManager.isSessionRunning {
                cameraManager.startSession()
            }
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                cameraManager.startSession()
            } else if newPhase == .background || newPhase == .inactive {
                cameraManager.stopSession()
            }
        }
        .onChange(of: activeMode) { newMode in
            cameraManager.isPeakingEnabled = (newMode == "MF")
            if newMode == "A" {
                cameraManager.setModeAuto()
            }
        }
    }
}

// Format shutter speed to readable fractions
func formatShutterSpeed(_ duration: Double) -> String {
    if duration >= 1.0 {
        return String(format: "%.1fs", duration)
    } else {
        return String(format: "1/%.0f", 1.0 / duration)
    }
}

// MARK: - Reusable UI Subcomponents

struct CapsuleTextButton: View {
    let title: String
    let isSelected: Bool
    let color: Color
    
    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: isSelected ? .bold : .medium))
            .foregroundColor(isSelected ? .black : color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(isSelected ? color : Color.clear)
            .overlay(
                Capsule().stroke(color, lineWidth: 1)
            )
            .cornerRadius(12)
    }
}

struct LensButton: View {
    let title: String
    let value: Double
    let current: Double
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: current == value ? .bold : .medium))
                .foregroundColor(.white)
                .frame(width: 38, height: 30)
                .background(current == value ? Color.white.opacity(0.3) : Color.clear)
                .clipShape(Capsule())
        }
    }
}

struct TextModeButton: View {
    let title: String
    let mode: String
    @Binding var current: String
    
    var body: some View {
        Button(action: { current = mode }) {
            Text(title)
                .font(.system(size: 13, weight: current == mode ? .bold : .medium))
                .foregroundColor(current == mode ? Color(hue: 0.12, saturation: 0.8, brightness: 0.9) : .white.opacity(0.7))
        }
    }
}

// A simple horizontal scrubber representation matching ProCamera's visual style.
struct HorizontalRulerSlider: View {
    @Binding var value: Float
    let range: ClosedRange<Float>
    let label: String
    
    var body: some View {
        HStack(spacing: 15) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.yellow)
                .frame(width: 40, alignment: .leading)
            
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Tick marks background
                    HStack(spacing: geo.size.width / 20) {
                        ForEach(0..<20) { i in
                            Rectangle()
                                .fill(Color.white.opacity(i % 5 == 0 ? 0.6 : 0.3))
                                .frame(width: 1, height: i % 5 == 0 ? 12 : 6)
                        }
                    }
                    
                    // Thumb
                    let sliderRatio = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
                    let thumbX = min(max(sliderRatio * geo.size.width, 0), geo.size.width)
                    
                    Rectangle()
                        .fill(Color.yellow)
                        .frame(width: 2, height: 20)
                        .offset(x: thumbX)
                }
                .frame(height: 20)
                // Scrubbing logic
                .gesture(
                    DragGesture()
                        .onChanged { out in
                            let ratio = Float(out.location.x / geo.size.width)
                            let clamped = max(min(ratio, 1.0), 0.0)
                            value = range.lowerBound + (clamped * (range.upperBound - range.lowerBound))
                        }
                )
            }
            .frame(height: 20)
            
            // Value Readout
            Text(String(format: "%.1f", value))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.horizontal, 20)
    }
}

// Boilerplate init to bind Double ranges
extension HorizontalRulerSlider {
    init(value: Binding<Double>, range: ClosedRange<Double>, label: String) {
        let floatBinding = Binding<Float>(
            get: { Float(value.wrappedValue) },
            set: { value.wrappedValue = Double($0) }
        )
        let floatRange = Float(range.lowerBound)...Float(range.upperBound)
        self.init(value: floatBinding, range: floatRange, label: label)
    }
}
