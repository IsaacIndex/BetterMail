import SwiftUI

internal struct GraphSettingsSheet: View {
    @ObservedObject internal var settings: GraphCanvasSettings
    @Environment(\.dismiss) private var dismiss

    internal var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(NSLocalizedString("graph.settings.title", comment: "Graph settings title"))
                .font(.title3.bold())
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
            HStack {
                Spacer()
                Button(NSLocalizedString("graph.settings.done", comment: "Close graph settings")) {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 360)
    }
}
