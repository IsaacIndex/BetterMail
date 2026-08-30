import AppKit
import SpriteKit

/// AppKit accessibility proxy for a graph mark that is rendered by SpriteKit
/// rather than backed by its own `NSView`.
///
/// `SKNode` can carry accessibility metadata, but macOS does not reliably
/// expose a usable AX frame for a custom node. A retained
/// `NSAccessibilityElement` child of the `SKView` gives assistive clients a
/// stable parent-space frame and a real press action.
internal final class ObsidianGraphAccessibilityElement: NSAccessibilityElement,
                                                          NSAccessibilityButton {
    private var onPress: (() -> Void)?
    private weak var organizerParentView: NSView?
    private var organizerFrameInParentSpace = CGRect.null
    private var organizerScreenFrame = CGRect.null
    private var organizerLabel: String?
    private var organizerIdentifier: String?

    internal func update(parent: NSView,
                         frameInParentSpace: CGRect,
                         label: String,
                         help: String?,
                         identifier: String?,
                         value: Any?,
                         isSelected: Bool,
                         customActions: [NSAccessibilityCustomAction],
                         onPress: @escaping () -> Void) {
        self.onPress = onPress
        organizerParentView = parent
        organizerFrameInParentSpace = frameInParentSpace
        organizerScreenFrame = NSAccessibility.screenRect(fromView: parent,
                                                           rect: frameInParentSpace)
        organizerLabel = label
        organizerIdentifier = identifier
        setAccessibilityElement(true)
        setAccessibilityEnabled(true)
        setAccessibilityRole(.button)
        setAccessibilityRoleDescription(NSAccessibility.Role.button.description(with: nil))
        setAccessibilityLabel(label)
        setAccessibilityHelp(help)
        setAccessibilityIdentifier(identifier)
        setAccessibilityValue(value)
        setAccessibilitySelected(isSelected)
        setAccessibilityParent(parent)
        setAccessibilityFrameInParentSpace(frameInParentSpace)
        setAccessibilityFrame(organizerScreenFrame)
        setAccessibilityCustomActions(customActions)
    }

    /// External accessibility clients query the retained proxy rather than
    /// the hidden SpriteKit node. Re-derive screen space from the retained
    /// parent-space frame so moving the window cannot leave a stale AX frame.
    override func accessibilityFrame() -> NSRect {
        guard let organizerParentView else { return organizerScreenFrame }
        return NSAccessibility.screenRect(fromView: organizerParentView,
                                          rect: organizerFrameInParentSpace)
    }

    override func accessibilityParent() -> Any? {
        organizerParentView
    }

    override func accessibilityLabel() -> String? {
        organizerLabel
    }

    // AppKit imports the role protocol's optional identifier as nonoptional in
    // Swift. Return an empty value for expansion-only nodes that deliberately
    // have no stable organizer identifier.
    override func accessibilityIdentifier() -> String {
        organizerIdentifier ?? ""
    }

    internal func visibleScreenFrame(in parent: NSView) -> CGRect? {
        guard organizerParentView === parent,
              let window = parent.window,
              window.isVisible,
              !window.isMiniaturized,
              window.alphaValue > 0,
              !parent.isHiddenOrHasHiddenAncestor,
              parent.alphaValue > 0,
              !organizerFrameInParentSpace.isNull,
              !organizerFrameInParentSpace.isEmpty,
              organizerFrameInParentSpace.origin.x.isFinite,
              organizerFrameInParentSpace.origin.y.isFinite,
              organizerFrameInParentSpace.width.isFinite,
              organizerFrameInParentSpace.height.isFinite else {
            return nil
        }
        let clippedFrame = organizerFrameInParentSpace.intersection(parent.visibleRect)
        guard !clippedFrame.isNull, !clippedFrame.isEmpty else { return nil }
        let screenFrame = NSAccessibility.screenRect(fromView: parent, rect: clippedFrame)
        guard !screenFrame.isNull,
              !screenFrame.isEmpty,
              screenFrame.origin.x.isFinite,
              screenFrame.origin.y.isFinite,
              screenFrame.width.isFinite,
              screenFrame.height.isFinite else {
            return nil
        }
        guard NSScreen.screens.contains(where: { $0.frame.intersects(screenFrame) }) else {
            return nil
        }
        return screenFrame
    }

    internal func hasVisibleFrame(in parent: NSView) -> Bool {
        visibleScreenFrame(in: parent) != nil
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return false }
        onPress()
        return true
    }
}

