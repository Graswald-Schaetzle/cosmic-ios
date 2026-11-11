import SwiftUI

enum CaptureTourTarget: Hashable { case tourPanel, map, liveCard, reset, expand, finish, done, reviewPreview, reviewActions }

struct CaptureTourAnchors: PreferenceKey {
    static let defaultValue: [CaptureTourTarget: Anchor<CGRect>] = [:]
    static func reduce(value: inout [CaptureTourTarget: Anchor<CGRect>], nextValue: () -> [CaptureTourTarget: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    func captureTourTarget(_ target: CaptureTourTarget) -> some View {
        transformAnchorPreference(key: CaptureTourAnchors.self, value: .bounds) { anchors, bounds in
            anchors[target] = bounds
        }
    }
}

/// The same overlay follows real controls throughout capture, review and save.
struct CaptureCoachMark: View {
    let walkthrough: CaptureWalkthrough
    let target: CGRect?
    let availableSize: CGSize
    var safeAreaInsets = EdgeInsets()
    var highlightsMap = false
    let canReview: Bool
    var inspecting = false
    var hasPreview = true
    var avoiding: CGRect? = nil
    var panel: CGRect? = nil
    var visibleRegion: CGRect? = nil
    var warning: String? = nil
    let action: () -> Void

    var body: some View {
        CaptureTourOverlay(target: target, availableSize: availableSize, safeAreaInsets: safeAreaInsets,
            avoiding: avoiding, panel: panel, visibleRegion: visibleRegion, dimOpacity: target == nil ? 0.3 : 0.6) {
            CaptureWalkthroughCard(walkthrough: walkthrough, inspecting: inspecting, hasPreview: hasPreview,
                canReview: canReview, warning: warning, action: action)
        }
    }
}

struct CaptureTourOverlay<Content: View>: View {
    let target: CGRect?
    let availableSize: CGSize
    var safeAreaInsets = EdgeInsets()
    var avoiding: CGRect? = nil
    var panel: CGRect? = nil
    var visibleRegion: CGRect? = nil
    var dimOpacity = 0.6
    @ViewBuilder let content: () -> Content
    @State private var cardHeight: CGFloat = 220
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let frame = CaptureTourPlacement.frame(size: availableSize, height: cardHeight,
            preferredWidth: typeSize.isAccessibilitySize ? 380 : 320,
            target: target, avoiding: avoiding, panel: panel)
        let width = frame.width, height = frame.height
        let x = frame.minX, y = frame.minY
        let hole = target?.insetBy(dx: -5, dy: -5)
        ZStack(alignment: .topLeading) {
            Path { path in
                path.addRect(CGRect(x: -safeAreaInsets.leading, y: -safeAreaInsets.top,
                    width: availableSize.width + safeAreaInsets.leading + safeAreaInsets.trailing,
                    height: availableSize.height + safeAreaInsets.top + safeAreaInsets.bottom))
                if let region = visibleRegion ?? hole {
                    path.addRoundedRect(in: region, cornerSize: CGSize(width: 14, height: 14))
                }
                if let hole, let region = visibleRegion, !region.intersects(hole) {
                    path.addRoundedRect(in: hole, cornerSize: CGSize(width: 14, height: 14))
                }
            }
            .fill(.black.opacity(dimOpacity), style: FillStyle(eoFill: true))
            .allowsHitTesting(false).accessibilityHidden(true)
            if let hole {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(CaptureTourStyle.accent, lineWidth: 2)
                    .frame(width: hole.width, height: hole.height)
                    .overlay {
                        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
                            let opacity = reduceMotion ? 0.25 : 0.2 + 0.1 * sin(timeline.date.timeIntervalSinceReferenceDate * 3)
                            RoundedRectangle(cornerRadius: 14).stroke(CaptureTourStyle.accent.opacity(opacity), lineWidth: 8)
                                .frame(width: hole.width, height: hole.height)
                        }
                    }
                    .position(x: hole.midX, y: hole.midY)
                    .allowsHitTesting(false).accessibilityHidden(true)
                CaptureTourLeader(card: frame, target: hole)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            ScrollView {
                content().padding(14)
                    .background { GeometryReader { geometry in
                        Color.clear.onAppear { cardHeight = geometry.size.height }
                            .onChange(of: geometry.size.height) { _, value in cardHeight = value }
                    } }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: width, height: height)
            .background(Color(red: 0.04, green: 0.06, blue: 0.07), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.16), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
            .offset(x: x, y: y)
            .accessibilityIdentifier("capture-tour-overlay")
        }
    }
}

/// Connect the teaching card to the real target, including targets on either side
/// of an expanded preview. The dotted tail continues just inside large panels.
private struct CaptureTourLeader: View {
    let card: CGRect
    let target: CGRect

