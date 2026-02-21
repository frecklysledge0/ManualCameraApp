import SwiftUI
import CoreImage

struct HistogramView: View {
    let data: [Float]
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                Rectangle()
                    .fill(Color.black.opacity(0.4))
                    .border(Color.white, width: 1)
                
                if !data.isEmpty {
                    Path { path in
                        let w = geometry.size.width
                        let h = geometry.size.height
                        
                        let stepX = w / CGFloat(data.count)
                        
                        path.move(to: CGPoint(x: 0, y: h))
                        for i in 0..<data.count {
                            let x = CGFloat(i) * stepX
                            // Prevent overflowing the box, capping at 0.95 of height
                            let y = h - (CGFloat(data[i]) * h * 0.95)
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                        path.addLine(to: CGPoint(x: w, y: h))
                        path.closeSubpath()
                    }
                    .fill(Color.white.opacity(0.8))
                } else {
                    Text("Histogram")
                        .font(.caption2)
                        .foregroundColor(.white)
                        .position(x: geometry.size.width/2, y: geometry.size.height/2)
                }
            }
        }
    }
}

import CoreImage.CIFilterBuiltins
import Metal
import AVFoundation

class ImagePipelineProcessor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let context: CIContext
    
    // Callbacks to main thread / CameraManager
    var onPeakingUpdate: ((UIImage?) -> Void)?
    var onHistogramUpdate: (([Float]) -> Void)?
    
    var isPeakingEnabled = false
    var isHistogramEnabled = true
    
    override init() {
        if let metalDevice = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: metalDevice)
        } else {
            context = CIContext()
        }
        super.init()
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
        
        // 1. Histogram Processing
        if isHistogramEnabled {
            if let histData = generateHistogram(from: ciImage) {
                onHistogramUpdate?(histData)
            }
        }
        
        // 2. Peaking Processing
        if isPeakingEnabled {
            if let peakImg = generatePeaking(from: ciImage) {
                onPeakingUpdate?(peakImg)
            }
        } else {
            onPeakingUpdate?(nil)
        }
    }
    
    private func generatePeaking(from ciImage: CIImage) -> UIImage? {
        let edges = CIFilter.edges()
        edges.inputImage = ciImage
        edges.intensity = 5.0
        guard let edgeOutput = edges.outputImage else { return nil }
        
        let mask = CIFilter.maskToAlpha()
        mask.inputImage = edgeOutput
        guard let maskOutput = mask.outputImage else { return nil }
        
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

    private func generateHistogram(from ciImage: CIImage) -> [Float]? {
        // Convert to grayscale first so R=G=B=Luma, making histogram generation purely luminance based
        let mono = CIFilter.colorControls()
        mono.inputImage = ciImage
        mono.saturation = 0.0
        guard let monoImage = mono.outputImage else { return nil }
        
        let areaHistogram = CIFilter.areaHistogram()
        areaHistogram.inputImage = monoImage
        areaHistogram.extent = monoImage.extent
        areaHistogram.count = 256
        areaHistogram.scale = 1.0

        guard let histOutput = areaHistogram.outputImage else { return nil }
        
        var bitmap = [Float](repeating: 0, count: 256 * 4) // RGBAf
        context.render(histOutput, toBitmap: &bitmap, rowBytes: 256 * 4 * MemoryLayout<Float>.size, bounds: CGRect(x: 0, y: 0, width: 256, height: 1), format: .RGBAf, colorSpace: nil)
        
        var result = [Float](repeating: 0, count: 256)
        var maxVal: Float = 0.0001
        
        // We rendered RGBA floats. Since we desaturated, picking the R channel is sufficient for luma frequency.
        for i in 0..<256 {
            let frequency = bitmap[i * 4] // Extract Red channel
            result[i] = frequency
            if frequency > maxVal { maxVal = frequency }
        }
        
        // Normalize the graph values between 0.0 and 1.0 based on the maximum bin peak
        for i in 0..<256 {
            result[i] = result[i] / maxVal
        }
        
        return result
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
