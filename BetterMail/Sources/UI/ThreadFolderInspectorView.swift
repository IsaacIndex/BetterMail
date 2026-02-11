import AppKit
import SwiftUI

internal struct ThreadFolderInspectorView: View {
    internal let folder: ThreadFolder
    internal let minimapModel: FolderMinimapModel?
    internal let summaryState: ThreadSummaryState?
    internal let canRegenerateSummary: Bool
    internal let onRegenerateSummary: (() -> Void)?
    internal let onMinimapJump: (CGPoint) -> Void
    internal let onJumpToLatest: () -> Void
    internal let onJumpToOldest: () -> Void
    internal let onPreview: (String, ThreadFolderColor) -> Void
    internal let onSave: (String, ThreadFolderColor) -> Void

    internal static let minimapHeight: CGFloat = 160

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var draftTitle: String
    @State private var draftColor: Color
    @State private var baselineTitle: String
    @State private var baselineColor: ThreadFolderColor
    @State private var isResettingDraft = false
    @State private var pendingSaveTask: Task<Void, Never>?

    internal init(folder: ThreadFolder,
                  minimapModel: FolderMinimapModel?,
                  summaryState: ThreadSummaryState?,
                  canRegenerateSummary: Bool,
                  onRegenerateSummary: (() -> Void)?,
                  onMinimapJump: @escaping (CGPoint) -> Void,
                  onJumpToLatest: @escaping () -> Void,
                  onJumpToOldest: @escaping () -> Void,
                  onPreview: @escaping (String, ThreadFolderColor) -> Void,
                  onSave: @escaping (String, ThreadFolderColor) -> Void) {
        self.folder = folder
        self.minimapModel = minimapModel
        self.summaryState = summaryState
        self.canRegenerateSummary = canRegenerateSummary
        self.onRegenerateSummary = onRegenerateSummary
        self.onMinimapJump = onMinimapJump
        self.onJumpToLatest = onJumpToLatest
        self.onJumpToOldest = onJumpToOldest
        self.onPreview = onPreview
        self.onSave = onSave
        let initialColor = Color(red: folder.color.red,
                                 green: folder.color.green,
                                 blue: folder.color.blue,
                                 opacity: folder.color.alpha)
        _draftTitle = State(initialValue: folder.title)
        _draftColor = State(initialValue: initialColor)
        _baselineTitle = State(initialValue: folder.title)
        _baselineColor = State(initialValue: folder.color)
    }

