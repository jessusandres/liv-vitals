import LivCore
import SwiftUI

/// Two-ring sunburst of a folder: the inner ring shows its children, the outer ring their children.
struct SunburstView: View {
    let root: DiskNode
    /// Name shown in the center for `root`, e.g. "Home" instead of the user name.
    let title: String
    let canGoUp: Bool
    @Binding var hovered: URL?
    let color: (DiskNode) -> Color
    let onOpen: (DiskNode) -> Void
    let onCenterTap: () -> Void
    /// Items of the right-click menu for a segment.
    var menuItems: ((DiskNode) -> AnyView)?

    private struct Segment: Identifiable {
        let node: DiskNode
        let depth: Int
        let start: Double
        let end: Double
        var id: URL { node.url }
    }

    private var segments: [Segment] {
        var result: [Segment] = []
        func walk(_ node: DiskNode, depth: Int, start: Double, span: Double) {
            guard node.size.bytes > 0 else { return }
            var cursor = start
            for child in node.children {
                let childSpan = span * Double(child.size.bytes) / Double(node.size.bytes)
                // Children are sorted largest first, so everything after a sliver is a sliver too.
                guard childSpan >= 0.8 else { break }
                result.append(Segment(node: child, depth: depth, start: cursor, end: cursor + childSpan))
                if depth < 2, child.isDirectory {
                    walk(child, depth: depth + 1, start: cursor, span: childSpan)
                }
                cursor += childSpan
            }
        }
        walk(root, depth: 1, start: -90, span: 360)
        return result
    }

    var body: some View {
        // Laid out once per render and the hovered node resolved once: from the drawn segments first (what the ring
        // hover sets), and only for a list row that is not drawn (a sliver or a deeper level) by walking the tree.
        let segments = self.segments
        let centerNode = hovered.flatMap { url in segments.first { $0.node.url == url }?.node ?? root.node(at: url) } ?? root
        return GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                ForEach(segments) { segment in
                    let isHovered = hovered == segment.node.url
                    RingSegment(
                        start: segment.start,
                        end: segment.end,
                        inner: segment.depth == 1 ? 0.40 : 0.71,
                        outer: segment.depth == 1 ? 0.69 : 0.97
                    )
                    .fill(color(segment.node).opacity(segment.depth == 1 ? 0.95 : 0.6))
                    .brightness(isHovered ? 0.12 : 0)
                    .opacity(hovered == nil || isHovered ? 1 : 0.55)
                    .onHover { inside in
                        if inside { hovered = segment.node.url } else if hovered == segment.node.url { hovered = nil }
                    }
                    .onTapGesture { onOpen(segment.node) }
                    .accessibilityElement()
                    .accessibilityLabel(AccessibilityText.sunburstSegment(
                        name: segment.node.name,
                        size: segment.node.size.formatted,
                        isDirectory: segment.node.isDirectory
                    ))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { onOpen(segment.node) }
                    .contextMenu {
                        if let menuItems { menuItems(segment.node) }
                    }
                }

                Circle()
                    .fill(.regularMaterial)
                    .frame(width: side * 0.38, height: side * 0.38)
                    .overlay {
                        VStack(spacing: 4) {
                            Text(hovered == nil ? title : centerNode.name)
                                .font(.headline)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                            Text(centerNode.size.formatted)
                                .font(.system(size: side * 0.045, weight: .semibold, design: .rounded))
                                .contentTransition(.numericText())
                            if hovered == nil, canGoUp {
                                Text("Click to go up")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(side * 0.03)
                    }
                    .onTapGesture(perform: onCenterTap)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(canGoUp ? .isButton : [])
                    .accessibilityAction(named: "Go up") { if canGoUp { onCenterTap() } }
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .motion(.easeOut(duration: 0.15), value: hovered)
        }
    }
}

/// A slice of a ring between two angles (degrees) and two radii (fractions of the half side).
nonisolated struct RingSegment: Shape {
    var start: Double
    var end: Double
    var inner: Double
    var outer: Double

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let gap = end - start > 2 ? 0.4 : 0
        var path = Path()
        path.addArc(center: center, radius: radius * outer, startAngle: .degrees(start + gap), endAngle: .degrees(end - gap), clockwise: false)
        path.addArc(center: center, radius: radius * inner, startAngle: .degrees(end - gap), endAngle: .degrees(start + gap), clockwise: true)
        path.closeSubpath()
        return path
    }
}
