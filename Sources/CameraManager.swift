import AVFoundation
import SwiftUI
import Photos
import Combine
import CoreImage
import UIKit


class CameraManager: NSObject, ObservableObject {
    @Published var session = AVCaptureSession()
    @Published var isSessionRunning = false
    
    // Manual Settings
    @Published var currentISO: Float = 100
    @Published var currentShutterSpeed: Double = 1.0 / 60.0
    @Published var currentFocus: Float = 0.5
    @Published var currentFocalLength: Double = 24.0
    @Published var currentWB: Float = 5000.0 // Added WB
    @Published var currentEV: Float = 0.0 // Added EV
    
    @Published var peakingImage: UIImage?
    @Published var isPeakingEnabled: Bool = false
    @Published var isFrontCamera: Bool = false
    
    // Lens Selection
    @Published var selectedLens: Double = 1.0 // 0.5, 1.0, 5.0
    
    // Limits
    @Published var minISO: Float = 0
    @Published var maxISO: Float = 0
    @Published var minExposureDuration = CMTime()
    @Published var maxExposureDuration = CMTime()
    @Published var minEV: Float = -2.0
    @Published var maxEV: Float = 2.0
    
    private let photoOutput = AVCapturePhotoOutput()
    private var videoDeviceInput: AVCaptureDeviceInput?
    private let sessionQueue = DispatchQueue(label: "camera.sessionQueue")
    
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let videoDataQueue = DispatchQueue(label: "camera.videoDataQueue", qos: .userInteractive)
    
    override init() {
        super.init()
        checkPermissions()
    }
    
    private func checkPermissions() {
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        
        if cameraStatus == .notDetermined {
            sessionQueue.suspend()
            AVCaptureDevice.requestAccess(for: .video) { _ in
                self.sessionQueue.resume()
                self.checkPhotoPermissionsAndSetup()
            }
        } else {
            checkPhotoPermissionsAndSetup()
        }
    }
    
