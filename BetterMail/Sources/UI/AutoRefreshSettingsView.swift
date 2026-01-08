import SwiftUI

struct AutoRefreshSettingsView: View {
    @ObservedObject var settings: AutoRefreshSettings
    @ObservedObject var inspectorSettings: InspectorViewSettings

    var body: some View {
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
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, idealWidth: 520)
        .padding(.vertical, 8)
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
}
