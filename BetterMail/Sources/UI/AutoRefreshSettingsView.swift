import SwiftUI

struct AutoRefreshSettingsView: View {
    @ObservedObject var settings: AutoRefreshSettings

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
}