    // Check Photo Permissions Once at App Launch
    private func checkPhotoPermissionsAndSetup() {
        if #available(iOS 14, *) {
            let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            if status == .notDetermined {
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in
                    self.setupSession()
                }
            } else {
                self.setupSession()
            }
        } else {
            let status = PHPhotoLibrary.authorizationStatus()
            if status == .notDetermined {
                PHPhotoLibrary.requestAuthorization { _ in
                    self.setupSession()
                }
            } else {
                self.setupSession()
            }
        }
    }
    
    private func setupSession() {
        sessionQueue.async {
            self.session.beginConfiguration()
            
            // 1. Initialize AVCaptureSession with sessionPreset = .photo
            self.session.sessionPreset = .photo
            
            // Use discrete wide angle camera instead of triple camera because virtual cameras block custom manual exposure mode!
            guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                self.session.commitConfiguration()
                return
            }
            
            do {
                let videoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)
                if self.session.canAddInput(videoDeviceInput) {
                    self.session.addInput(videoDeviceInput)
                    self.videoDeviceInput = videoDeviceInput
                    
                    DispatchQueue.main.async {
                        self.minISO = videoDevice.activeFormat.minISO
                        self.maxISO = videoDevice.activeFormat.maxISO
                        self.minExposureDuration = videoDevice.activeFormat.minExposureDuration
                        self.maxExposureDuration = videoDevice.activeFormat.maxExposureDuration
                        self.minEV = videoDevice.minExposureTargetBias
                        self.maxEV = videoDevice.maxExposureTargetBias
                        self.currentISO = self.minISO
                        if let format = videoDevice.activeFormat.supportedColorSpaces.first {
                            print("Supported Colorspace", format)
                        }
                    }
                }
                
                // 2. Configure AVCapturePhotoOutput to support 48MP Apple ProRAW
                if self.session.canAddOutput(self.photoOutput) {
                    self.session.addOutput(self.photoOutput)
                    
                    if let maxDimensions = videoDevice.activeFormat.supportedMaxPhotoDimensions.last {
                        self.photoOutput.maxPhotoDimensions = maxDimensions
                    }
                    if self.photoOutput.isAppleProRAWSupported {
                        self.photoOutput.isAppleProRAWEnabled = true
                    }
                }
                
                // Add Video Data Output for Histogram & Focus Peaking
                if self.session.canAddOutput(self.videoDataOutput) {
                    self.session.addOutput(self.videoDataOutput)
                    self.videoDataOutput.setSampleBufferDelegate(self, queue: self.videoDataQueue)
                    self.videoDataOutput.alwaysDiscardsLateVideoFrames = true
                    self.videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
                }
                
                self.session.commitConfiguration()
                self.session.startRunning()
                
                DispatchQueue.main.async {
                    self.isSessionRunning = self.session.isRunning
                }
                
            } catch {
                print("Error setting up camera: \(error)")
                self.session.commitConfiguration()
            }
        }
    }
    
    // MARK: - Lifecycle Management
    
    func startSession() {
        sessionQueue.async {
            if !self.session.isRunning {
                self.session.startRunning()
                DispatchQueue.main.async {
                    self.isSessionRunning = true
                }
            }
        }
    }
    
    func stopSession() {
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
                DispatchQueue.main.async {
                    self.isSessionRunning = false
                }
            }
        }
    }
    
    // MARK: - Lens and Optics Control
    
    func switchLens(factor: Double) {
        // Snapshot main-thread variables to avoid race conditions inside the async queue
        let snappedISO = self.currentISO
        let snappedSS = self.currentShutterSpeed
        let snappedWB = self.currentWB
        let snappedEV = self.currentEV
        
        sessionQueue.async {
            self.session.beginConfiguration()
            
            if let currentInput = self.videoDeviceInput {
                self.session.removeInput(currentInput)
            }
            
            let deviceType: AVCaptureDevice.DeviceType
            if factor == 0.5 {
                deviceType = .builtInUltraWideCamera
            } else if factor == 5.0 {
                deviceType = .builtInTelephotoCamera
            } else {
                deviceType = .builtInWideAngleCamera
            }
            
            let newDevice: AVCaptureDevice
            if let device = AVCaptureDevice.default(deviceType, for: .video, position: .back) {
                newDevice = device
            } else if let fallback = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
                print("Requested lens \(factor)x not found (Simulator/Device Limit). Falling back to WideAngle.")
                newDevice = fallback
            } else {
                self.session.commitConfiguration()
                return
            }
            
            guard let newInput = try? AVCaptureDeviceInput(device: newDevice) else {
                self.session.commitConfiguration()
                return
            }
            
            if self.session.canAddInput(newInput) {
                self.session.addInput(newInput)
                self.videoDeviceInput = newInput
                
                // Update bindings for the new physical sensor limits
                DispatchQueue.main.async {
                    self.minISO = newDevice.activeFormat.minISO
                    self.maxISO = newDevice.activeFormat.maxISO
                    self.minExposureDuration = newDevice.activeFormat.minExposureDuration
                    self.maxExposureDuration = newDevice.activeFormat.maxExposureDuration
                    self.minEV = newDevice.minExposureTargetBias
                    self.maxEV = newDevice.maxExposureTargetBias
                    
                    self.currentISO = max(min(self.currentISO, self.maxISO), self.minISO)
                    let currentDur = CMTime(seconds: self.currentShutterSpeed, preferredTimescale: 1000000)
                    let safeDur = max(min(currentDur, self.maxExposureDuration), self.minExposureDuration)
                    self.currentShutterSpeed = safeDur.seconds
                    
                    self.selectedLens = factor
                }
            }
            
            self.session.commitConfiguration()
            
            // Reapply exposure using thread-safe snapshot variables
            self.updateExposure(iso: snappedISO, shutterSpeed: snappedSS)
            self.updateWhiteBalance(temperature: snappedWB)
            self.updateEV(bias: snappedEV)
        }
    }
    
    func toggleFrontCamera() {
        let snappedISO = self.currentISO
        let snappedSS = self.currentShutterSpeed
        let snappedWB = self.currentWB
        let snappedEV = self.currentEV
        
        sessionQueue.async {
            self.session.beginConfiguration()
            
            if let currentInput = self.videoDeviceInput {
                self.session.removeInput(currentInput)
            }
            
            let position: AVCaptureDevice.Position = self.isFrontCamera ? .back : .front
            let deviceType: AVCaptureDevice.DeviceType
            
            if position == .back {
                if self.selectedLens == 0.5 {
                    deviceType = .builtInUltraWideCamera
                } else if self.selectedLens == 5.0 {
                    deviceType = .builtInTelephotoCamera
                } else {
                    deviceType = .builtInWideAngleCamera
                }
            } else {
                deviceType = .builtInWideAngleCamera
            }
            
            guard let newDevice = AVCaptureDevice.default(deviceType, for: .video, position: position),
                  let newInput = try? AVCaptureDeviceInput(device: newDevice) else {
                self.session.commitConfiguration()
                return
            }
            
            if self.session.canAddInput(newInput) {
                self.session.addInput(newInput)
                self.videoDeviceInput = newInput
                
                DispatchQueue.main.async {
                    self.isFrontCamera.toggle()
                    
                    self.minISO = newDevice.activeFormat.minISO
                    self.maxISO = newDevice.activeFormat.maxISO
                    self.minExposureDuration = newDevice.activeFormat.minExposureDuration
                    self.maxExposureDuration = newDevice.activeFormat.maxExposureDuration
                    self.minEV = newDevice.minExposureTargetBias
                    self.maxEV = newDevice.maxExposureTargetBias
                    
                    self.currentISO = max(min(self.currentISO, self.maxISO), self.minISO)
                    let currentDur = CMTime(seconds: self.currentShutterSpeed, preferredTimescale: 1000000)
                    let safeDur = max(min(currentDur, self.maxExposureDuration), self.minExposureDuration)
                    self.currentShutterSpeed = safeDur.seconds
                }
            }
            
            self.session.commitConfiguration()
            
            self.updateExposure(iso: snappedISO, shutterSpeed: snappedSS)
            self.updateWhiteBalance(temperature: snappedWB)
            self.updateEV(bias: snappedEV)
        }
    }
    
    func setModeAuto() {
        sessionQueue.async {
            guard let device = self.videoDeviceInput?.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
                if device.exposureTargetBias != 0 {
                    device.setExposureTargetBias(0, completionHandler: nil)
                }
                device.unlockForConfiguration()
                
                DispatchQueue.main.async {
                    self.currentEV = 0
                }
            } catch {
                print("Failed to set auto mode")
            }
        }
    }
    
    // MARK: - Manual Controls
    
    func updateFocus(lensPosition: Float) {
        sessionQueue.async {
            guard let device = self.videoDeviceInput?.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusModeSupported(.locked) {
                    device.setFocusModeLocked(lensPosition: lensPosition, completionHandler: nil)
                }
                device.unlockForConfiguration()
                DispatchQueue.main.async {
                    self.currentFocus = lensPosition // Keep UI synced even if unsupported
                }
            } catch {
                print("Failed to lock for focus update")
            }
        }
    }
    
    func focusAtPoint(_ point: CGPoint) {
        sessionQueue.async {
            guard let device = self.videoDeviceInput?.device else { return }
            do {
                try device.lockForConfiguration()
                
                if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(.autoFocus) {
                    device.focusPointOfInterest = point
                    device.focusMode = .autoFocus
                }
                
                if device.isExposurePointOfInterestSupported && device.isExposureModeSupported(.autoExpose) {
                    device.exposurePointOfInterest = point
                    device.exposureMode = .autoExpose
                }
                
                device.isSubjectAreaChangeMonitoringEnabled = true
                device.unlockForConfiguration()
            } catch {
                print("Failed to lock for focus tap update")
            }
        }
    }
    
    func updateExposure(iso: Float, shutterSpeed: Double) {
        sessionQueue.async {
            guard let device = self.videoDeviceInput?.device else { return }
            do {
                try device.lockForConfiguration()
                
                let minI = device.activeFormat.minISO
                let maxI = device.activeFormat.maxISO
                let targetISO = (maxI > minI) ? max(min(iso, maxI), minI) : iso
                
                let minD = device.activeFormat.minExposureDuration
                let maxD = device.activeFormat.maxExposureDuration
                let duration = CMTime(seconds: shutterSpeed, preferredTimescale: 1000000)
                let targetDuration = (maxD.seconds > minD.seconds) ? max(min(duration, maxD), minD) : duration
                
                if device.isExposureModeSupported(.custom) {
                    device.setExposureModeCustom(duration: targetDuration, iso: targetISO, completionHandler: nil)
                } else {
                    print("Custom exposure not supported on this physical device!")
                }
                device.unlockForConfiguration()
                DispatchQueue.main.async {
                    // Update the UI representation regardless of hardware support for Simulator stability
                    self.currentISO = targetISO
                    self.currentShutterSpeed = targetDuration.seconds
                }
            } catch {
                print("Failed to lock for exposure update")
            }
        }
    }
    
    func updateWhiteBalance(temperature: Float) {
        sessionQueue.async {
            let safeTemp = max(min(temperature, 8000), 3000)
            guard let device = self.videoDeviceInput?.device else { return }
            do {
                try device.lockForConfiguration()
                let wbTempAndTint = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: safeTemp, tint: 0.0)
                let deviceGains = device.deviceWhiteBalanceGains(for: wbTempAndTint)
                
                let maxGain = device.maxWhiteBalanceGain
                let safeGains = AVCaptureDevice.WhiteBalanceGains(
                    redGain: max(1.0, min(deviceGains.redGain, maxGain)),
                    greenGain: max(1.0, min(deviceGains.greenGain, maxGain)),
                    blueGain: max(1.0, min(deviceGains.blueGain, maxGain))
                )
                
                if device.isWhiteBalanceModeSupported(.locked) {
                    device.setWhiteBalanceModeLocked(with: safeGains, completionHandler: nil)
                }
                
                device.unlockForConfiguration()
                DispatchQueue.main.async {
                    self.currentWB = safeTemp
                }
            } catch {
                print("Failed to lock for WB update")
            }
        }
    }
    
    func resetWhiteBalance() {
        sessionQueue.async {
            guard let device = self.videoDeviceInput?.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
                device.unlockForConfiguration()
            } catch {
                print("Failed to lock for WB reset")
            }
        }
    }
    
    func updateEV(bias: Float) {
        sessionQueue.async {
            guard let device = self.videoDeviceInput?.device else { return }
            do {
                try device.lockForConfiguration()
                // Force Auto Exposure so TargetBias can mathematically take effect
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                
                let targetBias = max(self.minEV, min(self.maxEV, bias))
                device.setExposureTargetBias(targetBias, completionHandler: nil)
                device.unlockForConfiguration()
                DispatchQueue.main.async {
                    self.currentEV = targetBias
                }
            } catch {
                print("Failed to lock for EV update")
            }
        }
    }
    
    // MARK: - Capture
    
    func capturePhoto() {
        sessionQueue.async {
            let photoSettings: AVCapturePhotoSettings
            
            // Check for ProRAW support
            if self.photoOutput.isAppleProRAWSupported {
                guard let rawFormat = self.photoOutput.availableRawPhotoPixelFormatTypes.first else {
                    return
                }
                photoSettings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat,
                                                       processedFormat: [AVVideoCodecKey: AVVideoCodecType.hevc])
            } else {
                photoSettings = AVCapturePhotoSettings()
            }
            
            photoSettings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
            
            self.photoOutput.capturePhoto(with: photoSettings, delegate: self)
        }
    }
}

extension CameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error = error {
            print("Error capturing photo: \(error)")
            return
        }
        
        guard let photoData = photo.fileDataRepresentation() else { return }
        
        // Save to Photos library (permissions are handled at app launch)
        PHPhotoLibrary.shared().performChanges({
            let creationRequest = PHAssetCreationRequest.forAsset()
            creationRequest.addResource(with: .photo, data: photoData, options: nil)
        }) { success, error in
            if success {
                print("Saved photo to library")
            } else if let error = error {
                print("Error saving photo: \(error)")
            }
        }
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        if isPeakingEnabled { // only process if enabled
            let newPeakingImage = PeakingProcessor.shared.process(pixelBuffer: pixelBuffer)
            DispatchQueue.main.async {
                self.peakingImage = newPeakingImage
            }
        }
    }
}
