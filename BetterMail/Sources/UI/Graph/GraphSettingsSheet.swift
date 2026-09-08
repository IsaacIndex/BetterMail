import Foundation
import SwiftUI

internal struct GraphSettingsSheet: View {
    @ObservedObject internal var settings: GraphCanvasSettings
    @ObservedObject internal var automationCoordinator: GraphAutomationCoordinator
    internal let onScanCurrentMail: () -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var mailConsentSettings = OrganizationMailAutomationConsentSettings()

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
                    .help(NSLocalizedString("graph.settings.visible_branches.help",
                                            comment: "Help for the root graph branch limit"))
                    Stepper(value: $settings.visibleBranchesPerNode,
                            in: GraphCanvasSettings.visibleBranchesPerNodeRange) {
                        HStack {
                            Text(NSLocalizedString("graph.settings.visible_branches_per_node",
                                                   comment: "Number of child branches shown per graph node"))
                            Spacer()
                            Text("\(settings.visibleBranchesPerNode)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(DesignTokens.Graph.AppTheme.inkTertiary)
                        }
                    }
                    .help(NSLocalizedString("graph.settings.visible_branches_per_node.help",
                                            comment: "Help for the per-node graph branch limit"))
                    Stepper(value: $settings.visibleEmailsPerThread,
                            in: GraphCanvasSettings.visibleEmailsPerThreadRange) {
                        HStack {
                            Text(NSLocalizedString("graph.settings.visible_emails_per_thread",
                                                   comment: "Number of email nodes shown per thread page"))
                            Spacer()
                            Text("\(settings.visibleEmailsPerThread)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(DesignTokens.Graph.AppTheme.inkTertiary)
                        }
                    }
                    .help(NSLocalizedString("graph.settings.visible_emails_per_thread.help",
                                            comment: "Help for the per-thread email node limit"))
                }
                displaySection
                suggestionPreferencesSection
                GraphAutomationSettingsSection(settings: automationCoordinator.settings,
                                               coordinator: automationCoordinator,
                                               onScanCurrentMail: onScanCurrentMail)
                OrganizationMailAutomationConsentSection(settings: mailConsentSettings)
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
        .frame(maxHeight: 720)
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

    private var suggestionPreferencesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(NSLocalizedString("graph.settings.suggestions.title",
                                   comment: "Graph suggestion preferences section title"))
                .font(.headline)
                .foregroundStyle(DesignTokens.Graph.AppTheme.ink)
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

private struct OrganizationMailAutomationConsentSection: View {
    @ObservedObject var settings: OrganizationMailAutomationConsentSettings

    @State private var draftEffects: Set<OrganizationMailAutomationEffect> = []
    @State private var isShowingGrantConfirmation = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(NSLocalizedString("organization.mail.consent.title",
                                       comment: "Apple Mail automation consent section title"))
                    .font(.headline)
                    .foregroundStyle(DesignTokens.Graph.AppTheme.ink)
                Spacer()
                Text(statusText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isCurrent ? Color.green : Color.secondary)
                    .accessibilityIdentifier(AccessibilityID.organizationMailConsentStatus)
            }
            Text(NSLocalizedString("organization.mail.consent.detail",
                                   comment: "Explanation of separate Mail automation consent"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            consentToggle(.messageMove,
                          titleKey: "organization.mail.consent.effect.move")
            consentToggle(.messageRestore,
                          titleKey: "organization.mail.consent.effect.restore")
            consentToggle(.mailboxCreation,
                          titleKey: "organization.mail.consent.effect.create")

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(NSLocalizedString("organization.mail.consent.grant",
                                         comment: "Grant selected Apple Mail automation consent")) {
                    isShowingGrantConfirmation = true
                }
                .disabled(draftEffects.isEmpty)
                .accessibilityIdentifier(AccessibilityID.organizationMailConsentGrant)
                if isCurrent {
                    Button(NSLocalizedString("organization.mail.consent.revoke",
                                             comment: "Revoke Apple Mail automation consent"),
                           role: .destructive) {
                        do {
                            try settings.revoke()
                            draftEffects = []
                            errorMessage = nil
                        } catch {
                            errorMessage = NSLocalizedString("organization.mail.consent.error.save",
                                                             comment: "Failed to save Apple Mail consent")
                        }
                    }
                    .accessibilityIdentifier(AccessibilityID.organizationMailConsentRevoke)
                }
            }
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
        .onAppear(perform: syncDraft)
        .onChange(of: settings.resolution) { _, _ in syncDraft() }
        .alert(NSLocalizedString("organization.mail.consent.confirm.title",
                                 comment: "Confirm Apple Mail automation consent title"),
               isPresented: $isShowingGrantConfirmation) {
            Button(NSLocalizedString("organization.mail.consent.confirm.action",
                                     comment: "Confirm Apple Mail automation consent")) {
                do {
                    try settings.grant(allowedEffects: draftEffects)
                    errorMessage = nil
                } catch {
                    errorMessage = NSLocalizedString("organization.mail.consent.error.save",
                                                     comment: "Failed to save Apple Mail consent")
                }
            }
            Button(NSLocalizedString("common.cancel", comment: "Cancel"), role: .cancel) {}
        } message: {
            Text(String.localizedStringWithFormat(
                NSLocalizedString("organization.mail.consent.confirm.message",
                                  comment: "Confirm selected Mail automation effect count"),
                draftEffects.count
            ))
        }
    }

    private var isCurrent: Bool {
        if case .current = settings.resolution { return true }
        return false
    }

    private var statusText: String {
        NSLocalizedString(settings.resolution.status.localizationKey,
                          comment: "Apple Mail automation consent status")
    }

    private func consentToggle(_ effect: OrganizationMailAutomationEffect,
                               titleKey: String) -> some View {
        Toggle(NSLocalizedString(titleKey, comment: "Apple Mail automation effect"),
               isOn: Binding(
                   get: { draftEffects.contains(effect) },
                   set: { isEnabled in
                       if isEnabled {
                           draftEffects.insert(effect)
                       } else {
                           draftEffects.remove(effect)
                       }
                   }
               ))
            .accessibilityIdentifier("bettermail.organization-mail-consent.effect.\(effect.rawValue)")
    }

    private func syncDraft() {
        draftEffects = settings.allowedEffects
    }
}

private struct GraphAutomationSettingsSection: View {
    @ObservedObject var settings: GraphAutomationSettings
    @ObservedObject var coordinator: GraphAutomationCoordinator
    let onScanCurrentMail: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(NSLocalizedString("graph.automation.settings.title",
                                       comment: "Graph automation settings heading"))
                    .font(.headline)
                    .foregroundStyle(DesignTokens.Graph.AppTheme.ink)
                Spacer()
                if coordinator.isEvaluating {
                    ProgressView().controlSize(.small)
                }
            }
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

    private func actionControls(title: String,
                                mode: Binding<GraphAutomationMode>,
                                strictness: Binding<GraphAutomationStrictness>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.callout.weight(.semibold))
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
