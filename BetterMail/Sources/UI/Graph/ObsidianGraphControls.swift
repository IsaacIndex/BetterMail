import SwiftUI

/// Task-first graph controls. Group context stays visible while paging,
/// display, force, and diagnostic tuning live behind one Advanced disclosure.
/// Existing settings bindings and persisted keys remain unchanged.
internal struct ObsidianGraphControls: View {
    @ObservedObject internal var settings: GraphCanvasSettings
    internal let data: GraphData
    internal let textScale: CGFloat
    internal let canUndoLayoutReset: Bool
    internal let onResetLayout: () -> Void
    internal let onUndoLayoutReset: () -> Void

    @State private var isCollapsed = true
    @State private var showsGroups = true
    @State private var showsAdvanced = false
    @State private var showsPaging = false
    @State private var showsDisplay = false
    @State private var showsForces = false
    @State private var showsLayout = false
    @State private var showsResetLayoutConfirmation = false

    internal var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !isCollapsed {
                Divider()
                    .overlay(DesignTokens.Graph.AppTheme.line)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        controlSection(NSLocalizedString("graph.controls.groups",
                                                         comment: "Graph groups controls heading"),
                                       systemImage: "circle.grid.cross",
                                       isExpanded: $showsGroups) {
                            groups
                        }
                        controlSection(NSLocalizedString("organizer.controls.advanced",
                                                         value: "Advanced",
                                                         comment: "Advanced organizer graph controls heading"),
                                       systemImage: "slider.horizontal.3",
                                       isExpanded: $showsAdvanced) {
                            advanced
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 500)
            }
        }
        .frame(width: 196)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(DesignTokens.Graph.AppTheme.panel.opacity(0.96))
                .shadow(color: Color.black.opacity(0.11), radius: 18, y: 7)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(DesignTokens.Graph.AppTheme.line, lineWidth: 1)
        )
        .accessibilityIdentifier(AccessibilityID.graphControls)
        .animation(.easeOut(duration: 0.16), value: isCollapsed)
        .confirmationDialog(
            NSLocalizedString("organizer.layout.reset.confirm.title",
                              comment: "Confirm active organizer layout reset"),
            isPresented: $showsResetLayoutConfirmation,
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("organizer.layout.reset.confirm.action",
                                     comment: "Confirm active organizer layout reset"),
                   role: .destructive,
                   action: onResetLayout)
            Button(NSLocalizedString("common.cancel", comment: "Cancel action"),
                   role: .cancel) {}
        } message: {
            Text(NSLocalizedString("organizer.layout.reset.confirm.message",
                                   comment: "Active mailbox layout reset explanation"))
        }
    }

    private var header: some View {
        Button {
            isCollapsed.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "circle.hexagongrid")
                    .foregroundStyle(DesignTokens.Graph.AppTheme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(NSLocalizedString("graph.controls.title", comment: "Graph controls title"))
                        .font(DesignTokens.font(size: 11, weight: .semibold, textScale: textScale))
                        .foregroundStyle(DesignTokens.Graph.AppTheme.ink)
                    Text(String.localizedStringWithFormat(
                        NSLocalizedString("graph.controls.branch_count",
                                          comment: "Visible and total graph branch count"),
                        data.visiblePrimaryBranchCount,
                        data.totalPrimaryBranchCount
                    ))
                    .font(DesignTokens.font(size: 9, weight: .regular, textScale: textScale))
                    .foregroundStyle(DesignTokens.Graph.AppTheme.inkTertiary)
                }
                Spacer(minLength: 4)
                Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DesignTokens.Graph.AppTheme.inkTertiary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString("graph.controls.toggle",
                                              comment: "Show or hide graph controls"))
    }

    private var paging: some View {
        VStack(alignment: .leading, spacing: 9) {
            Stepper(value: $settings.visibleBranchCount,
                    in: GraphCanvasSettings.visibleBranchCountRange) {
                HStack {
                    Text(NSLocalizedString("graph.settings.visible_branches",
                                           comment: "Number of graph branches shown per page"))
                    Spacer()
                    valueText("\(settings.visibleBranchCount)")
                }
            }
            .font(.caption)
            .help(NSLocalizedString("graph.settings.visible_branches.help",
                                    comment: "Help for the root graph branch limit"))
            Stepper(value: $settings.visibleBranchesPerNode,
                    in: GraphCanvasSettings.visibleBranchesPerNodeRange) {
                HStack {
                    Text(NSLocalizedString("graph.settings.visible_branches_per_node",
                                           comment: "Number of child branches shown per graph node"))
                    Spacer()
                    valueText("\(settings.visibleBranchesPerNode)")
                }
            }
            .font(.caption)
            .help(NSLocalizedString("graph.settings.visible_branches_per_node.help",
                                    comment: "Help for the per-node graph branch limit"))
            Stepper(value: $settings.visibleEmailsPerThread,
                    in: GraphCanvasSettings.visibleEmailsPerThreadRange) {
                HStack {
                    Text(NSLocalizedString("graph.settings.visible_emails_per_thread",
                                           comment: "Number of email nodes shown per thread page"))
                    Spacer()
                    valueText("\(settings.visibleEmailsPerThread)")
                }
            }
            .font(.caption)
            .help(NSLocalizedString("graph.settings.visible_emails_per_thread.help",
                                    comment: "Help for the per-thread email node limit"))
        }
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 2) {
            nestedSection(NSLocalizedString("graph.controls.filters",
                                             comment: "Graph paging controls heading"),
                          systemImage: "rectangle.stack",
                          isExpanded: $showsPaging) {
                paging
            }
            nestedSection(NSLocalizedString("graph.controls.display",
                                             comment: "Graph display controls heading"),
                          systemImage: "eye",
                          isExpanded: $showsDisplay) {
                display
            }
            nestedSection(NSLocalizedString("graph.controls.forces",
                                             comment: "Graph forces controls heading"),
                          systemImage: "point.3.connected.trianglepath.dotted",
                          isExpanded: $showsForces) {
                forces
            }
            nestedSection(NSLocalizedString("organizer.layout.controls.title",
                                             comment: "Organizer layout controls heading"),
                          systemImage: "arrow.counterclockwise",
                          isExpanded: $showsLayout) {
                layoutActions
            }
        }
    }

    private var layoutActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                showsResetLayoutConfirmation = true
            } label: {
                Label(NSLocalizedString("organizer.layout.reset",
                                        comment: "Reset active organizer layout"),
                      systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.link)
            .accessibilityIdentifier(AccessibilityID.organizerResetLayout)

            Button(action: onUndoLayoutReset) {
                Label(NSLocalizedString("organizer.layout.reset.undo",
                                        comment: "Undo active organizer layout reset"),
                      systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.link)
            .disabled(!canUndoLayoutReset)
            .accessibilityIdentifier(AccessibilityID.organizerUndoLayoutReset)

            Text(NSLocalizedString("organizer.layout.reset.scope_note",
                                   comment: "Active mailbox layout reset scope note"))
                .font(.caption2)
                .foregroundStyle(DesignTokens.Graph.AppTheme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var groups: some View {
        if data.groupings.isEmpty {
            Text(NSLocalizedString("graph.controls.groups.empty", comment: "Empty graph groups message"))
                .font(.caption)
                .foregroundStyle(DesignTokens.Graph.AppTheme.inkTertiary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(data.groupings.prefix(8))) { grouping in
                    HStack(spacing: 7) {
                        Circle()
                            .fill(grouping.isSuggestion
                                  ? DesignTokens.Graph.AppTheme.panelSecondary
                                  : DesignTokens.Graph.AppTheme.accentSoft)
                            .overlay(
                                Circle()
                                    .stroke(DesignTokens.Graph.AppTheme.accent,
                                            style: StrokeStyle(lineWidth: 1,
                                                               dash: grouping.isSuggestion ? [2, 2] : []))
                            )
                            .frame(width: 9, height: 9)
                        Text(grouping.title)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        valueText("\(grouping.memberCount)")
                    }
                    .font(.caption)
                }
            }
        }
    }

    private var display: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(NSLocalizedString("graph.controls.arrows", comment: "Show graph arrows toggle"),
                   isOn: $settings.obsidianShowsArrows)
            controlSlider(NSLocalizedString("graph.controls.text_fade",
                                             comment: "Graph text fade threshold slider"),
                          value: $settings.obsidianTextFadeThreshold,
                          range: -2...1,
                          step: 0.05,
                          precision: 2)
            controlSlider(NSLocalizedString("graph.controls.node_size", comment: "Graph node size slider"),
                          value: $settings.obsidianNodeSize,
                          range: 0.65...1.8,
                          step: 0.05,
                          precision: 2)
            controlSlider(NSLocalizedString("graph.controls.link_thickness",
                                             comment: "Graph link thickness slider"),
                          value: $settings.obsidianLinkThickness,
                          range: 0.5...3,
                          step: 0.1,
                          precision: 1)
        }
        .font(.caption)
    }

    private var forces: some View {
        VStack(alignment: .leading, spacing: 10) {
            controlSlider(NSLocalizedString("graph.controls.center_force", comment: "Graph center force slider"),
                          value: $settings.obsidianCenterStrength,
                          range: 0...0.012,
                          step: 0.0005,
                          precision: 4)
            controlSlider(NSLocalizedString("graph.controls.repel_force", comment: "Graph repel force slider"),
                          value: $settings.obsidianRepelStrength,
                          range: 400...6_000,
                          step: 100,
                          precision: 0)
            controlSlider(NSLocalizedString("graph.controls.link_force", comment: "Graph link force slider"),
                          value: $settings.obsidianLinkStrength,
                          range: 0.005...0.09,
                          step: 0.005,
                          precision: 3)
            controlSlider(NSLocalizedString("graph.controls.link_distance", comment: "Graph link distance slider"),
                          value: $settings.obsidianLinkDistance,
                          range: 48...180,
                          step: 2,
                          precision: 0)
            Button(NSLocalizedString("graph.settings.forces.restore",
                                     comment: "Restore graph force defaults")) {
                settings.restoreObsidianDefaults()
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }

    private func controlSection<Content: View>(_ title: String,
                                               systemImage: String,
                                               isExpanded: Binding<Bool>,
                                               @ViewBuilder content: @escaping () -> Content) -> some View {
        DisclosureGroup(isExpanded: isExpanded) {
            content()
                .padding(.top, 8)
                .padding(.bottom, 6)
        } label: {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DesignTokens.Graph.AppTheme.ink)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
    }

    private func nestedSection<Content: View>(_ title: String,
                                              systemImage: String,
                                              isExpanded: Binding<Bool>,
                                              @ViewBuilder content: @escaping () -> Content) -> some View {
        DisclosureGroup(isExpanded: isExpanded) {
            content()
                .padding(.top, 7)
                .padding(.bottom, 5)
        } label: {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(DesignTokens.Graph.AppTheme.inkSecondary)
        }
        .padding(.vertical, 4)
    }

    private func controlSlider(_ title: String,
                               value: Binding<CGFloat>,
                               range: ClosedRange<Double>,
                               step: Double,
                               precision: Int) -> some View {
        let doubleValue = Binding<Double>(get: { Double(value.wrappedValue) },
                                          set: { value.wrappedValue = CGFloat($0) })
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                valueText(Self.formatted(value.wrappedValue, precision: precision))
            }
            Slider(value: doubleValue, in: range, step: step)
        }
    }

    private func valueText(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(DesignTokens.Graph.AppTheme.inkTertiary)
    }

    private static func formatted(_ value: CGFloat, precision: Int) -> String {
        String(format: "%.\(precision)f", Double(value))
    }
}
