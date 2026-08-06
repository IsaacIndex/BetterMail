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
                    Stepper(value: $settings.visibleBranchCount,
                            in: GraphCanvasSettings.visibleBranchCountRange) {
                        HStack {
                            Text(NSLocalizedString("graph.settings.visible_branches",
                                                   comment: "Number of graph branches shown per page"))
                            Spacer()
                            Text("\(settings.visibleBranchCount)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(DesignTokens.Graph.AppTheme.inkTertiary)
                        }
                    }
                }
                displaySection
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
                    settings.restoreObsidianDefaults()
                }
            }
            forceSlider(NSLocalizedString("graph.controls.center_force", comment: "Graph center force slider"),
                        value: $settings.obsidianCenterStrength,
                        range: 0...0.012,
                        step: 0.0005,
                        precision: 4)
            forceSlider(NSLocalizedString("graph.controls.repel_force", comment: "Graph repel force slider"),
                        value: $settings.obsidianRepelStrength,
                        range: 400...6_000,
                        step: 100,
                        precision: 0)
            forceSlider(NSLocalizedString("graph.controls.link_force", comment: "Graph link force slider"),
                        value: $settings.obsidianLinkStrength,
                        range: 0.005...0.09,
                        step: 0.005,
                        precision: 3)
            forceSlider(NSLocalizedString("graph.controls.link_distance", comment: "Graph link distance slider"),
                        value: $settings.obsidianLinkDistance,
                        range: 48...180,
                        step: 2,
                        precision: 0)
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

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString("graph.controls.display", comment: "Graph display controls heading"))
                .font(.headline)
                .foregroundStyle(DesignTokens.Graph.AppTheme.ink)
            Toggle(NSLocalizedString("graph.controls.arrows", comment: "Show graph arrows toggle"),
                   isOn: $settings.obsidianShowsArrows)
            forceSlider(NSLocalizedString("graph.controls.text_fade",
                                          comment: "Graph text fade threshold slider"),
                        value: $settings.obsidianTextFadeThreshold,
                        range: -2...1,
                        step: 0.05,
                        precision: 2)
            forceSlider(NSLocalizedString("graph.controls.node_size", comment: "Graph node size slider"),
                        value: $settings.obsidianNodeSize,
                        range: 0.65...1.8,
                        step: 0.05,
                        precision: 2)
            forceSlider(NSLocalizedString("graph.controls.link_thickness",
                                          comment: "Graph link thickness slider"),
                        value: $settings.obsidianLinkThickness,
                        range: 0.5...3,
                        step: 0.1,
                        precision: 1)
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
