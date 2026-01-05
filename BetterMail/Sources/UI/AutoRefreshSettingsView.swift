import SwiftUI

struct AutoRefreshSettingsView: View {
    @ObservedObject var settings: AutoRefreshSettings

    var body: some View {
        Form {
            Toggle("Enable Auto Refresh", isOn: $settings.isEnabled)
            intervalRow
                .disabled(!settings.isEnabled)
        }
        .padding()
        .frame(minWidth: 360)
    }

    private var intervalRow: some View {
        HStack {
            Text("Refresh interval")
            Spacer()
            Stepper(value: intervalBinding, in: Self.minimumMinutes...Self.maximumMinutes, step: 1) {
                Text("\(Int(settings.interval / 60)) min")
                    .monospacedDigit()
            }
        }
    }

    private var intervalBinding: Binding<Double> {
        Binding(get: {
            settings.interval / 60
        }, set: { newValue in
            settings.interval = newValue * 60
        })
    }

    private static let minimumMinutes = AutoRefreshSettings.minimumInterval / 60
    private static let maximumMinutes = AutoRefreshSettings.maximumInterval / 60
}
