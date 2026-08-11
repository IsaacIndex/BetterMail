import AppKit
import SpriteKit

/// A deliberately restrained graph mark: a dot, a focus ring, and plain text.
/// Keeping labels separate from the dot lets zoom fade text without shrinking
/// the node's hit target.
internal final class ObsidianGraphSceneNode: SKNode {
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
        hitTarget = SKShapeNode(circleOfRadius: max(radius + 7, 11))
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
                             hasFocusedNode: Bool) {
        let shouldDimForFocus = hasFocusedNode && !isSelected && !isHovered && !isNeighbor
        alpha = isDimmed ? 0.12 : shouldDimForFocus ? 0.22 : 1
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
