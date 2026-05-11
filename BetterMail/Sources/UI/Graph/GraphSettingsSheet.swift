import Foundation
import SwiftUI

internal struct GraphSettingsSheet: View {
    @ObservedObject internal var settings: GraphCanvasSettings
    @Environment(\.dismiss) private var dismiss

    internal var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(NSLocalizedString("graph.settings.title", comment: "Graph settings title"))
                    .font(.title3.bold())
                    .foregroundStyle(DesignTokens.Graph.AppTheme.ink)
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(NSLocalizedString("graph.settings.sound", comment: "Graph sound toggle"),
                           isOn: $settings.soundOn)
                    Picker(NSLocalizedString("graph.settings.motion", comment: "Graph motion picker"),
                           selection: $settings.reduceMotionOverride) {
                        ForEach(GraphReduceMotionOverride.allCases) { mode in
                            Text(mode.localizedTitle).tag(mode)
                        }
                    }
                    TextField(NSLocalizedString("graph.settings.snip_parent", comment: "Graph snip parent mailbox field"),
                              text: $settings.snipParentMailboxPath)
                        .textFieldStyle(.roundedBorder)
                }
                forcesSection
                HStack {
                    Spacer()
                    Button(NSLocalizedString("graph.settings.done", comment: "Close graph settings")) {
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(18)
        }
        .frame(width: 440)
        .frame(maxHeight: 620)
        .background(DesignTokens.Graph.AppTheme.background)
    }

    private var forcesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(NSLocalizedString("graph.settings.forces.title", comment: "Graph force settings section title"))
                    .font(.headline)
                    .foregroundStyle(DesignTokens.Graph.AppTheme.ink)
                Spacer()
                Button(NSLocalizedString("graph.settings.forces.restore", comment: "Restore graph force defaults")) {
                    settings.restoreWhisperDefaults()
                }
            }
            forceSlider(NSLocalizedString("graph.settings.forces.center", comment: "Center force slider"),
                        value: $settings.forceCenter,
                        range: 0.001...0.02,
                        step: 0.001,
                        precision: 3)
            forceSlider(NSLocalizedString("graph.settings.forces.repel", comment: "Repel force slider"),
                        value: $settings.forceRepel,
                        range: 1_000...8_000,
                        step: 100,
                        precision: 0)
            forceSlider(NSLocalizedString("graph.settings.forces.repel_cutoff", comment: "Repel cutoff slider"),
                        value: $settings.forceRepelCutoff,
                        range: 160...640,
                        step: 10,
                        precision: 0)
            forceSlider(NSLocalizedString("graph.settings.forces.link_spring", comment: "Link spring slider"),
                        value: $settings.forceLinkSpring,
                        range: 0.01...0.09,
                        step: 0.005,
                        precision: 3)
            forceSlider(NSLocalizedString("graph.settings.forces.trunk_length", comment: "Trunk length slider"),
                        value: $settings.forceTrunkLength,
                        range: 120...320,
                        step: 4,
                        precision: 0)
            forceSlider(NSLocalizedString("graph.settings.forces.chain_length", comment: "Chain length slider"),
                        value: $settings.forceChainLength,
                        range: 60...180,
                        step: 2,
                        precision: 0)
            forceSlider(NSLocalizedString("graph.settings.forces.damping", comment: "Damping slider"),
                        value: $settings.forceDamping,
                        range: 0.72...0.96,
                        step: 0.01,
                        precision: 2)
            forceSlider(NSLocalizedString("graph.settings.forces.curl", comment: "Curl slider"),
                        value: $settings.forceCurl,
                        range: 0...16,
                        step: 0.5,
                        precision: 1)
            forceSlider(NSLocalizedString("graph.settings.forces.curl_variability", comment: "Curl variability slider"),
                        value: $settings.forceCurlVariability,
                        range: 0...1,
                        step: 0.05,
                        precision: 2)
            forceSlider(NSLocalizedString("graph.settings.forces.spline_tension", comment: "Spline tension slider"),
                        value: $settings.forceSplineTension,
                        range: 0...1,
                        step: 0.05,
                        precision: 2)
            forceSlider(NSLocalizedString("graph.settings.forces.curl_falloff", comment: "Curl falloff slider"),
                        value: $settings.forceCurlFalloff,
                        range: 0...1,
                        step: 0.05,
                        precision: 2)
            Toggle(NSLocalizedString("graph.settings.forces.label_repel", comment: "Label repel toggle"),
                   isOn: $settings.forceLabelRepelOn)
            forceSlider(NSLocalizedString("graph.settings.forces.label_repel_strength", comment: "Label repel strength slider"),
                        value: $settings.forceLabelRepelStrength,
                        range: 0...0.4,
                        step: 0.01,
                        precision: 2)
                .disabled(!settings.forceLabelRepelOn)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(DesignTokens.Graph.AppTheme.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(DesignTokens.Graph.AppTheme.line, lineWidth: 1)
        )
    }

    private func forceSlider(_ title: String,
                             value: Binding<CGFloat>,
                             range: ClosedRange<Double>,
                             step: Double,
                             precision: Int) -> some View {
        let doubleValue = Binding<Double>(
            get: { Double(value.wrappedValue) },
            set: { value.wrappedValue = CGFloat($0) }
        )
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(Self.formatted(value.wrappedValue, precision: precision))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DesignTokens.Graph.AppTheme.inkTertiary)
            }
            .font(.caption)
            Slider(value: doubleValue, in: range, step: step)
        }
    }

    private static func formatted(_ value: CGFloat, precision: Int) -> String {
        String(format: "%.\(precision)f", Double(value))
    }
}
