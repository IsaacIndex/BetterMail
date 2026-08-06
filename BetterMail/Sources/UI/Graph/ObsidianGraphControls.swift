import SwiftUI

/// Floating controls intentionally mirror Obsidian's Filters / Groups /
/// Display / Forces vocabulary while exposing only controls BetterMail can
/// honor against its existing graph projection.
internal struct ObsidianGraphControls: View {
    @ObservedObject internal var settings: GraphCanvasSettings
    @Binding internal var searchQuery: String
    internal let data: GraphData
    internal let totalBranchCount: Int
    internal let textScale: CGFloat

    @State private var isCollapsed = false
    @State private var showsFilters = true
    @State private var showsGroups = false
    @State private var showsDisplay = false
    @State private var showsForces = false

    internal var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !isCollapsed {
                Divider()
                    .overlay(DesignTokens.Graph.AppTheme.line)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        controlSection(NSLocalizedString("graph.controls.filters",
                                                         comment: "Graph filters controls heading"),
                                       systemImage: "line.3.horizontal.decrease.circle",
                                       isExpanded: $showsFilters) {
                            filters
                        }
                        controlSection(NSLocalizedString("graph.controls.groups",
                                                         comment: "Graph groups controls heading"),
                                       systemImage: "circle.grid.cross",
                                       isExpanded: $showsGroups) {
                            groups
                        }
                        controlSection(NSLocalizedString("graph.controls.display",
                                                         comment: "Graph display controls heading"),
                                       systemImage: "eye",
                                       isExpanded: $showsDisplay) {
                            display
                        }
                        controlSection(NSLocalizedString("graph.controls.forces",
                                                         comment: "Graph forces controls heading"),
                                       systemImage: "point.3.connected.trianglepath.dotted",
                                       isExpanded: $showsForces) {
                            forces
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 500)
            }
        }
        .frame(width: isCollapsed ? 196 : 276)
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
                        data.threads.count,
                        totalBranchCount
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

    private var filters: some View {
        VStack(alignment: .leading, spacing: 9) {
            TextField(NSLocalizedString("graph.controls.search", comment: "Graph filter search field"),
                      text: $searchQuery)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(AccessibilityID.graphControlsSearch)
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
                        valueText("\(grouping.threadIDs.count)")
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
