import AppKit
import SwiftUI

struct ThreadFolderInspectorView: View {
    let folder: ThreadFolder
    let onPreview: (String, ThreadFolderColor) -> Void
    let onSave: (String, ThreadFolderColor) -> Void
    let onCancel: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var draftTitle: String
    @State private var draftColor: Color
    @State private var baselineTitle: String
    @State private var baselineColor: ThreadFolderColor
    @State private var isResettingDraft = false

    init(folder: ThreadFolder,
         onPreview: @escaping (String, ThreadFolderColor) -> Void,
         onSave: @escaping (String, ThreadFolderColor) -> Void,
         onCancel: @escaping () -> Void) {
        self.folder = folder
        self.onPreview = onPreview
        self.onSave = onSave
        self.onCancel = onCancel
        let initialColor = Color(red: folder.color.red,
                                 green: folder.color.green,
                                 blue: folder.color.blue,
                                 opacity: folder.color.alpha)
        _draftTitle = State(initialValue: folder.title)
        _draftColor = State(initialValue: initialColor)
        _baselineTitle = State(initialValue: folder.title)
        _baselineColor = State(initialValue: folder.color)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString("threadcanvas.folder.inspector.title",
                                   comment: "Title for the folder inspector panel"))
                .font(.headline)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    folderNameField
                    folderColorPicker
                    folderPreview
                    actionButtons
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(inspectorPrimaryForegroundStyle)
        .shadow(color: Color.black.opacity(isGlassInspectorEnabled ? 0.35 : 0), radius: 1.2, x: 0, y: 1)
        .background(inspectorBackground)
        .modifier(FolderInspectorColorSchemeModifier(isEnabled: isGlassInspectorEnabled))
        .onChange(of: folder.id) { _, _ in
            resetDraft(with: folder)
        }
    }

    private var folderNameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(NSLocalizedString("threadcanvas.folder.inspector.name",
                                   comment: "Folder name field label"))
                .font(.caption)
                .foregroundStyle(inspectorSecondaryForegroundStyle)
            TextField("", text: $draftTitle)
                .textFieldStyle(.roundedBorder)
                .onChange(of: draftTitle) { _, _ in
                    updatePreviewIfNeeded()
                }
        }
    }

    private var folderColorPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(NSLocalizedString("threadcanvas.folder.inspector.color",
                                   comment: "Folder color picker label"))
                .font(.caption)
                .foregroundStyle(inspectorSecondaryForegroundStyle)
            ColorPicker("", selection: $draftColor, supportsOpacity: true)
                .labelsHidden()
                .onChange(of: draftColor) { _, _ in
                    updatePreviewIfNeeded()
                }
        }
    }

    private var folderPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(NSLocalizedString("threadcanvas.folder.inspector.preview",
                                   comment: "Folder preview label"))
                .font(.caption)
                .foregroundStyle(inspectorSecondaryForegroundStyle)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(draftColor.opacity(0.4))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.4))
                )
                .overlay(alignment: .leading) {
                    Text(draftTitle.isEmpty
                         ? NSLocalizedString("threadcanvas.subject.placeholder",
                                             comment: "Placeholder subject when missing")
                         : draftTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(inspectorPrimaryForegroundStyle)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }
                .frame(height: 72)
        }
    }

    private var actionButtons: some View {
        let hasChanges = draftTitle != baselineTitle || draftFolderColor != baselineColor
        return HStack {
            Button(NSLocalizedString("threadcanvas.folder.inspector.cancel",
                                     comment: "Cancel button title")) {
                onCancel()
                resetDraft(with: folder)
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button(NSLocalizedString("threadcanvas.folder.inspector.save",
                                     comment: "Save button title")) {
                let color = draftFolderColor
                onSave(draftTitle, color)
                baselineTitle = draftTitle
                baselineColor = color
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!hasChanges)
        }
        .padding(.top, 4)
    }

    private var isGlassInspectorEnabled: Bool {
        if #available(macOS 26, *) {
            return !reduceTransparency
        }
        return false
    }

    private var inspectorPrimaryForegroundStyle: Color {
        isGlassInspectorEnabled ? Color.white : Color.primary
    }

    private var inspectorSecondaryForegroundStyle: Color {
        isGlassInspectorEnabled ? Color.white.opacity(0.75) : Color.secondary
    }

    @ViewBuilder
    private var inspectorBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        if reduceTransparency {
            shape
                .fill(Color(nsColor: NSColor.windowBackgroundColor).opacity(0.96))
                .overlay(shape.stroke(Color.white.opacity(0.3)))
        } else if #available(macOS 26, *) {
            shape
                .fill(Color.white.opacity(0.08))
                .glassEffect(
                    .regular
                        .tint(Color.white.opacity(0.2)),
                    in: .rect(cornerRadius: 18)
                )
                .overlay(shape.stroke(Color.white.opacity(0.35)))
                .shadow(color: Color.black.opacity(0.25), radius: 16, y: 8)
        } else {
            shape
                .fill(Color(nsColor: NSColor.windowBackgroundColor).opacity(0.9))
                .overlay(shape.stroke(Color.white.opacity(0.25)))
        }
    }

    private var draftFolderColor: ThreadFolderColor {
        let nsColor = NSColor(draftColor)
        let resolved = nsColor.usingColorSpace(.deviceRGB) ?? nsColor
        return ThreadFolderColor(red: resolved.redComponent,
                                 green: resolved.greenComponent,
                                 blue: resolved.blueComponent,
                                 alpha: resolved.alphaComponent)
    }

    private func updatePreviewIfNeeded() {
        guard !isResettingDraft else { return }
        onPreview(draftTitle, draftFolderColor)
    }

    private func resetDraft(with folder: ThreadFolder) {
        isResettingDraft = true
        draftTitle = folder.title
        draftColor = Color(red: folder.color.red,
                           green: folder.color.green,
                           blue: folder.color.blue,
                           opacity: folder.color.alpha)
        baselineTitle = folder.title
        baselineColor = folder.color
        DispatchQueue.main.async {
            isResettingDraft = false
        }
    }
}

private struct FolderInspectorColorSchemeModifier: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content.colorScheme(.dark)
        } else {
            content
        }
    }
}
