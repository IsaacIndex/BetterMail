import AppKit
import SpriteKit

internal final class GraphSceneNode: SKNode {
    private struct LabelNodes {
        let container: SKNode
        let background: SKShapeNode
    }

    internal let graphID: String
    internal let kind: GraphNodeKind
    internal let threadID: String?
    private let labelSide: CGFloat
    private let shapeContainer = SKNode()
    private let disc: SKShapeNode
    private let ring: SKShapeNode
    private let messageDetail: SKShapeNode?
    private let labelContainer: SKNode?
    private let labelBackground: SKShapeNode?
    private var breathRing: SKShapeNode?

    internal init(graphID: String,
                  kind: GraphNodeKind,
                  threadID: String?,
                  radius: CGFloat,
                  title: String?,
                  fillColor: NSColor,
                  strokeColor: NSColor,
                  strokeWidth: CGFloat,
                  showsLabel: Bool,
                  labelSide: CGFloat = 1) {
        self.graphID = graphID
        self.kind = kind
        self.threadID = threadID
        self.labelSide = labelSide
        disc = SKShapeNode(path: Self.nodePath(kind: kind, radius: radius))
        ring = SKShapeNode(path: Self.nodePath(kind: kind, radius: radius + 2))
        if kind == .message {
            messageDetail = SKShapeNode(path: Self.messageDetailPath(radius: radius))
        } else {
            messageDetail = nil
        }
        if showsLabel, let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let labelNodes: LabelNodes
            switch kind {
            case .message:
                labelNodes = Self.makeMessageSummaryLabel(title, radius: radius)
            case .center, .thread:
                labelNodes = Self.makeThreadLabel(title, radius: radius)
            }
            labelContainer = labelNodes.container
            labelBackground = labelNodes.background
        } else {
            labelContainer = nil
            labelBackground = nil
        }
        super.init()
        isUserInteractionEnabled = false
        shapeContainer.zPosition = 2
        disc.fillColor = fillColor
        disc.strokeColor = strokeColor
        disc.lineWidth = strokeWidth
        ring.fillColor = .clear
        ring.strokeColor = .clear
        ring.lineWidth = 0
        shapeContainer.addChild(ring)
        shapeContainer.addChild(disc)
        if let messageDetail {
            messageDetail.strokeColor = DesignTokens.Graph.panelNS.withAlphaComponent(0.72)
            messageDetail.lineWidth = 1.0
            messageDetail.lineCap = .round
            messageDetail.lineJoin = .round
            messageDetail.zPosition = 3
            shapeContainer.addChild(messageDetail)
        }
        addChild(shapeContainer)
        if let labelContainer {
            addChild(labelContainer)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    internal func applySelection(isSelected: Bool, isHovered: Bool, isDimmed: Bool) {
        alpha = isDimmed ? 0.22 : 1
        if isSelected {
            disc.fillColor = DesignTokens.Graph.accentSoftNS
            disc.strokeColor = DesignTokens.Graph.accentNS
            disc.lineWidth = 2
            messageDetail?.strokeColor = DesignTokens.Graph.accentNS.withAlphaComponent(0.62)
            labelBackground?.strokeColor = DesignTokens.Graph.accentNS.withAlphaComponent(0.48)
            labelBackground?.lineWidth = 1
        } else if isHovered {
            disc.strokeColor = DesignTokens.Graph.accentNS
            disc.lineWidth = 1.6
            messageDetail?.strokeColor = DesignTokens.Graph.accentNS.withAlphaComponent(0.58)
            labelBackground?.strokeColor = DesignTokens.Graph.accentNS.withAlphaComponent(0.35)
            labelBackground?.lineWidth = 1
        } else {
            messageDetail?.strokeColor = DesignTokens.Graph.panelNS.withAlphaComponent(0.72)
            labelBackground?.strokeColor = DesignTokens.Graph.lineNS.withAlphaComponent(0.85)
            labelBackground?.lineWidth = 0.8
        }
    }

    internal func setBaseStyle(fillColor: NSColor, strokeColor: NSColor, strokeWidth: CGFloat) {
        disc.fillColor = fillColor
        disc.strokeColor = strokeColor
        disc.lineWidth = strokeWidth
        messageDetail?.strokeColor = DesignTokens.Graph.panelNS.withAlphaComponent(0.72)
    }

    internal func setBranchAngle(_ angle: CGFloat) {
        guard kind == .message else { return }
        shapeContainer.zRotation = angle
        let forward = CGVector(dx: cos(angle), dy: sin(angle))
        let normal = CGVector(dx: -sin(angle), dy: cos(angle))
        labelContainer?.position = CGPoint(x: forward.dx * 132 + normal.dx * labelSide * 68,
                                           y: forward.dy * 132 + normal.dy * labelSide * 68)
    }

    internal func updateBreath(elapsedTime: TimeInterval, phase: Double, reduceMotion: Bool) {
        guard !reduceMotion else {
            breathRing?.removeFromParent()
            breathRing = nil
            setScale(1)
            return
        }
        let scale = 1 + CGFloat(sin((elapsedTime + phase * 1_000) * 0.0025)) * 0.06
        setScale(scale)
        if breathRing == nil {
            let radius = max(disc.frame.width, disc.frame.height) / 2 + 10
            let aura = SKShapeNode(circleOfRadius: radius)
            aura.fillColor = .clear
            aura.strokeColor = DesignTokens.Graph.liveNS.withAlphaComponent(0.35)
            aura.lineWidth = 0.8
            aura.zPosition = -1
            aura.run(.repeatForever(.sequence([
                .group([.scale(to: 1.18, duration: 1.7), .fadeAlpha(to: 0, duration: 1.7)]),
                .group([.scale(to: 1.0, duration: 0), .fadeAlpha(to: 0.35, duration: 0)])
            ])))
            breathRing = aura
            addChild(aura)
        }
    }

    internal func runWaterPulse(wateredCount: Int, reduceMotion: Bool) {
        let radius = max(disc.frame.width, disc.frame.height) / 2 + 18 + CGFloat(wateredCount * 4)
        let aura = SKShapeNode(circleOfRadius: radius)
        aura.fillColor = .clear
        aura.strokeColor = DesignTokens.Graph.waterNS.withAlphaComponent(reduceMotion ? 0.3 : 0.6)
        aura.lineWidth = 1.1
        aura.zPosition = -2
        addChild(aura)
        if reduceMotion {
            aura.run(.sequence([.fadeOut(withDuration: 0.35), .removeFromParent()]))
        } else {
            aura.setScale(0.8)
            aura.run(.sequence([
                .group([.scale(to: 1.5, duration: 2.4), .fadeOut(withDuration: 2.4)]),
                .removeFromParent()
            ]))
        }
    }

    internal func runSprout(reduceMotion: Bool) {
        guard !reduceMotion else {
            alpha = 1
            return
        }
        setScale(0.01)
        alpha = 0
        run(.sequence([
            .group([.scale(to: 1.2, duration: 0.38), .fadeIn(withDuration: 0.24)]),
            .scale(to: 1.0, duration: 0.17)
        ]))
    }

    internal func runPrune(action: GraphCompostAction, reduceMotion: Bool, completion: @escaping () -> Void) {
        if reduceMotion {
            run(.sequence([.fadeOut(withDuration: 0.25), .run(completion)]))
            return
        }
        switch action {
        case .snip:
            run(.sequence([
                .group([
                    .fadeOut(withDuration: 1.6),
                    .moveBy(x: CGFloat.random(in: -8...8), y: -42, duration: 1.6),
                    .rotate(byAngle: 0.72, duration: 1.6)
                ]),
                .run(completion)
            ]))
        case .archive:
            run(.sequence([
                .group([
                    .fadeAlpha(to: 0.25, duration: 1.0),
                    .scale(to: 0.85, duration: 1.0)
                ]),
                .run(completion)
            ]))
        }
    }

    private static func nodePath(kind: GraphNodeKind, radius: CGFloat) -> CGPath {
        switch kind {
        case .center, .thread:
            return CGPath(ellipseIn: CGRect(x: -radius,
                                            y: -radius,
                                            width: radius * 2,
                                            height: radius * 2),
                          transform: nil)
        case .message:
            return messageLeafPath(radius: radius)
        }
    }

    private static func messageLeafPath(radius: CGFloat) -> CGPath {
        let width = radius * 2.9
        let height = radius * 1.9
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -width / 2, y: 0))
        path.addQuadCurve(to: CGPoint(x: 0, y: height / 2),
                          control: CGPoint(x: -width * 0.34, y: height * 0.52))
        path.addQuadCurve(to: CGPoint(x: width / 2, y: 0),
                          control: CGPoint(x: width * 0.34, y: height * 0.52))
        path.addQuadCurve(to: CGPoint(x: 0, y: -height / 2),
                          control: CGPoint(x: width * 0.34, y: -height * 0.52))
        path.addQuadCurve(to: CGPoint(x: -width / 2, y: 0),
                          control: CGPoint(x: -width * 0.34, y: -height * 0.52))
        path.closeSubpath()
        return path
    }

    private static func messageDetailPath(radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -radius * 0.95, y: 0))
        path.addLine(to: CGPoint(x: radius * 0.95, y: 0))
        path.move(to: CGPoint(x: -radius * 0.18, y: 0))
        path.addLine(to: CGPoint(x: radius * 0.34, y: radius * 0.34))
        path.move(to: CGPoint(x: -radius * 0.18, y: 0))
        path.addLine(to: CGPoint(x: radius * 0.34, y: -radius * 0.34))
        return path
    }

    private static func makeThreadLabel(_ title: String, radius: CGFloat) -> LabelNodes {
        let isCenterNode = radius > 34
        let lines = isCenterNode
            ? [readableLabelText(title, maxCharacters: 18)]
            : wrappedLines(for: readableLabelText(title, maxCharacters: 116),
                           maxLineLength: 30,
                           maxLines: 3)
        let fontSize: CGFloat = isCenterNode ? 11 : 10.4
        let lineHeight: CGFloat = isCenterNode ? 13.5 : 12.6
        let horizontalPadding: CGFloat = isCenterNode ? 12 : 14
        let verticalPadding: CGFloat = isCenterNode ? 5 : 8
        let lineNodes = lines.map { line -> SKLabelNode in
            let labelNode = SKLabelNode(text: line)
            labelNode.fontName = "HelveticaNeue-Semibold"
            labelNode.fontSize = fontSize
            labelNode.fontColor = DesignTokens.Graph.inkNS
            labelNode.verticalAlignmentMode = .center
            labelNode.horizontalAlignmentMode = .center
            labelNode.zPosition = 2
            return labelNode
        }
        let measuredWidth = lineNodes.map(\.frame.width).max() ?? 0
        let labelSize = CGSize(width: min(max(measuredWidth + horizontalPadding * 2, isCenterNode ? 58 : 132), isCenterNode ? 92 : 224),
                               height: CGFloat(lineNodes.count) * lineHeight + verticalPadding * 2)
        let background = SKShapeNode(rectOf: labelSize, cornerRadius: 8)
        background.fillColor = DesignTokens.Graph.backgroundNS.withAlphaComponent(0.9)
        background.strokeColor = DesignTokens.Graph.lineNS.withAlphaComponent(0.85)
        background.lineWidth = 0.8
        background.zPosition = 1
        let container = SKNode()
        container.position = CGPoint(x: 0,
                                     y: -radius - labelSize.height / 2 - (isCenterNode ? 8 : 11))
        container.zPosition = 4
        container.addChild(background)
        let firstY = CGFloat(lineNodes.count - 1) * lineHeight / 2
        for (index, labelNode) in lineNodes.enumerated() {
            labelNode.position = CGPoint(x: 0, y: firstY - CGFloat(index) * lineHeight)
            container.addChild(labelNode)
        }
        return LabelNodes(container: container, background: background)
    }

    private static func makeMessageSummaryLabel(_ text: String, radius: CGFloat) -> LabelNodes {
        let cardSize = CGSize(width: 230, height: 58)
        let background = SKShapeNode(rectOf: cardSize, cornerRadius: 8)
        background.fillColor = DesignTokens.Graph.panelNS.withAlphaComponent(0.94)
        background.strokeColor = DesignTokens.Graph.lineNS.withAlphaComponent(0.9)
        background.lineWidth = 0.9
        background.zPosition = 1

        let accent = SKShapeNode(rectOf: CGSize(width: 3, height: cardSize.height - 16), cornerRadius: 1.5)
        accent.fillColor = DesignTokens.Graph.Botanical.messageNS.withAlphaComponent(0.8)
        accent.strokeColor = .clear
        accent.position = CGPoint(x: -cardSize.width / 2 + 10, y: 0)
        accent.zPosition = 2

        let container = SKNode()
        container.position = CGPoint(x: 0, y: -radius - 56)
        container.zPosition = 6
        container.addChild(background)
        container.addChild(accent)

        let lines = wrappedLines(for: readableSummaryText(text), maxLineLength: 38, maxLines: 3)
        let lineHeight: CGFloat = 13.2
        let firstY = CGFloat(lines.count - 1) * lineHeight / 2
        for (index, line) in lines.enumerated() {
            let labelNode = SKLabelNode(text: line)
            labelNode.fontName = "HelveticaNeue-Medium"
            labelNode.fontSize = 10.2
            labelNode.fontColor = DesignTokens.Graph.inkSecondaryNS
            labelNode.verticalAlignmentMode = .center
            labelNode.horizontalAlignmentMode = .left
            labelNode.position = CGPoint(x: -cardSize.width / 2 + 20,
                                         y: firstY - CGFloat(index) * lineHeight)
            labelNode.zPosition = 3
            container.addChild(labelNode)
        }
        return LabelNodes(container: container, background: background)
    }

    private static func readableLabelText(_ title: String, maxCharacters: Int = 68) -> String {
        let collapsed = title
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > maxCharacters else { return collapsed }
        let remaining = maxCharacters - 3
        let prefixCount = max(16, Int(Double(remaining) * 0.68))
        let suffixCount = max(0, remaining - prefixCount)
        return "\(collapsed.prefix(prefixCount))...\(collapsed.suffix(suffixCount))"
    }

    private static func readableSummaryText(_ text: String, maxCharacters: Int = 126) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > maxCharacters else { return collapsed }
        return "\(collapsed.prefix(maxCharacters - 3))..."
    }

    private static func wrappedLines(for text: String,
                                     maxLineLength: Int,
                                     maxLines: Int) -> [String] {
        let words = text.split(separator: " ").flatMap {
            splitWord(String($0), maxLineLength: maxLineLength)
        }
        guard !words.isEmpty else { return [] }
        var lines: [String] = []
        var current = ""
        var didTruncate = false
        for word in words {
            if current.isEmpty {
                current = word
            } else if current.count + word.count + 1 <= maxLineLength {
                current += " \(word)"
            } else {
                guard lines.count < maxLines - 1 else {
                    didTruncate = true
                    break
                }
                lines.append(current)
                current = word
            }
        }
        if lines.count < maxLines && !current.isEmpty {
            lines.append(current)
        }
        if didTruncate, let lastLine = lines.indices.last {
            lines[lastLine] = ellipsizedLine(lines[lastLine], maxLineLength: maxLineLength)
        }
        return lines.isEmpty ? [readableSummaryText(text, maxCharacters: maxLineLength)] : lines
    }

    private static func splitWord(_ word: String, maxLineLength: Int) -> [String] {
        guard word.count > maxLineLength, maxLineLength > 1 else { return [word] }
        var chunks: [String] = []
        var remainder = word[...]
        while !remainder.isEmpty {
            let endIndex = remainder.index(remainder.startIndex,
                                           offsetBy: min(maxLineLength, remainder.count))
            chunks.append(String(remainder[..<endIndex]))
            remainder = remainder[endIndex...]
        }
        return chunks
    }

    private static func ellipsizedLine(_ line: String, maxLineLength: Int) -> String {
        guard line.count > 3 else { return "..." }
        if line.count + 3 <= maxLineLength {
            return "\(line)..."
        }
        return "\(line.prefix(max(1, maxLineLength - 3)))..."
    }
}
