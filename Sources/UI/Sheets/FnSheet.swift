import SwiftUI

/// Secondary settings in a half-height sheet (Slice 2 §4).
struct FnSheet: View {
    let controller: CameraController
    @Environment(\.cameraTheme) var theme

    var body: some View {
        let settings = controller.settings
        let overlays = settings.overlays
        NavigationStack {
            Form {
                Section {
                    Toggle(Branding.editionName, isOn: Binding(get: { settings.isEdition }, set: { controller.setEdition($0) }))
                    if settings.isEdition {
                        Picker("Framing", selection: Binding(get: { settings.framing }, set: { controller.setFraming($0) })) {
                            ForEach(FramingMode.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Picker("Grain", selection: Binding(get: { settings.grain }, set: { controller.setGrain($0) })) {
                            ForEach(GrainLevel.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Picker("Shutter sound", selection: Binding(get: { settings.shutterSound }, set: { controller.setShutterSound($0) })) {
                            ForEach(ShutterSoundVolume.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Toggle("Grain in viewfinder", isOn: Binding(get: { settings.previewGrain }, set: { controller.setPreviewGrain($0) }))
                    }
                } header: {
                    Text(Branding.editionShortName)
                } footer: {
                    Text(settings.isEdition
                         ? "Every photo is developed from RAW in \(Branding.lookName). 1:1 and XPAN crop the developed photo; a kept RAW stays full-frame. The shutter sound follows the silent switch."
                         : "A calm, monochrome interface with \(Branding.lookName), framing and grain.")
                }

                if settings.isEdition {
                    Section("White balance") {
                        Picker("White balance", selection: Binding(get: { settings.whiteBalance }, set: { controller.setWhiteBalance($0) })) {
                            Text("Auto").tag(WhiteBalanceStop.auto)
                            ForEach(WhiteBalancePreset.allCases, id: \.self) { preset in
                                Text(preset.label).tag(WhiteBalanceStop.preset(preset))
                            }
                            if case .kelvin(let kelvin) = settings.whiteBalance {
                                Text("\(kelvin)K").tag(WhiteBalanceStop.kelvin(kelvin))
                            }
                        }
                    }
                }

                Section("Focus") {
                    Picker("Focus mode", selection: Binding(get: { settings.focusMode }, set: { controller.setFocusMode($0) })) {
                        ForEach(FocusMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Peaking in AF", isOn: Binding(get: { overlays.peakingInAF }, set: { value in controller.updateOverlays { $0.peakingInAF = value } }))
                    Picker("Peaking colour", selection: Binding(get: { overlays.peakingColor }, set: { value in controller.updateOverlays { $0.peakingColor = value } })) {
                        ForEach(PeakingColor.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Peaking level", selection: Binding(get: { overlays.peakingLevel }, set: { value in controller.updateOverlays { $0.peakingLevel = value } })) {
                        ForEach(PeakingLevel.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Exposure aids") {
                    Toggle("Zebras", isOn: Binding(get: { overlays.zebrasEnabled }, set: { value in controller.updateOverlays { $0.zebrasEnabled = value } }))
                    Picker("Zebra threshold", selection: Binding(get: { overlays.zebraThreshold }, set: { value in controller.updateOverlays { $0.zebraThreshold = value } })) {
                        ForEach(ZebraThreshold.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!overlays.zebrasEnabled)
                    Picker("Histogram", selection: Binding(get: { overlays.histogramMode }, set: { value in controller.updateOverlays { $0.histogramMode = value } })) {
                        ForEach(HistogramMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Composition") {
                    Picker("Grid", selection: Binding(get: { overlays.grid }, set: { value in controller.updateOverlays { $0.grid = value } })) {
                        ForEach(GridMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Level", isOn: Binding(get: { overlays.levelEnabled }, set: { value in controller.updateOverlays { $0.levelEnabled = value } }))
                    Toggle("Horizon line in viewfinder", isOn: Binding(get: { overlays.levelLine }, set: { value in controller.updateOverlays { $0.levelLine = value } }))
                }

                Section("Capture") {
                    Picker("Format", selection: Binding(get: { settings.captureFormat }, set: { controller.setCaptureFormat($0) })) {
                        ForEach(CaptureFormat.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!settings.rawSupported)
                    if !settings.rawSupported {
                        Text("This lens has no RAW format; photos are saved as HEIF.")
                            .font(.footnote)
                            .foregroundColor(theme.secondaryText)
                    }
                    if settings.rawSuppressedForStorage {
                        Text("RAW is paused: less than 150 MB free.")
                            .font(.footnote)
                            .foregroundColor(theme.warning)
                    }
                }

                Section("Haptics") {
                    Toggle("Haptics", isOn: Binding(get: { settings.haptics.enabled }, set: { controller.setHapticsEnabled($0) }))
                    HStack {
                        Text("Intensity")
                        Slider(
                            value: Binding(get: { Double(settings.haptics.intensity) }, set: { controller.setHapticIntensity(Float($0)) }),
                            in: 0.5...1.0,
                            step: 0.1
                        )
                    }
                    .disabled(!settings.haptics.enabled)
                }

                #if DEBUG
                Section("Developer") {
                    Toggle("Performance HUD", isOn: Binding(get: { settings.showPerformanceHUD }, set: { controller.setShowPerformanceHUD($0) }))
                }
                #endif
            }
            .navigationTitle("Fn")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { controller.toggleFnSheet() }
                }
            }
        }
        .tint(theme.selection)
        .preferredColorScheme(.dark)
    }
}