    var body: some View {
        Canvas { context, _ in
            guard let arrow = CaptureTourArrowGeometry(card: card, target: target) else { return }
            // Paint the complete connector together. Drawing a separate dark head
            // over an already-coloured shaft cuts a visible notch into the join.
            var path = Path()
            path.move(to: arrow.start)
            path.addCurve(to: arrow.shaftJoin, control1: arrow.control1, control2: arrow.control2)
            path.addLine(to: arrow.tip)
            path.move(to: arrow.headLeft)
            path.addLine(to: arrow.tip)
            path.addLine(to: arrow.headRight)
            let stroke = StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
            context.stroke(path, with: .color(.black.opacity(0.75)),
                           style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            context.stroke(path, with: .color(CaptureTourStyle.accent), style: stroke)
            if arrow.isPanel {
                var leader = Path()
                leader.move(to: arrow.forwardPoint(distance: 7))
                leader.addLine(to: arrow.forwardPoint(distance: 28))
                context.stroke(leader, with: .color(CaptureTourStyle.accent.opacity(0.6)),
                               style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2, 4]))
            }
        }
    }
}

/// One geometry source for the curve, its straight terminal shaft and the head.
/// The last 24 points stay straight, even when the card and target have a large
/// vertical offset and almost no horizontal gap.
struct CaptureTourArrowGeometry {
    let start: CGPoint
    let tip: CGPoint
    let shaftJoin: CGPoint
    let control1: CGPoint
    let control2: CGPoint
    let headLeft: CGPoint
    let headRight: CGPoint
    let direction: CGVector
    let isPanel: Bool

