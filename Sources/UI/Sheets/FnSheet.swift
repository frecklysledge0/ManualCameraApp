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
                    Toggle("RAW + HEIF", isOn: Binding(get: { settings.rawEnabled }, set: { _ in controller.toggleRaw() }))
                        .disabled(!settings.rawSupported)
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

                Section {
                    Toggle(Branding.editionName, isOn: .constant(false))
                        .disabled(true)
                } footer: {
                    Text("Coming in the next update.")
                }
            }
            .navigationTitle("Fn")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { controller.toggleFnSheet() }
                }
            }
        }
        .tint(theme.accent)
        .preferredColorScheme(.dark)
    }
}