/// A deliberately restrained graph mark: a dot, a focus ring, and plain text.
/// Keeping labels separate from the dot lets zoom fade text without shrinking
/// the node's hit target.
internal final class ObsidianGraphSceneNode: SKNode {
    internal static func effectiveHitRadius(radius: CGFloat, nodeScale: CGFloat) -> CGFloat {
        max(radius + 7, 11) * max(1, max(0.55, min(nodeScale, 2.2)))
    }

    internal let graphID: String
    internal let kind: GraphNodeKind
    internal let threadID: String?

    private let radius: CGFloat
    private let hitTarget: SKShapeNode
    private let dot: SKShapeNode
    private let focusRing: SKShapeNode
    private let dashedRing: SKShapeNode?
    private let label: SKLabelNode?
    private var theme: DesignTokens.Graph.AppTheme.Palette
    private var baseFillColor: NSColor
    private var baseStrokeColor: NSColor
    private var nodeScale: CGFloat = 1
    private var labelBaseAlpha: CGFloat = 1
    private var onAccessibilityPress: (() -> Void)?
    private var organizerAccessibilityIdentifier: String?
    private var organizerAccessibilityValue: String?
    private var organizerAccessibilityCustomActions: [NSAccessibilityCustomAction] = []
    private var organizerAccessibilitySelected = false
    private var appKitAccessibilityElement: ObsidianGraphAccessibilityElement?

    /// SpriteKit's macOS accessibility category exposes only the core subset
    /// of AppKit attributes to Swift. These Objective-C-visible accessors add
    /// the identifier, value, selected state, and custom actions queried by
    /// VoiceOver without pretending `SKNode` conforms to the full protocol.
    @objc dynamic var accessibilityIdentifier: String? {
        organizerAccessibilityIdentifier
    }

    @objc dynamic var accessibilityValue: Any? {
        organizerAccessibilityValue
    }

    @objc dynamic var accessibilityCustomActions: [NSAccessibilityCustomAction]? {
        organizerAccessibilityCustomActions
    }

    @objc dynamic var isAccessibilitySelected: Bool {
        organizerAccessibilitySelected
    }

    internal var hasOrganizerAccessibilityDescriptor: Bool {
        organizerAccessibilityIdentifier?.hasPrefix("bettermail.organizer.") == true
            && isAccessibilityEnabled
            && accessibilityRole == NSAccessibility.Role.button.rawValue
    }

    internal func isOrganizerAccessibilityVisible(in view: SKView) -> Bool {
        hasOrganizerAccessibilityDescriptor && isAccessibilityVisible(in: view)
    }

    internal func organizerAccessibilityFrameInScreen(
        in view: SKView
    ) -> CGRect? {
        guard isOrganizerAccessibilityVisible(in: view),
              let appKitAccessibilityElement else { return nil }
        guard let frame = appKitAccessibilityElement.visibleScreenFrame(in: view) else {
            return nil
        }
        guard !frame.isNull,
              !frame.isEmpty,
              frame.origin.x.isFinite,
              frame.origin.y.isFinite,
              frame.width.isFinite,
              frame.height.isFinite else { return nil }
        return frame
    }

    internal func isAccessibilityVisible(in view: SKView) -> Bool {
        guard let appKitAccessibilityElement,
              onAccessibilityPress != nil,
              !isHidden,
              alpha > 0 else {
            return false
        }
        return appKitAccessibilityElement.hasVisibleFrame(in: view)
    }

    internal init(graphID: String,
                  kind: GraphNodeKind,
                  threadID: String?,
                  radius: CGFloat,
                  title: String?,
                  fillColor: NSColor,
                  strokeColor: NSColor,
                  textScale: CGFloat,
                  theme: DesignTokens.Graph.AppTheme.Palette) {
        self.graphID = graphID
        self.kind = kind
        self.threadID = threadID
        self.radius = radius
        self.theme = theme
        baseFillColor = fillColor
        baseStrokeColor = strokeColor
        hitTarget = SKShapeNode(circleOfRadius: Self.effectiveHitRadius(radius: radius,
                                                                       nodeScale: 1))
        dot = SKShapeNode(circleOfRadius: radius)
        focusRing = SKShapeNode(circleOfRadius: radius + 4)
        if kind == .ghostGroup || kind == .remaining {
            dashedRing = SKShapeNode(path: Self.dashedCirclePath(radius: radius + 2.5))
        } else {
            dashedRing = nil
        }
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            let fontSize = max(9, 11 * textScale)
            let font = NSFont.systemFont(ofSize: fontSize,
                                         weight: kind == .center ? .semibold : .regular)
            let label = SKLabelNode(fontNamed: font.fontName)
            label.text = title
            label.fontSize = fontSize
            label.fontColor = theme.inkSecondaryNS
            label.horizontalAlignmentMode = .left
            label.verticalAlignmentMode = .center
            label.position = CGPoint(x: radius + 7, y: 0)
            label.zPosition = 4
            self.label = label
        } else {
            label = nil
        }