    init?(card: CGRect, target: CGRect) {
        guard [card.minX, card.minY, card.width, card.height,
               target.minX, target.minY, target.width, target.height].allSatisfy({ $0.isFinite }),
              card.width > 0, card.height > 0, target.width > 0, target.height > 0,
              !card.intersects(target) else { return nil }
        func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
            min(max(value, lower), max(lower, upper))
        }
        let start: CGPoint
        let tip: CGPoint
        let exit: CGVector
        isPanel = target.width > 100 && target.height > 100
        let inset: CGFloat = isPanel ? 16 : -3
        if card.maxX <= target.minX {
            start = CGPoint(x: card.maxX + 5, y: card.midY)
            tip = CGPoint(x: max(target.minX + inset, card.maxX + 22),
                          y: clamp(card.midY - 20, target.minY + 12, target.maxY - 12))
            exit = CGVector(dx: 1, dy: 0)
        } else if card.minX >= target.maxX {
            start = CGPoint(x: card.minX - 5, y: card.midY)
            tip = CGPoint(x: min(target.maxX - inset, card.minX - 22),
                          y: clamp(card.midY - 20, target.minY + 12, target.maxY - 12))
            exit = CGVector(dx: -1, dy: 0)
        } else if card.maxY <= target.minY {
            start = CGPoint(x: clamp(target.midX, card.minX + 20, card.maxX - 20), y: card.maxY + 5)
            tip = CGPoint(x: clamp(start.x + 16, target.minX + 12, target.maxX - 12),
                          y: max(target.minY + inset, card.maxY + 22))
            exit = CGVector(dx: 0, dy: 1)
        } else {
            start = CGPoint(x: clamp(target.midX, card.minX + 20, card.maxX - 20), y: card.minY - 5)
            tip = CGPoint(x: clamp(start.x + 16, target.minX + 12, target.maxX - 12),
                          y: min(target.maxY - inset, card.minY - 22))
            exit = CGVector(dx: 0, dy: -1)
        }
        let length = hypot(tip.x - start.x, tip.y - start.y)
        guard length >= 16 else { return nil }
        let direction = CGVector(dx: (tip.x - start.x) / length, dy: (tip.y - start.y) / length)
        // Short gaps use a straight connector instead of cramming a bend inside
        // the head. Longer connectors ease into a clearly straight final shaft.
        let terminalLength: CGFloat = length <= 36 ? length : 24
        let join = CGPoint(x: tip.x - direction.dx * terminalLength,
                           y: tip.y - direction.dy * terminalLength)
        let remaining = length - terminalLength
        let gap = exit.dx != 0 ? abs(tip.x - start.x) : abs(tip.y - start.y)
        let bend = min(30, gap * 0.45, remaining * 0.3)
        self.start = start
        self.tip = tip
        self.direction = direction
        shaftJoin = join
        control1 = CGPoint(x: start.x + exit.dx * bend, y: start.y + exit.dy * bend)
        control2 = CGPoint(x: join.x - direction.dx * bend, y: join.y - direction.dy * bend)
        let base = CGPoint(x: tip.x - direction.dx * 11, y: tip.y - direction.dy * 11)
        headLeft = CGPoint(x: base.x - direction.dy * 6.6, y: base.y + direction.dx * 6.6)
        headRight = CGPoint(x: base.x + direction.dy * 6.6, y: base.y - direction.dx * 6.6)
    }

    func forwardPoint(distance: CGFloat) -> CGPoint {
        CGPoint(x: tip.x + direction.dx * distance, y: tip.y + direction.dy * distance)
    }
}

/// Reserve space before positioning teaching, so it never covers the preview.
enum CaptureTourPlacement {
    static func frame(size: CGSize, height: CGFloat, preferredWidth: CGFloat = 320,
                      target: CGRect?, avoiding: CGRect?, panel: CGRect?) -> CGRect {
        if let panel {
            let fittedHeight = min(height, panel.height)
            return CGRect(x: panel.minX, y: size.width > size.height ? panel.maxY - fittedHeight : panel.minY,
                          width: panel.width, height: fittedHeight)
        }
        let obstacle = avoiding ?? target
        let landscape = size.width > size.height
        let left: CGFloat = landscape ? 76 : 16
        var width = min(preferredWidth, size.width - left - 16)
        var maxHeight = size.height - 32
        var x = left, y: CGFloat = 16
        if let obstacle {
            if landscape && obstacle.minX - left >= 240 {
                width = min(width, obstacle.minX - left - 28)
                x = obstacle.minX - width - 28
                y = max(16, min(size.height - min(height, maxHeight) - 16, size.height * 0.62 - height / 2))
            } else if landscape && size.width - obstacle.maxX >= 256 {
                x = obstacle.maxX + 28
                width = min(width, size.width - x - 16)
                y = max(16, min(size.height - min(height, maxHeight) - 16, size.height * 0.62 - height / 2))
            } else if obstacle.minY > 180 {
                maxHeight = obstacle.minY - 32
                x = max(16, (size.width - width) / 2)
                y = max(16, obstacle.minY - min(height, maxHeight) - 16)
            } else if size.height - obstacle.maxY > 180 {
                y = obstacle.maxY + 16
                maxHeight = size.height - y - 16
            }
        } else if landscape {
            y = max(16, min(size.height - min(height, maxHeight) - 16, size.height * 0.62 - height / 2))
        }
        return CGRect(x: x, y: y, width: width, height: min(height, maxHeight))
    }
}
