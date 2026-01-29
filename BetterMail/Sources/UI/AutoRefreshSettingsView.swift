import OSLog
import SwiftUI

internal struct AutoRefreshSettingsView: View {
    @ObservedObject internal var settings: AutoRefreshSettings
    @ObservedObject internal var inspectorSettings: InspectorViewSettings
    @ObservedObject internal var displaySettings: ThreadCanvasDisplaySettings
    @StateObject private var backfillViewModel: BatchBackfillSettingsViewModel
    @State private var isResetConfirmationPresented = false

    internal init(settings: AutoRefreshSettings,
                  inspectorSettings: InspectorViewSettings,
                  displaySettings: ThreadCanvasDisplaySettings) {
        self.settings = settings
        self.inspectorSettings = inspectorSettings
        self.displaySettings = displaySettings
        _backfillViewModel = StateObject(wrappedValue: BatchBackfillSettingsViewModel(
            snippetLineLimitProvider: { inspectorSettings.snippetLineLimit }
        ))
    }

    internal var body: some View {
        Form {
            Section {
                Toggle("Enable auto refresh", isOn: $settings.isEnabled)

                LabeledContent("Refresh interval") {
                    Stepper(
                        value: minutesBinding,
                        in: Int(Self.minimumMinutes)...Int(Self.maximumMinutes),
                        step: 1
                    ) {
                        Text("\(minutesBinding.wrappedValue) min")
                            .monospacedDigit()
                    }
                    .frame(maxWidth: 180, alignment: .trailing)
                    .disabled(!settings.isEnabled)
                }
            } header: {
                Text("Auto Refresh")
            } footer: {
                Text("Automatically refreshes the thread list on the selected interval.")
            }

            Section {
                LabeledContent(NSLocalizedString("settings.inspector.snippet_lines", comment: "Label for snippet line limit setting")) {
                    Stepper(
                        value: lineLimitBinding,
                        in: InspectorViewSettings.minimumSnippetLineLimit...InspectorViewSettings.maximumSnippetLineLimit,
                        step: 1
                    ) {
                        Text(String.localizedStringWithFormat(
                            NSLocalizedString("settings.inspector.snippet_lines.value", comment: "Value label for snippet line limit"),
                            inspectorSettings.snippetLineLimit
                        ))
                        .monospacedDigit()
                    }
                    .frame(maxWidth: 180, alignment: .trailing)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(NSLocalizedString("settings.inspector.stop_words", comment: "Label for snippet stop words setting"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $inspectorSettings.stopPhrasesText)
                        .frame(minHeight: 120)
                        .font(.callout)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.secondary.opacity(0.35))
                        )
                }
            } header: {
                Text(NSLocalizedString("settings.inspector.title", comment: "Header for inspector settings section"))
            } footer: {
                Text(NSLocalizedString("settings.inspector.stop_words.footer", comment: "Footer describing stop words behavior"))
            }

            Section {
                LabeledContent(NSLocalizedString("settings.canvas.zoom.current", comment: "Label for current thread canvas zoom")) {
                    Text(displaySettings.currentZoom, format: .number.precision(.fractionLength(3)))
                        .monospacedDigit()
                }

                LabeledContent(NSLocalizedString("settings.canvas.zoom.detailed", comment: "Label for detailed zoom threshold")) {
                    Stepper(
                        value: detailedThresholdBinding,
                        in: Double(ThreadCanvasLayoutMetrics.minZoom)...Double(ThreadCanvasLayoutMetrics.maxZoom),
                        step: 0.05
                    ) {
                        Text(detailedThresholdBinding.wrappedValue,
                             format: .number.precision(.fractionLength(2)))
                            .monospacedDigit()
                    }
                    .frame(maxWidth: 180, alignment: .trailing)
                }

                LabeledContent(NSLocalizedString("settings.canvas.zoom.compact", comment: "Label for compact zoom threshold")) {
                    Stepper(
                        value: compactThresholdBinding,
                        in: Double(ThreadCanvasLayoutMetrics.minZoom)...Double(ThreadCanvasLayoutMetrics.maxZoom),
                        step: 0.05
                    ) {
                        Text(compactThresholdBinding.wrappedValue,
                             format: .number.precision(.fractionLength(2)))
                            .monospacedDigit()
                    }
                    .frame(maxWidth: 180, alignment: .trailing)
                }

                LabeledContent(NSLocalizedString("settings.canvas.zoom.minimal", comment: "Label for minimal zoom threshold")) {
                    Stepper(
                        value: minimalThresholdBinding,
                        in: Double(ThreadCanvasLayoutMetrics.minZoom)...Double(ThreadCanvasLayoutMetrics.maxZoom),
                        step: 0.05
                    ) {
                        Text(minimalThresholdBinding.wrappedValue,
                             format: .number.precision(.fractionLength(2)))
                            .monospacedDigit()
                    }
                    .frame(maxWidth: 180, alignment: .trailing)
                }
            } header: {
                Text(NSLocalizedString("settings.canvas.title", comment: "Header for thread canvas settings section"))
            } footer: {
                Text(NSLocalizedString("settings.canvas.zoom.footer", comment: "Footer describing thread canvas zoom thresholds"))
            }

            Section {
                DatePicker(NSLocalizedString("settings.backfill.start", comment: "Label for backfill start date"),
                           selection: $backfillViewModel.startDate,
                           displayedComponents: .date)
                DatePicker(NSLocalizedString("settings.backfill.end", comment: "Label for backfill end date"),
                           selection: $backfillViewModel.endDate,
                           displayedComponents: .date)

                Button {
                    backfillViewModel.startBackfill()
                } label: {
                    HStack {
                        if backfillViewModel.isRunning {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(NSLocalizedString("settings.backfill.button", comment: "Button label to start batch backfill"))
                    }
                }
                .disabled(backfillViewModel.isRunning)

                VStack(alignment: .leading, spacing: 4) {
                    Text(backfillViewModel.statusText)
                        .font(.subheadline)
                    if let total = backfillViewModel.totalCount {
                        Text(String.localizedStringWithFormat(
                            NSLocalizedString("settings.backfill.progress", comment: "Progress detail for backfill"),
                            backfillViewModel.completedCount,
                            total,
                            backfillViewModel.currentBatchSize
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    if let error = backfillViewModel.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    if let progressValue = backfillViewModel.progressValue {
                        ProgressView(value: progressValue)
                    }
                }
                .accessibilityElement(children: .combine)
            } header: {
                Text(NSLocalizedString("settings.backfill.title", comment: "Header for batch backfill settings section"))
            } footer: {
                Text(NSLocalizedString("settings.backfill.footer", comment: "Footer describing batch backfill behavior"))
            }

            Section {
                Button(role: .destructive) {
                    isResetConfirmationPresented = true
                } label: {
                    Text(NSLocalizedString("settings.reset.manual_grouping.button", comment: "Button label for resetting manual grouping"))
                }
            } header: {
                Text(NSLocalizedString("settings.reset.title", comment: "Header for reset section in settings"))
            } footer: {
                Text(NSLocalizedString("settings.reset.manual_grouping.footer", comment: "Footer text describing manual grouping reset"))
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, idealWidth: 520)
        .padding(.vertical, 8)
        .alert(NSLocalizedString("settings.reset.manual_grouping.confirm_title", comment: "Title for confirmation alert when resetting manual grouping"),
               isPresented: $isResetConfirmationPresented) {
            Button(NSLocalizedString("settings.reset.manual_grouping.confirm_action", comment: "Destructive action label for resetting manual grouping"),
                   role: .destructive) {
                resetManualGrouping()
            }
            Button(NSLocalizedString("settings.reset.manual_grouping.cancel", comment: "Cancel label for resetting manual grouping"),
                   role: .cancel) {}
        } message: {
            Text(NSLocalizedString("settings.reset.manual_grouping.confirm_message", comment: "Confirmation message for resetting manual grouping"))
        }
    }

    private var minutesBinding: Binding<Int> {
        Binding(
            get: { Int(settings.interval / 60) },
            set: { newValue in
                settings.interval = Double(newValue) * 60
            }
        )
    }

    private static let minimumMinutes = AutoRefreshSettings.minimumInterval / 60
    private static let maximumMinutes = AutoRefreshSettings.maximumInterval / 60

    private var lineLimitBinding: Binding<Int> {
        Binding(
            get: { inspectorSettings.snippetLineLimit },
            set: { inspectorSettings.snippetLineLimit = $0 }
        )
    }

    private var detailedThresholdBinding: Binding<Double> {
        Binding(
            get: { Double(displaySettings.detailedThreshold) },
            set: { displaySettings.detailedThreshold = CGFloat($0) }
        )
    }

    private var compactThresholdBinding: Binding<Double> {
        Binding(
            get: { Double(displaySettings.compactThreshold) },
            set: { displaySettings.compactThreshold = CGFloat($0) }
        )
    }

    private var minimalThresholdBinding: Binding<Double> {
        Binding(
            get: { Double(displaySettings.minimalThreshold) },
            set: { displaySettings.minimalThreshold = CGFloat($0) }
        )
    }

    private func resetManualGrouping() {
        Task {
            do {
                try await MessageStore.shared.resetManualThreadGroups()
            } catch {
                Log.app.error("Failed to reset manual thread groups: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
