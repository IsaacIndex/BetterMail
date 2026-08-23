import Foundation
import SwiftUI

internal struct GraphSettingsSheet: View {
    @ObservedObject internal var settings: GraphCanvasSettings
    @ObservedObject internal var automationCoordinator: GraphAutomationCoordinator
    internal let onScanCurrentMail: () -> Void
    @Environment(\.dismiss) private var dismiss

    internal var body: some View {
        Form {
            Section {
                Toggle(NSLocalizedString("graph.settings.sound", comment: "Graph sound toggle"),
                       isOn: $settings.soundOn)
                Picker(NSLocalizedString("graph.settings.motion", comment: "Graph motion picker"),
                       selection: $settings.reduceMotionOverride) {
                    ForEach(GraphReduceMotionOverride.allCases) { mode in
                        Text(mode.localizedTitle).tag(mode)
                    }
                }
                LabeledContent(NSLocalizedString("graph.settings.snip_parent",
                                                 comment: "Graph snip parent mailbox field")) {
                    TextField(NSLocalizedString("graph.settings.snip_parent",
                                                comment: "Graph snip parent mailbox field"),
                              text: $settings.snipParentMailboxPath)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                }
                branchCountControl
                childBranchCountControl
                emailCountControl
            } header: {
                Text(NSLocalizedString("graph.settings.title", comment: "Graph settings title"))
                    .font(.title3.bold())
                    .foregroundStyle(DesignTokens.Graph.AppTheme.ink)
                    .textCase(nil)
            }

            displaySection
            suggestionPreferencesSection
            GraphAutomationSettingsSection(settings: automationCoordinator.settings,
                                           coordinator: automationCoordinator,
                                           onScanCurrentMail: onScanCurrentMail)
            forcesSection

            Section {
                HStack {
                    Spacer()
                    Button(NSLocalizedString("graph.settings.done", comment: "Close graph settings")) {
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .frame(maxHeight: 720)
    }

    private var branchCountControl: some View {
        LabeledContent(NSLocalizedString("graph.settings.visible_branches",
                                         comment: "Number of graph branches shown per page")) {
            Stepper(value: $settings.visibleBranchCount,
                    in: GraphCanvasSettings.visibleBranchCountRange) {
                Text("\(settings.visibleBranchCount)")
                    .monospacedDigit()
            }
            .accessibilityLabel(NSLocalizedString("graph.settings.visible_branches",
                                                  comment: "Number of graph branches shown per page"))
            .frame(maxWidth: 150, alignment: .trailing)
        }
        .help(NSLocalizedString("graph.settings.visible_branches.help",
                                comment: "Help for the root graph branch limit"))
    }

    private var childBranchCountControl: some View {
        LabeledContent(NSLocalizedString("graph.settings.visible_branches_per_node",
                                         comment: "Number of child branches shown per graph node")) {
            Stepper(value: $settings.visibleBranchesPerNode,
                    in: GraphCanvasSettings.visibleBranchesPerNodeRange) {
                Text("\(settings.visibleBranchesPerNode)")
                    .monospacedDigit()
            }
            .accessibilityLabel(NSLocalizedString("graph.settings.visible_branches_per_node",
                                                  comment: "Number of child branches shown per graph node"))
            .frame(maxWidth: 150, alignment: .trailing)
        }
        .help(NSLocalizedString("graph.settings.visible_branches_per_node.help",
                                comment: "Help for the per-node graph branch limit"))
    }

    private var emailCountControl: some View {
        LabeledContent(NSLocalizedString("graph.settings.visible_emails_per_thread",
                                         comment: "Number of email nodes shown per thread page")) {
            Stepper(value: $settings.visibleEmailsPerThread,
                    in: GraphCanvasSettings.visibleEmailsPerThreadRange) {
                Text("\(settings.visibleEmailsPerThread)")
                    .monospacedDigit()
            }
            .accessibilityLabel(NSLocalizedString("graph.settings.visible_emails_per_thread",
                                                  comment: "Number of email nodes shown per thread page"))
            .frame(maxWidth: 150, alignment: .trailing)
        }
        .help(NSLocalizedString("graph.settings.visible_emails_per_thread.help",
                                comment: "Help for the per-thread email node limit"))
    }

    private var forcesSection: some View {
        Section {
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
        } header: {
            HStack {
                Text(NSLocalizedString("graph.settings.forces.title", comment: "Graph force settings section title"))
                    .foregroundStyle(DesignTokens.Graph.AppTheme.ink)
                Spacer()
                Button(NSLocalizedString("graph.settings.forces.restore", comment: "Restore graph force defaults")) {
                    settings.restoreObsidianDefaults()
                }
                .buttonStyle(.link)
            }
            .textCase(nil)
        }
    }

    private var displaySection: some View {
        Section {
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
        } header: {
            Text(NSLocalizedString("graph.controls.display", comment: "Graph display controls heading"))
                .foregroundStyle(DesignTokens.Graph.AppTheme.ink)
                .textCase(nil)
        }
    }

    private var suggestionPreferencesSection: some View {
        Section {
            Text(NSLocalizedString("graph.settings.suggestions.local_note",
                                   comment: "Graph suggestions are local preferences, not model training"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(String.localizedStringWithFormat(
                NSLocalizedString("graph.settings.suggestions.counts",
                                  comment: "Counts of hidden and exact rejected topic preferences"),
                settings.hiddenSuggestedTopics.count,
                settings.dismissedSuggestedTopicIDs.count
            ))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            Button(NSLocalizedString("graph.settings.suggestions.reset",
                                     comment: "Reset graph suggestion preferences")) {
                settings.resetSuggestedTopicPreferences()
            }
            .disabled(!settings.hasSuggestedTopicPreferences)
            .accessibilityIdentifier(AccessibilityID.graphSuggestionPreferencesReset)
        } header: {
            Text(NSLocalizedString("graph.settings.suggestions.title",
                                   comment: "Graph suggestion preferences section title"))
                .foregroundStyle(DesignTokens.Graph.AppTheme.ink)
                .textCase(nil)
        }
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
        return LabeledContent(title) {
            HStack(spacing: 8) {
                Slider(value: doubleValue, in: range, step: step)
                    .accessibilityLabel(title)
                    .frame(minWidth: 150)
                Text(Self.formatted(value.wrappedValue, precision: precision))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DesignTokens.Graph.AppTheme.inkTertiary)
                    .frame(minWidth: 46, alignment: .trailing)
            }
        }
    }

    private static func formatted(_ value: CGFloat, precision: Int) -> String {
        String(format: "%.\(precision)f", Double(value))
    }
}

private struct GraphAutomationSettingsSection: View {
    @ObservedObject var settings: GraphAutomationSettings
    @ObservedObject var coordinator: GraphAutomationCoordinator
    let onScanCurrentMail: () -> Void

    var body: some View {
        Section {
            Toggle(NSLocalizedString("graph.automation.settings.pause",
                                     comment: "Pause graph automation"),
                   isOn: Binding(get: { settings.isPaused },
                                 set: coordinator.setPaused))
                .accessibilityIdentifier(AccessibilityID.graphAutomationMasterPause)
            actionControls(title: NSLocalizedString("graph.automation.settings.attach",
                                                     comment: "Same-conversation automation settings"),
                           mode: $settings.attachMode,
                           strictness: $settings.attachStrictness)
            actionControls(title: NSLocalizedString("graph.automation.settings.append",
                                                     comment: "Same-topic automation settings"),
                           mode: $settings.appendMode,
                           strictness: $settings.appendStrictness)
            Toggle(NSLocalizedString("graph.automation.settings.follow_mailbox",
                                     comment: "Follow folder mailbox mapping setting"),
                   isOn: $settings.followsFolderMailboxMapping)
                .accessibilityIdentifier(AccessibilityID.graphAutomationFollowMailbox)
            Text(NSLocalizedString("graph.automation.settings.mailbox_note",
                                   comment: "Mailbox mapping automation explanation"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !coordinator.providerStatusMessage.isEmpty {
                Text(coordinator.providerStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(NSLocalizedString("graph.automation.settings.scan_current",
                                         comment: "Scan current mail for automation")) {
                    onScanCurrentMail()
                }
                .disabled(coordinator.isEvaluating || settings.isPaused)
                .accessibilityIdentifier(AccessibilityID.graphAutomationScanCurrentMail)
                Spacer()
                Menu(NSLocalizedString("graph.automation.settings.history",
                                       comment: "Automation history controls")) {
                    Button(NSLocalizedString("graph.automation.settings.clear_history",
                                             comment: "Clear automation history")) {
                        Task { await coordinator.resetHistory(includeObservations: false) }
                    }
                    Button(NSLocalizedString("graph.automation.settings.reset_baseline",
                                             comment: "Reset automation history and evaluated baseline"),
                           role: .destructive) {
                        Task { await coordinator.resetHistory(includeObservations: true) }
                    }
                }
            }
        } header: {
            HStack {
                Text(NSLocalizedString("graph.automation.settings.title",
                                       comment: "Graph automation settings heading"))
                    .foregroundStyle(DesignTokens.Graph.AppTheme.ink)
                Spacer()
                if coordinator.isEvaluating {
                    ProgressView().controlSize(.small)
                }
            }
            .textCase(nil)
        }
    }

    private func actionControls(title: String,
                                mode: Binding<GraphAutomationMode>,
                                strictness: Binding<GraphAutomationStrictness>) -> some View {
        LabeledContent(title) {
            HStack {
                Picker(NSLocalizedString("graph.automation.settings.mode",
                                         comment: "Automation action mode picker"),
                       selection: mode) {
                    ForEach(GraphAutomationMode.allCases) { value in
                        Text(value.localizedTitle).tag(value)
                    }
                }
                Picker(NSLocalizedString("graph.automation.settings.strictness",
                                         comment: "Automation strictness picker"),
                       selection: strictness) {
                    ForEach(GraphAutomationStrictness.allCases) { value in
                        Text(value.localizedTitle).tag(value)
                    }
                }
                .disabled(mode.wrappedValue == .off)
            }
            .labelsHidden()
        }
    }
}
