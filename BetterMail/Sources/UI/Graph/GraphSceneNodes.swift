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
    private let remainingDashRing: SKShapeNode?
    private let remainingPlus: SKShapeNode?
    private let labelContainer: SKNode?
    private let labelBackground: SKShapeNode?
    private var theme: DesignTokens.Graph.AppTheme.Palette
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
                  theme: DesignTokens.Graph.AppTheme.Palette,
                  labelSide: CGFloat = 1) {
        self.graphID = graphID
        self.kind = kind
        self.threadID = threadID
        self.labelSide = labelSide
        self.theme = theme
        disc = SKShapeNode(path: Self.nodePath(kind: kind, radius: radius))
        ring = SKShapeNode(path: Self.nodePath(kind: kind, radius: radius + 2))
        if kind == .message {
            messageDetail = SKShapeNode(path: Self.messageDetailPath(radius: radius))
        } else {
            messageDetail = nil
        }
        if kind == .remaining {
            remainingDashRing = SKShapeNode(path: Self.dashedCirclePath(radius: radius + 5,
                                                                        segmentCount: 16,
                                                                        segmentFraction: 0.56))
            remainingPlus = SKShapeNode(path: Self.plusPath(radius: max(8, radius * 0.34)))
        } else {
            remainingDashRing = nil
            remainingPlus = nil
        }
        if showsLabel, let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let labelNodes: LabelNodes
            switch kind {
            case .message:
                labelNodes = Self.makeMessageSummaryLabel(title, radius: radius, theme: theme)
            case .center, .thread, .remaining:
                labelNodes = Self.makeThreadLabel(title, radius: radius, kind: kind, theme: theme)
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
            messageDetail.strokeColor = theme.panelNS.withAlphaComponent(0.72)
            messageDetail.lineWidth = 1.0
            messageDetail.lineCap = .round
            messageDetail.lineJoin = .round
            messageDetail.zPosition = 3
            shapeContainer.addChild(messageDetail)
        }
        if let remainingDashRing {
            remainingDashRing.fillColor = .clear
            remainingDashRing.strokeColor = theme.archiveNS.withAlphaComponent(0.72)
            remainingDashRing.lineWidth = 1.4
            remainingDashRing.lineCap = .round
            remainingDashRing.lineJoin = .round
            remainingDashRing.zPosition = 4
            shapeContainer.addChild(remainingDashRing)
        }
        if let remainingPlus {
            remainingPlus.fillColor = .clear
            remainingPlus.strokeColor = theme.archiveNS.withAlphaComponent(0.86)
            remainingPlus.lineWidth = 1.8
            remainingPlus.lineCap = .round
            remainingPlus.lineJoin = .round
            remainingPlus.zPosition = 5
            shapeContainer.addChild(remainingPlus)
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
        if kind == .remaining {
            let isEmphasized = isSelected || isHovered
            let emphasisColor = isEmphasized ? theme.accentNS : theme.archiveNS
            disc.fillColor = theme.panelSecondaryNS.withAlphaComponent(0.34)
            disc.strokeColor = .clear
            disc.lineWidth = 0
            ring.strokeColor = .clear
            ring.lineWidth = 0
            remainingDashRing?.strokeColor = emphasisColor.withAlphaComponent(isEmphasized ? 0.95 : 0.72)
            remainingDashRing?.lineWidth = isSelected ? 2.2 : isHovered ? 2.0 : 1.4
            remainingPlus?.strokeColor = emphasisColor.withAlphaComponent(isEmphasized ? 0.98 : 0.82)
            remainingPlus?.lineWidth = isSelected ? 2.2 : 1.8
            labelBackground?.strokeColor = emphasisColor.withAlphaComponent(isEmphasized ? 0.48 : 0.28)
            labelBackground?.lineWidth = isEmphasized ? 1 : 0.8
            return
        }
        if isSelected {
            disc.fillColor = theme.accentSoftNS
            disc.strokeColor = theme.accentNS
            disc.lineWidth = 2
            messageDetail?.strokeColor = theme.accentNS.withAlphaComponent(0.62)
            labelBackground?.strokeColor = theme.accentNS.withAlphaComponent(0.48)
            labelBackground?.lineWidth = 1
        } else if isHovered {
            disc.strokeColor = theme.accentNS
            disc.lineWidth = 1.6
            messageDetail?.strokeColor = theme.accentNS.withAlphaComponent(0.58)
            labelBackground?.strokeColor = theme.accentNS.withAlphaComponent(0.35)
            labelBackground?.lineWidth = 1
        } else {
            messageDetail?.strokeColor = theme.panelNS.withAlphaComponent(0.72)
            labelBackground?.strokeColor = theme.lineNS.withAlphaComponent(0.85)
            labelBackground?.lineWidth = 0.8
        }
    }

    internal func setBaseStyle(fillColor: NSColor,
                               strokeColor: NSColor,
                               strokeWidth: CGFloat,
                               theme: DesignTokens.Graph.AppTheme.Palette) {
        self.theme = theme
        disc.fillColor = fillColor
        if kind == .remaining {
            disc.strokeColor = .clear
            disc.lineWidth = 0
            remainingDashRing?.strokeColor = strokeColor.withAlphaComponent(0.72)
            remainingDashRing?.lineWidth = strokeWidth
            remainingPlus?.strokeColor = strokeColor.withAlphaComponent(0.86)
        } else {
            disc.strokeColor = strokeColor
            disc.lineWidth = strokeWidth
        }
        messageDetail?.strokeColor = theme.panelNS.withAlphaComponent(0.72)
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
            aura.strokeColor = theme.liveNS.withAlphaComponent(0.35)
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
        aura.strokeColor = theme.waterNS.withAlphaComponent(reduceMotion ? 0.3 : 0.6)
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
        case .center, .thread, .remaining:
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

    private static func dashedCirclePath(radius: CGFloat,
                                         segmentCount: Int,
                                         segmentFraction: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let count = max(3, segmentCount)
        let fraction = min(max(segmentFraction, 0.1), 0.92)
        let step = CGFloat.pi * 2 / CGFloat(count)
        for index in 0..<count {
            let startAngle = CGFloat(index) * step
            let endAngle = startAngle + step * fraction
            path.move(to: CGPoint(x: cos(startAngle) * radius,
                                  y: sin(startAngle) * radius))
            path.addArc(center: .zero,
                        radius: radius,
                        startAngle: startAngle,
                        endAngle: endAngle,
                        clockwise: false)
        }
        return path
    }

    private static func plusPath(radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -radius, y: 0))
        path.addLine(to: CGPoint(x: radius, y: 0))
        path.move(to: CGPoint(x: 0, y: -radius))
        path.addLine(to: CGPoint(x: 0, y: radius))
        return path
    }

    private static func makeThreadLabel(_ title: String,
                                        radius: CGFloat,
                                        kind: GraphNodeKind,
                                        theme: DesignTokens.Graph.AppTheme.Palette) -> LabelNodes {
        let isCenterNode = kind == .center
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
            labelNode.fontName = "HelveticaNeue-Medium"
            labelNode.fontSize = fontSize
            labelNode.fontColor = theme.inkNS
            labelNode.verticalAlignmentMode = .center
            labelNode.horizontalAlignmentMode = .center
            labelNode.zPosition = 2
            return labelNode
        }
        let measuredWidth = lineNodes.map(\.frame.width).max() ?? 0
        let labelSize = CGSize(width: min(max(measuredWidth + horizontalPadding * 2, isCenterNode ? 58 : 132), isCenterNode ? 92 : 224),
                               height: CGFloat(lineNodes.count) * lineHeight + verticalPadding * 2)
        let background = SKShapeNode(rectOf: labelSize, cornerRadius: 8)
        background.fillColor = theme.backgroundNS.withAlphaComponent(0.9)
        background.strokeColor = theme.lineNS.withAlphaComponent(0.85)
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

    private static func makeMessageSummaryLabel(_ text: String,
                                                radius: CGFloat,
                                                theme: DesignTokens.Graph.AppTheme.Palette) -> LabelNodes {
        let cardSize = CGSize(width: 230, height: 58)
        let background = SKShapeNode(rectOf: cardSize, cornerRadius: 8)
        background.fillColor = theme.panelNS.withAlphaComponent(0.94)
        background.strokeColor = theme.lineNS.withAlphaComponent(0.9)
        background.lineWidth = 0.9
        background.zPosition = 1

        let accent = SKShapeNode(rectOf: CGSize(width: 3, height: cardSize.height - 16), cornerRadius: 1.5)
        accent.fillColor = theme.accentNS.withAlphaComponent(0.8)
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
            labelNode.fontColor = theme.inkSecondaryNS
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

internal struct GraphSummaryOccluder: Equatable {
    internal let id: String
    internal let position: CGPoint
    internal let radius: CGFloat
}

internal enum GraphSummaryPlacement {
    internal static let candidateAngles: [CGFloat] = [
        0,
        .pi / 4,
        .pi / 2,
        .pi * 3 / 4,
        .pi,
        -.pi * 3 / 4,
        -.pi / 2,
        -.pi / 4
    ]

    internal static func preferredAngle(origin: CGPoint,
                                        boxSize: CGSize,
                                        occluders: [GraphSummaryOccluder],
                                        previousAngle: CGFloat?) -> CGFloat {
        candidateAngles.max { lhs, rhs in
            score(angle: lhs, origin: origin, boxSize: boxSize, occluders: occluders, previousAngle: previousAngle) <
            score(angle: rhs, origin: origin, boxSize: boxSize, occluders: occluders, previousAngle: previousAngle)
        } ?? 0
    }

    internal static func calloutCenter(origin: CGPoint, boxSize: CGSize, angle: CGFloat) -> CGPoint {
        let distance = 14 + max(boxSize.width, boxSize.height) * 0.35
        return CGPoint(x: origin.x + cos(angle) * distance,
                       y: origin.y + sin(angle) * distance)
    }

    internal static func smoothedAngle(previous: CGFloat?, picked: CGFloat, amount: CGFloat = 0.18) -> CGFloat {
        guard let previous else { return picked }
        let delta = normalizedAngle(picked - previous)
        guard abs(delta) > 0.001 else { return picked }
        return normalizedAngle(previous + delta * amount)
    }

    private static func score(angle: CGFloat,
                              origin: CGPoint,
                              boxSize: CGSize,
                              occluders: [GraphSummaryOccluder],
                              previousAngle: CGFloat?) -> CGFloat {
        let center = calloutCenter(origin: origin, boxSize: boxSize, angle: angle)
        let nearestDistance = occluders
            .filter { hypot($0.position.x - origin.x, $0.position.y - origin.y) > 0.1 }
            .map { hypot($0.position.x - center.x, $0.position.y - center.y) - $0.radius }
            .min() ?? 10_000
        let hysteresis: CGFloat
        if let previousAngle {
            hysteresis = max(0, cos(normalizedAngle(angle - previousAngle))) * 600
        } else {
            hysteresis = 0
        }
        return nearestDistance + hysteresis
    }

    private static func normalizedAngle(_ angle: CGFloat) -> CGFloat {
        var value = angle
        while value > .pi { value -= .pi * 2 }
        while value < -.pi { value += .pi * 2 }
        return value
    }
}

internal final class SummaryCalloutNode: SKNode {
    internal let graphID: String
    private let background = SKShapeNode()
    private let tether = SKShapeNode()
    private let theme: DesignTokens.Graph.AppTheme.Palette
    private var labelNodes: [SKLabelNode] = []
    private var displayedText = ""
    internal private(set) var boxSize = CGSize(width: 120, height: 40)

    internal init(graphID: String,
                  text: String,
                  theme: DesignTokens.Graph.AppTheme.Palette) {
        self.graphID = graphID
        self.theme = theme
        super.init()
        isUserInteractionEnabled = false
        zPosition = 8
        tether.fillColor = .clear
        tether.strokeColor = theme.lineNS.withAlphaComponent(0.8)
        tether.lineWidth = 1
        tether.lineCap = .round
        tether.zPosition = -1
        background.fillColor = theme.panelNS.withAlphaComponent(0.96)
        background.strokeColor = theme.lineNS.withAlphaComponent(0.92)
        background.lineWidth = 1
        background.zPosition = 1
        addChild(tether)
        addChild(background)
        updateText(text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    @discardableResult
    internal func update(text: String,
                         anchorPosition: CGPoint,
                         anchorRadius: CGFloat,
                         occluders: [GraphSummaryOccluder],
                         previousAngle: CGFloat?) -> CGFloat {
        updateText(text)
        let pickedAngle = GraphSummaryPlacement.preferredAngle(origin: anchorPosition,
                                                              boxSize: boxSize,
                                                              occluders: occluders,
                                                              previousAngle: previousAngle)
        let angle = GraphSummaryPlacement.smoothedAngle(previous: previousAngle, picked: pickedAngle)
        let center = GraphSummaryPlacement.calloutCenter(origin: anchorPosition,
                                                        boxSize: boxSize,
                                                        angle: angle)
        position = center
        updateTether(anchorPosition: anchorPosition, anchorRadius: anchorRadius, angle: angle)
        return angle
    }

    internal var occlusionRadius: CGFloat {
        max(boxSize.width, boxSize.height) * 0.5 + 12
    }

    internal func applyDimmed(_ isDimmed: Bool) {
        alpha = isDimmed ? 0.22 : 1
    }

    private func updateText(_ text: String) {
        let cleaned = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard cleaned != displayedText else { return }
        displayedText = cleaned
        labelNodes.forEach { $0.removeFromParent() }
        labelNodes = []

        let lines = Self.wrappedLines(for: cleaned, maxLineLength: 28, maxLines: 2)
        let fontSize: CGFloat = 10.5
        let lineHeight: CGFloat = 13.4
        let labels = lines.map { line -> SKLabelNode in
            let label = SKLabelNode(text: line)
            label.fontName = "HelveticaNeue-Medium"
            label.fontSize = fontSize
            label.fontColor = theme.inkNS
            label.verticalAlignmentMode = .center
            label.horizontalAlignmentMode = .left
            label.zPosition = 2
            return label
        }
        let measuredWidth = min(160, max(70, (labels.map(\.frame.width).max() ?? 0) + 22))
        boxSize = CGSize(width: measuredWidth,
                         height: CGFloat(labels.count) * lineHeight + 14)
        background.path = CGPath(roundedRect: CGRect(x: -boxSize.width / 2,
                                                     y: -boxSize.height / 2,
                                                     width: boxSize.width,
                                                     height: boxSize.height),
                                 cornerWidth: 5,
                                 cornerHeight: 5,
                                 transform: nil)
        let firstY = CGFloat(labels.count - 1) * lineHeight / 2
        for (index, label) in labels.enumerated() {
            label.position = CGPoint(x: -boxSize.width / 2 + 11,
                                     y: firstY - CGFloat(index) * lineHeight)
            labelNodes.append(label)
            addChild(label)
        }
    }

    private func updateTether(anchorPosition: CGPoint, anchorRadius: CGFloat, angle: CGFloat) {
        let unit = CGVector(dx: cos(angle), dy: sin(angle))
        let start = CGPoint(x: anchorPosition.x + unit.dx * anchorRadius - position.x,
                            y: anchorPosition.y + unit.dy * anchorRadius - position.y)
        let edgeScale = min(
            unit.dx == 0 ? .greatestFiniteMagnitude : (boxSize.width / 2) / abs(unit.dx),
            unit.dy == 0 ? .greatestFiniteMagnitude : (boxSize.height / 2) / abs(unit.dy)
        )
        let end = CGPoint(x: -unit.dx * edgeScale,
                          y: -unit.dy * edgeScale)
        let path = CGMutablePath()
        path.move(to: start)
        path.addLine(to: end)
        tether.path = path
    }

    private static func wrappedLines(for text: String, maxLineLength: Int, maxLines: Int) -> [String] {
        let words = text.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        var lines: [String] = []
        var current = ""
        for word in words {
            if current.isEmpty {
                current = word
            } else if current.count + word.count + 1 <= maxLineLength {
                current += " \(word)"
            } else {
                guard lines.count < maxLines - 1 else {
                    lines.append(ellipsized(current, maxLineLength: maxLineLength))
                    return lines
                }
                lines.append(current)
                current = word
            }
        }
        if !current.isEmpty && lines.count < maxLines {
            lines.append(current)
        }
        return lines
    }

    private static func ellipsized(_ line: String, maxLineLength: Int) -> String {
        guard line.count > 3 else { return "..." }
        return "\(line.prefix(max(1, maxLineLength - 3)))..."
    }
}

internal enum GraphSpline {
    internal static func points(from start: CGPoint,
                                to end: CGPoint,
                                seed: UInt32,
                                config: GraphCurlConfig,
                                anchor: CGPoint? = nil) -> [CGPoint] {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let distance = hypot(dx, dy)
        guard distance > 0.1, config.curl > 0 else { return [start, end] }
        let unit = CGVector(dx: dx / distance, dy: dy / distance)
        let normal = CGVector(dx: -unit.dy, dy: unit.dx)
        let falloffPower = max(0.12, 1 - config.curlFalloff * 0.7)
        let middlePoints = [CGFloat(0.25), 0.5, 0.75].enumerated().map { index, t -> CGPoint in
            let noise = deterministicNoise(seed: seed, salt: UInt32(index + 1))
            let fallbackSign: CGFloat = noise >= 0.5 ? 1 : -1
            let sign: CGFloat
            if config.asymmetricArc, let anchor {
                sign = outwardArcSign(from: start, to: end, anchor: anchor, fallbackSign: fallbackSign)
            } else {
                sign = fallbackSign
            }
            let variability = 1 + (noise * 2 - 1) * config.curlVariability
            let taper = pow(max(0, sin(.pi * t)), falloffPower)
            let offset = config.curl * variability * taper * sign
            return CGPoint(x: start.x + dx * t + normal.dx * offset,
                           y: start.y + dy * t + normal.dy * offset)
        }
        return [start] + middlePoints + [end]
    }

    internal static func path(from start: CGPoint,
                              to end: CGPoint,
                              seed: UInt32,
                              config: GraphCurlConfig,
                              anchor: CGPoint? = nil) -> CGMutablePath {
        let splinePoints = points(from: start, to: end, seed: seed, config: config, anchor: anchor)
        let path = CGMutablePath()
        path.move(to: start)
        guard splinePoints.count > 2 else {
            path.addLine(to: end)
            return path
        }
        let tension = max(0, min(1, config.splineTension))
        for index in 0..<(splinePoints.count - 1) {
            let p0 = splinePoints[max(0, index - 1)]
            let p1 = splinePoints[index]
            let p2 = splinePoints[index + 1]
            let p3 = splinePoints[min(splinePoints.count - 1, index + 2)]
            let cp1 = CGPoint(x: p1.x + (p2.x - p0.x) * tension / 6,
                              y: p1.y + (p2.y - p0.y) * tension / 6)
            let cp2 = CGPoint(x: p2.x - (p3.x - p1.x) * tension / 6,
                              y: p2.y - (p3.y - p1.y) * tension / 6)
            path.addCurve(to: p2, control1: cp1, control2: cp2)
        }
        return path
    }

    internal static func sampledPoints(from start: CGPoint,
                                       to end: CGPoint,
                                       seed: UInt32,
                                       config: GraphCurlConfig,
                                       anchor: CGPoint? = nil,
                                       samples: Int) -> [CGPoint] {
        let splinePoints = points(from: start, to: end, seed: seed, config: config, anchor: anchor)
        guard splinePoints.count > 1 else { return splinePoints }
        let tension = max(0, min(1, config.splineTension))
        let segmentCount = splinePoints.count - 1
        let samplesPerSegment = max(2, Int(round(CGFloat(max(samples, 2)) / CGFloat(segmentCount))))
        var sampled: [CGPoint] = []
        sampled.reserveCapacity(segmentCount * samplesPerSegment + 1)

        for index in 0..<segmentCount {
            let p0 = splinePoints[max(0, index - 1)]
            let p1 = splinePoints[index]
            let p2 = splinePoints[index + 1]
            let p3 = splinePoints[min(splinePoints.count - 1, index + 2)]
            let cp1 = CGPoint(x: p1.x + (p2.x - p0.x) * tension / 6,
                              y: p1.y + (p2.y - p0.y) * tension / 6)
            let cp2 = CGPoint(x: p2.x - (p3.x - p1.x) * tension / 6,
                              y: p2.y - (p3.y - p1.y) * tension / 6)
            let firstSample = index == 0 ? 0 : 1
            for sampleIndex in firstSample...samplesPerSegment {
                let t = CGFloat(sampleIndex) / CGFloat(samplesPerSegment)
                sampled.append(cubicPoint(from: p1, control1: cp1, control2: cp2, to: p2, t: t))
            }
        }
        return sampled
    }

    internal static func ribbonPoints(from start: CGPoint,
                                      to end: CGPoint,
                                      seed: UInt32,
                                      config: GraphCurlConfig,
                                      anchor: CGPoint?,
                                      widthStart: CGFloat,
                                      widthEnd: CGFloat,
                                      tipMin: CGFloat,
                                      taperPow: CGFloat,
                                      samples: Int) -> (left: [CGPoint], right: [CGPoint]) {
        let centerline = sampledPoints(from: start,
                                       to: end,
                                       seed: seed,
                                       config: config,
                                       anchor: anchor,
                                       samples: samples)
        guard centerline.count >= 2 else { return ([], []) }
        var left: [CGPoint] = []
        var right: [CGPoint] = []
        left.reserveCapacity(centerline.count)
        right.reserveCapacity(centerline.count)

        for index in centerline.indices {
            let t = CGFloat(index) / CGFloat(centerline.count - 1)
            let eased = pow(t, taperPow)
            let width = max(tipMin, widthStart + (widthEnd - widthStart) * eased)
            let previous = centerline[max(centerline.startIndex, index - 1)]
            let next = centerline[min(centerline.index(before: centerline.endIndex), index + 1)]
            let tangent = CGVector(dx: next.x - previous.x, dy: next.y - previous.y)
            let magnitude = max(0.001, hypot(tangent.dx, tangent.dy))
            let unit = CGVector(dx: tangent.dx / magnitude, dy: tangent.dy / magnitude)
            let normal = CGVector(dx: -unit.dy, dy: unit.dx)
            let halfWidth = width / 2
            let point = centerline[index]
            left.append(CGPoint(x: point.x + normal.dx * halfWidth,
                                y: point.y + normal.dy * halfWidth))
            right.append(CGPoint(x: point.x - normal.dx * halfWidth,
                                 y: point.y - normal.dy * halfWidth))
        }
        return (left, right)
    }

    internal static func ribbonPath(from start: CGPoint,
                                    to end: CGPoint,
                                    seed: UInt32,
                                    config: GraphCurlConfig,
                                    anchor: CGPoint?,
                                    widthStart: CGFloat,
                                    widthEnd: CGFloat,
                                    tipMin: CGFloat,
                                    taperPow: CGFloat,
                                    samples: Int) -> CGMutablePath {
        let ribbon = ribbonPoints(from: start,
                                  to: end,
                                  seed: seed,
                                  config: config,
                                  anchor: anchor,
                                  widthStart: widthStart,
                                  widthEnd: widthEnd,
                                  tipMin: tipMin,
                                  taperPow: taperPow,
                                  samples: samples)
        let path = CGMutablePath()
        guard let first = ribbon.left.first else { return path }
        path.move(to: first)
        for point in ribbon.left.dropFirst() {
            path.addLine(to: point)
        }
        for point in ribbon.right.reversed() {
            path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }

    internal static func outwardArcSign(from start: CGPoint,
                                        to end: CGPoint,
                                        anchor: CGPoint,
                                        fallbackSign: CGFloat = 1) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let distance = hypot(dx, dy)
        guard distance > 0.1 else { return normalizedSign(fallbackSign) }
        let unit = CGVector(dx: dx / distance, dy: dy / distance)
        let normal = CGVector(dx: -unit.dy, dy: unit.dx)
        let midpoint = CGPoint(x: (start.x + end.x) / 2,
                               y: (start.y + end.y) / 2)
        let anchorVector = CGVector(dx: midpoint.x - anchor.x,
                                    dy: midpoint.y - anchor.y)
        let dot = normal.dx * anchorVector.dx + normal.dy * anchorVector.dy
        guard abs(dot) > 0.001 else { return normalizedSign(fallbackSign) }
        return dot >= 0 ? 1 : -1
    }

    private static func cubicPoint(from start: CGPoint,
                                   control1: CGPoint,
                                   control2: CGPoint,
                                   to end: CGPoint,
                                   t: CGFloat) -> CGPoint {
        let inverseT = 1 - t
        let x = inverseT * inverseT * inverseT * start.x +
            3 * inverseT * inverseT * t * control1.x +
            3 * inverseT * t * t * control2.x +
            t * t * t * end.x
        let y = inverseT * inverseT * inverseT * start.y +
            3 * inverseT * inverseT * t * control1.y +
            3 * inverseT * t * t * control2.y +
            t * t * t * end.y
        return CGPoint(x: x, y: y)
    }

    private static func normalizedSign(_ value: CGFloat) -> CGFloat {
        value >= 0 ? 1 : -1
    }

    private static func deterministicNoise(seed: UInt32, salt: UInt32) -> CGFloat {
        var value = seed &+ salt &* 0x9E37_79B9
        value ^= value >> 16
        value &*= 0x7FEB_352D
        value ^= value >> 15
        value &*= 0x846C_A68B
        value ^= value >> 16
        return CGFloat(value & 0xFFFF) / CGFloat(UInt16.max)
    }
}

internal func splinePath(from start: CGPoint,
                         to end: CGPoint,
                         seed: UInt32,
                         config: GraphCurlConfig) -> CGMutablePath {
    GraphSpline.path(from: start, to: end, seed: seed, config: config)
}