        super.init()
        isUserInteractionEnabled = false
        // The frame-backed AppKit proxy is the AX element. Exposing this
        // SpriteKit node as a second AX element creates a duplicate button
        // whose frame is missing in the installed app.
        isAccessibilityElement = false

        hitTarget.fillColor = NSColor.white.withAlphaComponent(0.001)
        hitTarget.strokeColor = .clear
        hitTarget.zPosition = 0
        addChild(hitTarget)

        focusRing.fillColor = .clear
        focusRing.strokeColor = .clear
        focusRing.lineWidth = 0
        focusRing.zPosition = 1
        addChild(focusRing)

        dot.fillColor = fillColor
        dot.strokeColor = strokeColor
        dot.lineWidth = kind == .center ? 1.5 : 1
        dot.zPosition = 2
        addChild(dot)

        if let dashedRing {
            dashedRing.fillColor = .clear
            dashedRing.strokeColor = strokeColor.withAlphaComponent(0.78)
            dashedRing.lineWidth = 1.15
            dashedRing.lineCap = .round
            dashedRing.zPosition = 3
            addChild(dashedRing)
            dot.strokeColor = .clear
        }
        if let label {
            addChild(label)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    internal func configureExpansionAccessibility(label spokenLabel: String,
                                                  onPress: @escaping () -> Void) {
        children.forEach { $0.isAccessibilityElement = false }
        isAccessibilityElement = false
        accessibilityRole = NSAccessibility.Role.button.rawValue
        accessibilityRoleDescription = NSAccessibility.Role.button.description(with: nil)
        accessibilityLabel = spokenLabel
        isAccessibilityEnabled = true
        organizerAccessibilityIdentifier = nil
        organizerAccessibilityValue = nil
        organizerAccessibilityCustomActions = []
        organizerAccessibilitySelected = false
        onAccessibilityPress = onPress
    }

    internal func configureOrganizerAccessibility(
        _ descriptor: OrganizerAccessibilityDescriptor,
        onAction: @escaping (OrganizerAccessibilityAction) -> Bool
    ) {
        children.forEach { $0.isAccessibilityElement = false }
        isAccessibilityElement = false
        accessibilityRole = NSAccessibility.Role.button.rawValue
        accessibilityRoleDescription = NSAccessibility.Role.button.description(with: nil)
        accessibilityLabel = descriptor.label
        accessibilityHelp = descriptor.hint
        organizerAccessibilityIdentifier = descriptor.identifier
        organizerAccessibilityValue = descriptor.isSelected
            ? NSLocalizedString("accessibility.organizer.node.selected",
                                comment: "Selected organizer graph node state")
            : NSLocalizedString("accessibility.organizer.node.not_selected",
                                comment: "Unselected organizer graph node state")
        organizerAccessibilitySelected = descriptor.isSelected
        isAccessibilityEnabled = true
        onAccessibilityPress = { _ = onAction(.activate) }
        organizerAccessibilityCustomActions = descriptor.actions
            .filter { $0 != .activate }
            .map { action in
                NSAccessibilityCustomAction(name: Self.localizedName(for: action)) {
                    onAction(action)
                }
            }
    }

    /// SpriteKit does not derive a usable AppKit accessibility parent or
    /// screen-space frame for these custom nodes. Keep the semantic hit area
    /// synchronized with the rendered camera transform so VoiceOver and other
    /// accessibility clients can focus and activate the actual visible mark.
    @discardableResult
    internal func updateAccessibilityGeometry(in scene: SKScene,
                                               view: SKView)
    -> ObsidianGraphAccessibilityElement? {
        guard let spokenLabel = accessibilityLabel,
              let onAccessibilityPress else {
            return nil
        }
        accessibilityParent = view

        let hitRadius = Self.effectiveHitRadius(radius: radius, nodeScale: nodeScale)
        let lowerLeft = scene.convertPoint(toView: CGPoint(x: position.x - hitRadius,
                                                            y: position.y - hitRadius))
        let upperRight = scene.convertPoint(toView: CGPoint(x: position.x + hitRadius,
                                                             y: position.y + hitRadius))
        let frameInView = CGRect(x: min(lowerLeft.x, upperRight.x),
                                 y: min(lowerLeft.y, upperRight.y),
                                 width: abs(upperRight.x - lowerLeft.x),
                                 height: abs(upperRight.y - lowerLeft.y))
        let screenFrame = NSAccessibility.screenRect(fromView: view, rect: frameInView)
        accessibilityFrame = screenFrame

        let element: ObsidianGraphAccessibilityElement
        if let appKitAccessibilityElement {
            element = appKitAccessibilityElement
        } else {
            guard let created = ObsidianGraphAccessibilityElement.element(
                withRole: .button,
                frame: screenFrame,
                label: spokenLabel,
                parent: view
            ) as? ObsidianGraphAccessibilityElement else {
                return nil
            }
            element = created
        }
        appKitAccessibilityElement = element
        element.update(parent: view,
                       frameInParentSpace: frameInView,
                       label: spokenLabel,
                       help: accessibilityHelp,
                       identifier: organizerAccessibilityIdentifier,
                       value: organizerAccessibilityValue,
                       isSelected: organizerAccessibilitySelected,
                       customActions: organizerAccessibilityCustomActions,
                       onPress: onAccessibilityPress)
        return element
    }

    @objc func accessibilityPerformPress() -> Bool {
        guard let onAccessibilityPress else { return false }
        onAccessibilityPress()
        return true
    }

    private static func localizedName(for action: OrganizerAccessibilityAction) -> String {
        NSLocalizedString("accessibility.organizer.node.action.\(action.rawValue)",
                          comment: "Organizer graph node accessibility action")
    }

    internal func setNodeScale(_ scale: CGFloat) {
        nodeScale = max(0.55, min(scale, 2.2))
        dot.setScale(nodeScale)
        focusRing.setScale(nodeScale)
        dashedRing?.setScale(nodeScale)
        hitTarget.setScale(max(1, nodeScale))
    }

    internal func setBaseStyle(fillColor: NSColor,
                               strokeColor: NSColor,
                               theme: DesignTokens.Graph.AppTheme.Palette) {
        self.theme = theme
        baseFillColor = fillColor
        baseStrokeColor = strokeColor
        dot.fillColor = fillColor
        dot.strokeColor = kind == .ghostGroup || kind == .remaining ? .clear : strokeColor
        dashedRing?.strokeColor = strokeColor.withAlphaComponent(0.78)
        label?.fontColor = theme.inkSecondaryNS
    }

    internal func applyFocus(isSelected: Bool,
                             isHovered: Bool,
                             isNeighbor: Bool,
                             isDimmed: Bool,
                             hasFocusedNode: Bool,
                             snipState: GraphSnipNodeState = .normal) {
        let shouldDimForFocus = hasFocusedNode && !isSelected && !isHovered && !isNeighbor
        let focusAlpha: CGFloat = isDimmed ? 0.12 : shouldDimForFocus ? 0.22 : 1
        switch snipState {
        case .normal:
            alpha = focusAlpha
        case .partial:
            alpha = min(focusAlpha, 0.68)
        case .staged:
            alpha = min(focusAlpha, 0.34)
        }
        if isSelected || isHovered {
            let color = theme.accentNS
            focusRing.strokeColor = color.withAlphaComponent(isSelected ? 0.92 : 0.65)
            focusRing.lineWidth = isSelected ? 2.2 : 1.5
            dot.fillColor = isSelected ? theme.accentSoftNS : baseFillColor
            dot.strokeColor = color
            dot.lineWidth = isSelected ? 1.8 : 1.4
            dashedRing?.strokeColor = color.withAlphaComponent(0.95)
            dashedRing?.lineWidth = 1.8
            label?.fontColor = theme.inkNS
        } else {
            focusRing.strokeColor = .clear
            focusRing.lineWidth = 0
            dot.fillColor = baseFillColor
            dot.strokeColor = kind == .ghostGroup || kind == .remaining ? .clear : baseStrokeColor
            dot.lineWidth = kind == .center ? 1.5 : 1
            dashedRing?.strokeColor = baseStrokeColor.withAlphaComponent(0.78)
            dashedRing?.lineWidth = 1.15
            label?.fontColor = isNeighbor ? theme.inkNS : theme.inkSecondaryNS
        }
        switch snipState {
        case .normal:
            break
        case .partial:
            focusRing.strokeColor = theme.snipNS.withAlphaComponent(0.68)
            focusRing.lineWidth = 1.3
            dashedRing?.strokeColor = theme.snipNS.withAlphaComponent(0.72)
        case .staged:
            focusRing.strokeColor = theme.snipNS.withAlphaComponent(0.92)
            focusRing.lineWidth = 1.8
            dot.strokeColor = theme.snipNS.withAlphaComponent(0.9)
            dashedRing?.strokeColor = theme.snipNS.withAlphaComponent(0.9)
            label?.fontColor = theme.snipNS
        }
    }

    internal func updateLabel(zoomScale: CGFloat,
                              threshold: CGFloat,
                              forceVisible: Bool) {
        guard let label else { return }
        labelBaseAlpha = forceVisible ? 1 : Self.labelAlpha(zoomScale: zoomScale, threshold: threshold)
        label.alpha = labelBaseAlpha
    }

    internal func runWaterPulse(reduceMotion: Bool) {
        removeAction(forKey: "obsidian-water-pulse")
        focusRing.strokeColor = theme.waterNS.withAlphaComponent(0.9)
        focusRing.lineWidth = 2
        guard !reduceMotion else {
            focusRing.run(.sequence([.wait(forDuration: 0.12), .fadeOut(withDuration: 0.08)]),
                          withKey: "obsidian-water-pulse")
            return
        }
        focusRing.alpha = 1
        focusRing.setScale(nodeScale)
        focusRing.run(.sequence([
            .group([.scale(to: nodeScale * 2.3, duration: 0.34), .fadeOut(withDuration: 0.34)]),
            .run { [weak self] in
                self?.focusRing.setScale(self?.nodeScale ?? 1)
                self?.focusRing.alpha = 1
            }
        ]), withKey: "obsidian-water-pulse")
    }

    internal func runSprout(reduceMotion: Bool) {
        guard !reduceMotion else { return }
        setScale(0.72)
        alpha = 0
        run(.group([.scale(to: 1, duration: 0.22), .fadeIn(withDuration: 0.18)]),
            withKey: "obsidian-sprout")
    }

    internal func runSnipTransition(_ change: GraphSnipVisualChange,
                                    reduceMotion: Bool,
                                    delay: TimeInterval) {
        removeAction(forKey: "obsidian-snip-transition")
        let wait = SKAction.wait(forDuration: delay)
        if reduceMotion {
            let targetAlpha: CGFloat = change == .stage ? 0.34 : 1
            alpha = change == .stage ? 1 : 0.34
            run(.sequence([wait, .fadeAlpha(to: targetAlpha, duration: 0.16)]),
                withKey: "obsidian-snip-transition")
            return
        }
        switch change {
        case .stage:
            alpha = 1
            setScale(1)
            run(.sequence([
                wait,
                .group([.scale(to: 0.88, duration: 0.07),
                        .fadeAlpha(to: 0.18, duration: 0.07)]),
                .group([.scale(to: 1, duration: 0.16),
                        .fadeAlpha(to: 0.34, duration: 0.16)])
            ]), withKey: "obsidian-snip-transition")
        case .unstage:
            alpha = 0.34
            setScale(1)
            run(.sequence([
                wait,
                .group([.scale(to: 1, duration: 0.18),
                        .fadeAlpha(to: 1, duration: 0.18)])
            ]), withKey: "obsidian-snip-transition")
        }
    }

    internal func runPrune(action: GraphCompostAction,
                           reduceMotion: Bool,
                           completion: @escaping () -> Void) {
        removeAllActions()
        let tint = action == .archive ? theme.archiveNS : theme.snipNS
        focusRing.strokeColor = tint
        focusRing.lineWidth = 2
        guard !reduceMotion else {
            alpha = 0
            completion()
            return
        }
        run(.sequence([
            .group([.scale(to: 0.28, duration: 0.2), .fadeOut(withDuration: 0.2)]),
            .run(completion)
        ]), withKey: "obsidian-prune")
    }

    internal static func labelAlpha(zoomScale: CGFloat, threshold: CGFloat) -> CGFloat {
        let zoomLevel = log2(max(zoomScale, 0.05))
        return min(max((zoomLevel - threshold + 0.18) / 0.72, 0), 1)
    }

    private static func dashedCirclePath(radius: CGFloat,
                                         segmentCount: Int = 18,
                                         visibleFraction: CGFloat = 0.56) -> CGPath {
        let path = CGMutablePath()
        let step = (.pi * 2) / CGFloat(segmentCount)
        for segment in 0..<segmentCount {
            let start = CGFloat(segment) * step
            let end = start + step * visibleFraction
            path.addArc(center: .zero, radius: radius, startAngle: start, endAngle: end, clockwise: false)
        }
        return path
    }
}
