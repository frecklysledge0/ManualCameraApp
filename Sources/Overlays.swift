import SwiftUI
import CoreImage

struct HistogramView: View {
    let pixelBuffer: CVPixelBuffer?
    
    var body: some View {
        GeometryReader { geometry in
            // Render histogram here based on pixel buffer
            // To keep this lightweight, we generate a mock or basic luminance bar
            // Actual core image histogram processing is GPU intensive if not done via CIContext
            
            Rectangle()
                .fill(Color.black.opacity(0.4))
                .border(Color.white, width: 1)
                .overlay(
                    Text("Histogram")
                        .font(.caption2)
                        .foregroundColor(.white)
                )
        }
    }
}

import CoreImage.CIFilterBuiltins
import Metal

class PeakingProcessor {
    static let shared = PeakingProcessor()
    private let context: CIContext
    
    init() {
        if let metalDevice = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: metalDevice)
        } else {
            context = CIContext()
        }
    }
    
    func process(pixelBuffer: CVPixelBuffer) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        
        // 1. Edge Detection to find sharp details
        let edges = CIFilter.edges()
        edges.inputImage = ciImage
        edges.intensity = 5.0
        guard let edgeOutput = edges.outputImage else { return nil }
        
        // 2. Convert Black background to transparent Alpha
        let mask = CIFilter.maskToAlpha()
        mask.inputImage = edgeOutput
        guard let maskOutput = mask.outputImage else { return nil }
        
        // 3. Tint the white edges strictly Green
        let tint = CIFilter.colorMatrix()
        tint.inputImage = maskOutput
        tint.rVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        tint.gVector = CIVector(x: 0, y: 1, z: 0, w: 0)
        tint.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        tint.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        
        guard let tintedOutput = tint.outputImage,
              let cgImage = context.createCGImage(tintedOutput, from: tintedOutput.extent) else { return nil }
        
        return UIImage(cgImage: cgImage)
    }
}

struct FocusPeakingView: View {
    let peakingImage: UIImage?
    var isActive: Bool
    
    var body: some View {
        if isActive, let peakingImage = peakingImage {
            Image(uiImage: peakingImage)
                .resizable()
                .scaledToFit()
                .opacity(0.8)
                .allowsHitTesting(false)
        }
    }
}

struct GridOverlayView: View {
    @ObservedObject var motionManager: MotionManager
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Rule of Thirds
                Path { path in
                    let w = geometry.size.width
                    let h = geometry.size.height
                    
                    path.move(to: CGPoint(x: w/3, y: 0))
                    path.addLine(to: CGPoint(x: w/3, y: h))
                    
                    path.move(to: CGPoint(x: 2*w/3, y: 0))
                    path.addLine(to: CGPoint(x: 2*w/3, y: h))
                    
                    path.move(to: CGPoint(x: 0, y: h/3))
                    path.addLine(to: CGPoint(x: w, y: h/3))
                    
                    path.move(to: CGPoint(x: 0, y: 2*h/3))
                    path.addLine(to: CGPoint(x: w, y: 2*h/3))
                }
                .stroke(Color.white.opacity(0.5), lineWidth: 1)
                
                // Tilt-meter (Level)
                let rollDeg = motionManager.roll * 180 / .pi
                let isLevel = abs(rollDeg) < 2.0
                
                Rectangle()
                    .fill(isLevel ? Color.green : Color.yellow)
                    .frame(width: 100, height: 2)
                    .rotationEffect(.degrees(-rollDeg))
                    .animation(.linear(duration: 0.1), value: rollDeg)
            }
        }
    }
}