    internal var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString("threadcanvas.folder.inspector.title",
                                   comment: "Title for the folder inspector panel"))
                .font(.headline)

            Divider()

            folderMinimapSection

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    folderNameField
                    folderColorPicker
                    folderSummaryField
                    folderPreview
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
        .onDisappear {
            flushPendingSave()
        }
    }

    private var folderMinimapSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(NSLocalizedString("threadcanvas.folder.inspector.minimap",
                                       comment: "Folder minimap section label"))
                    .font(.caption)
                    .foregroundStyle(inspectorSecondaryForegroundStyle)
                Spacer()
                Button(action: onJumpToOldest) {
                    Image(systemName: "arrow.up.to.line.compact")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .controlSize(.mini)
                .disabled(!hasMinimapNodes)
                .accessibilityLabel(NSLocalizedString("threadcanvas.folder.inspector.minimap.jump.oldest",
                                                      comment: "Accessibility label for jump to oldest folder node"))
                .help(NSLocalizedString("threadcanvas.folder.inspector.minimap.jump.oldest",
                                        comment: "Help text for jump to oldest folder node"))
                Button(action: onJumpToLatest) {
                    Image(systemName: "arrow.down.to.line.compact")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .controlSize(.mini)
                .disabled(!hasMinimapNodes)
                .accessibilityLabel(NSLocalizedString("threadcanvas.folder.inspector.minimap.jump.latest",
                                                      comment: "Accessibility label for jump to latest folder node"))
                .help(NSLocalizedString("threadcanvas.folder.inspector.minimap.jump.latest",
                                        comment: "Help text for jump to latest folder node"))
            }
            FolderMinimapSurface(model: minimapModel,
                                 foreground: inspectorPrimaryForegroundStyle,
                                 secondaryForeground: inspectorSecondaryForegroundStyle,
                                 onJump: onMinimapJump)
            .frame(height: Self.minimapHeight)
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

    private var folderSummaryField: some View {
        let summaryText = summaryState?.text ?? ""
        let statusText = summaryState?.statusMessage ?? ""
        let placeholder = NSLocalizedString("threadcanvas.folder.inspector.summary.empty",
                                            comment: "Placeholder when no folder summary is available")
        let displayText = summaryText.isEmpty ? (statusText.isEmpty ? placeholder : statusText) : summaryText
        let isSummarizing = summaryState?.isSummarizing == true

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(NSLocalizedString("threadcanvas.folder.inspector.summary",
                                       comment: "Folder summary label"))
                    .font(.caption)
                    .foregroundStyle(inspectorSecondaryForegroundStyle)
                if let onRegenerateSummary {
                    Button(action: onRegenerateSummary) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .controlSize(.mini)
                    .disabled(!canRegenerateSummary || isSummarizing)
                    .accessibilityLabel(NSLocalizedString("threadcanvas.folder.inspector.summary.regenerate",
                                                          comment: "Accessibility label for regenerating a folder summary"))
                    .help(NSLocalizedString("threadcanvas.folder.inspector.summary.regenerate",
                                            comment: "Help text for regenerating a folder summary"))
                }
                if isSummarizing {
                    ProgressView().controlSize(.mini)
                }
                Spacer()
            }
            ScrollView {
                Text(displayText)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(minHeight: 96, maxHeight: 160)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.15))
            .cornerRadius(8)
            .opacity(summaryText.isEmpty ? 0.75 : 1)
        }
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

    private var hasMinimapNodes: Bool {
        guard let minimapModel else { return false }
        return !minimapModel.nodes.isEmpty
    }

    private func updatePreviewIfNeeded() {
        guard !isResettingDraft else { return }
        let color = draftFolderColor
        onPreview(draftTitle, color)
        scheduleSaveIfNeeded(title: draftTitle, color: color)
    }

    private func resetDraft(with folder: ThreadFolder) {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
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

    private func scheduleSaveIfNeeded(title: String, color: ThreadFolderColor) {
        guard title != baselineTitle || color != baselineColor else { return }
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            onSave(title, color)
            baselineTitle = title
            baselineColor = color
        }
    }

    private func flushPendingSave() {
        guard !isResettingDraft else { return }
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        let color = draftFolderColor
        guard draftTitle != baselineTitle || color != baselineColor else { return }
        onSave(draftTitle, color)
        baselineTitle = draftTitle
        baselineColor = color
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

internal struct FolderMinimapSurface: View {
    let model: FolderMinimapModel?
    let foreground: Color
    let secondaryForeground: Color
    let onJump: (CGPoint) -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.25))
                    )

                if let model, !model.nodes.isEmpty {
                    Canvas { context, size in
                        let pointsByID = Dictionary(uniqueKeysWithValues: model.nodes.map { node in
                            (node.id, point(for: node, in: size))
                        })

                        for edge in model.edges {
                            guard let source = pointsByID[edge.sourceID],
                                  let destination = pointsByID[edge.destinationID] else {
                                continue
                            }
                            var path = Path()
                            path.move(to: source)
                            path.addLine(to: destination)
                            context.stroke(path,
                                           with: .color(secondaryForeground.opacity(0.7)),
                                           lineWidth: 1.5)
                        }

                        for node in model.nodes {
                            let center = point(for: node, in: size)
                            let rect = CGRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7)
                            context.fill(Path(ellipseIn: rect), with: .color(foreground))
                        }
                    }
                } else {
                    Text(NSLocalizedString("threadcanvas.folder.inspector.minimap.empty",
                                           comment: "Placeholder text when minimap has no nodes"))
                        .font(.caption)
                        .foregroundStyle(secondaryForeground)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 10)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        guard model != nil else { return }
                        let normalizedPoint = Self.normalizedPoint(value.location, in: proxy.size)
                        onJump(normalizedPoint)
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(NSLocalizedString("threadcanvas.folder.inspector.minimap.accessibility.label",
                                                  comment: "Accessibility label for folder minimap"))
            .accessibilityHint(NSLocalizedString("threadcanvas.folder.inspector.minimap.accessibility.hint",
                                                 comment: "Accessibility hint for folder minimap"))
            .help(NSLocalizedString("threadcanvas.folder.inspector.minimap.help",
                                    comment: "Help text for folder minimap"))
        }
    }

    private func point(for node: FolderMinimapNode, in size: CGSize) -> CGPoint {
        let horizontalPadding: CGFloat = 10
        let verticalPadding: CGFloat = 10
        let width = max(size.width - (horizontalPadding * 2), 1)
        let height = max(size.height - (verticalPadding * 2), 1)
        let x = horizontalPadding + (node.normalizedX * width)
        let y = verticalPadding + (node.normalizedY * height)
        return CGPoint(x: x, y: y)
    }

    internal static func normalizedPoint(_ location: CGPoint, in size: CGSize) -> CGPoint {
        guard size.width > 0, size.height > 0 else {
            return CGPoint(x: 0.5, y: 0.5)
        }
        let normalizedX = min(max(location.x / size.width, 0), 1)
        let normalizedY = min(max(location.y / size.height, 0), 1)
        return CGPoint(x: normalizedX, y: normalizedY)
    }
}
