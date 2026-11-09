import AppKit
import LivCore
import SwiftUI

/// The geometry of an indicator, apart from the drawing, so it is tested without drawing anything.
enum IndicatorGeometry {
    static let height: CGFloat = 18
    static let spacing: CGFloat = 4
    static let padding: CGFloat = 2
    static let chartSize = CGSize(width: 30, height: 12)
    static let barSize = CGSize(width: 30, height: 6)
    static let gaugeDiameter: CGFloat = 13
    static let speedMinimumWidth: CGFloat = 50

    /// A line through the values, scaled to `0...ceiling`, inside `size` (origin at the bottom left, as Core Graphics has it).
    static func sparkline(values: [Double], ceiling: Double, in size: CGSize) -> [CGPoint] {
        guard values.count > 1, ceiling > 0 else { return [] }
        let step = size.width / CGFloat(values.count - 1)
        return values.enumerated().map { index, raw in
            let fraction = min(1, max(0, raw / ceiling))
            return CGPoint(x: step * CGFloat(index), y: size.height * CGFloat(fraction))
        }
    }
}

extension IndicatorTint {
    /// nil for the automatic tint, which is drawn as a template image the menu bar colors itself.
    func color(for metric: MetricKind) -> NSColor? {
        switch self {
        case .system: nil
        case .metric: NSColor(metric.color)
        case .purple: .systemPurple
        case .blue: .systemBlue
        case .teal: .systemTeal
        case .pink: .systemPink
        case .orange: .systemOrange
        }
    }
}

extension MetricKind {
    var color: Color {
        switch self {
        case .cpu: Color(red: 0.37, green: 0.34, blue: 1)
        case .memory: Color(red: 0.16, green: 0.42, blue: 1)
        case .gpu: Color(red: 0.55, green: 0.3, blue: 0.95)
        case .disk: Color(red: 0.90, green: 0.34, blue: 0.66)
        case .diskActivity: Color(red: 0.93, green: 0.48, blue: 0.26)
        case .network: Color(red: 0.18, green: 0.62, blue: 0.96)
        case .battery: Color(red: 0.13, green: 0.71, blue: 0.62)
        case .temperature: Color(red: 0.96, green: 0.45, blue: 0.2)
        }
    }
}

/// Draws a menu bar indicator with Core Graphics. SwiftUI's `ImageRenderer` did the same job but made the GPU renderer hold
/// about 110 MB for the first minute after launch; this uses no GPU at all and the image is drawn when the menu bar asks for
/// it. It is also what the Settings preview shows, so the preview and the bar cannot differ. An image is only built again
/// when something it shows changed.
@MainActor
enum IndicatorImageRenderer {
    static let height = IndicatorGeometry.height

    private struct Key: Hashable {
        var setting: IndicatorSetting
        var text: String
        var secondary: String?
        var fraction: Double?
        var history: [Double]
    }

    private static var cache: [MetricKind: (key: Key, image: NSImage)] = [:]

    /// The count of images actually built (the rest came from the cache); tests use it.
    private(set) static var drawn = 0

    static func image(for setting: IndicatorSetting, value: IndicatorValue, history: [Double]) -> NSImage {
        let shown = setting.style == .chart ? history : []
        // The fraction is rounded to a percent: a gauge that moved less than a pixel is not worth drawing again.
        let key = Key(
            setting: setting, text: value.text, secondary: value.secondary,
            fraction: value.fraction.map { ($0 * 100).rounded() / 100 }, history: shown
        )
        if let cached = cache[setting.metric], cached.key == key { return cached.image }

        let tint = setting.tint.color(for: setting.metric)
        let layout = IndicatorLayout(setting: setting, value: value, history: shown)
        let image = NSImage(size: NSSize(width: layout.width, height: height), flipped: false) { _ in
            layout.draw(color: tint ?? .black)
            return true
        }
        // Automatic: a template image, so the menu bar draws it black or white to match the bar.
        image.isTemplate = tint == nil
        drawn += 1
        cache[setting.metric] = (key, image)
        return image
    }
}

/// What goes into one indicator, left to right, and how wide it is.
private struct IndicatorLayout: @unchecked Sendable {
    indirect enum Part {
        case symbol(String)
        case label(NSAttributedString)
        case text(NSAttributedString)
        case speed(NSAttributedString, NSAttributedString?)
        case chart([Double], ceiling: Double)
        case bars(Double)
        case gauge(Double)
        /// A small label centered above a row of parts, both inside the menu bar height.
        case stack(NSAttributedString, [Part])
    }

    private(set) var parts: [Part] = []
    let width: CGFloat

    init(setting: IndicatorSetting, value: IndicatorValue, history: [Double]) {
        var parts: [Part] = []
        if setting.style == .icon || setting.showIcon { parts.append(.symbol(setting.metric.symbol)) }
        if setting.style != .icon {
            // The speed style already uses both lines, so its label stays on the left.
            let stacked = setting.showLabel && setting.style != .speed
            var row = [Self.content(setting: setting, value: value, history: history, stacked: stacked)]
            if setting.style != .number, let temperature = value.temperatureText, value.isAvailable {
                row.append(.text(Self.attributed(temperature, Self.numberFont(stacked: stacked))))
            }
            if stacked {
                parts.append(.stack(Self.attributed(setting.metric.shortTitle, NSFont.systemFont(ofSize: 7.5, weight: .bold), alpha: 0.7), row))
            } else {
                if setting.showLabel {
                    parts.append(.label(Self.attributed(setting.metric.shortTitle, NSFont.systemFont(ofSize: 8, weight: .bold), alpha: 0.7)))
                }
                parts += row
            }
        }
        self.parts = parts
        width = ceil(Self.rowWidth(parts) + IndicatorGeometry.padding * 2)
    }

    private static func numberFont(stacked: Bool) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: stacked ? 11 : 12, weight: .medium)
    }

    private static func content(setting: IndicatorSetting, value: IndicatorValue, history: [Double], stacked: Bool) -> Part {
        let number = numberFont(stacked: stacked)
        guard value.isAvailable else { return .text(attributed(IndicatorFormatter.missing, number)) }
        switch setting.style {
        case .number, .icon:
            return .text(attributed(value.text, number))
        case .speed:
            let small = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .medium)
            return .speed(attributed(value.text, small), value.secondary.map { attributed($0, small) })
        case .chart:
            return .chart(history, ceiling: setting.metric.isThroughput ? max(history.max() ?? 1, 1) : 100)
        case .bars:
            return .bars(value.fraction ?? 0)
        case .gauge:
            return .gauge(value.fraction ?? 0)
        }
    }

    private static func attributed(_ text: String, _ font: NSFont, alpha: CGFloat = 1) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black.withAlphaComponent(alpha)])
    }

    private static func rowWidth(_ parts: [Part]) -> CGFloat {
        parts.map(width(of:)).reduce(0, +) + IndicatorGeometry.spacing * CGFloat(max(0, parts.count - 1))
    }

    private static func width(of part: Part) -> CGFloat {
        switch part {
        case .symbol: 14
        case .label(let text), .text(let text): ceil(text.size().width)
        case .speed(let first, let second): max(IndicatorGeometry.speedMinimumWidth, ceil(max(first.size().width, second?.size().width ?? 0)))
        case .chart: IndicatorGeometry.chartSize.width
        case .bars: IndicatorGeometry.barSize.width
        case .gauge: IndicatorGeometry.gaugeDiameter
        case .stack(let label, let row): max(ceil(label.size().width), rowWidth(row))
        }
    }

    func draw(color: NSColor) {
        Self.drawRow(parts, in: CGRect(x: IndicatorGeometry.padding, y: 0, width: width, height: IndicatorGeometry.height), color: color)
    }

    private static func drawRow(_ parts: [Part], in rect: CGRect, color: NSColor) {
        var x = rect.minX
        for part in parts {
            let partWidth = width(of: part)
            draw(part, in: CGRect(x: x, y: rect.minY, width: partWidth, height: rect.height), color: color)
            x += partWidth + IndicatorGeometry.spacing
        }
    }

    private static func draw(_ part: Part, in rect: CGRect, color: NSColor) {
        switch part {
        case .symbol(let name):
            let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium).applying(.init(paletteColors: [color]))
            if let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
                let size = symbol.size
                symbol.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
            }
        case .label(let text), .text(let text):
            Self.drawText(text, color: color, in: rect, alignRight: false)
        case .stack(let label, let row):
            // The label takes the top 8.5 pt, the row the rest; each is centered in the part's width.
            let top = rect.maxY - 8.5
            let labelWidth = ceil(label.size().width)
            Self.drawText(label, color: color, in: CGRect(x: rect.minX + (rect.width - labelWidth) / 2, y: top, width: labelWidth, height: 8.5), alignRight: false)
            let rowWidth = Self.rowWidth(row)
            Self.drawRow(row, in: CGRect(x: rect.minX + (rect.width - rowWidth) / 2, y: rect.minY, width: rowWidth, height: top - rect.minY + 0.5), color: color)
        case .speed(let first, let second):
            if let second {
                Self.drawText(first, color: color, in: CGRect(x: rect.minX, y: rect.midY - 1, width: rect.width, height: 10), alignRight: true)
                Self.drawText(second, color: color, in: CGRect(x: rect.minX, y: rect.midY - 10, width: rect.width, height: 10), alignRight: true)
            } else {
                Self.drawText(first, color: color, in: rect, alignRight: true)
            }
        case .chart(let values, let ceiling):
            let chartHeight = min(IndicatorGeometry.chartSize.height, rect.height)
            let box = CGRect(x: rect.minX, y: rect.midY - chartHeight / 2, width: rect.width, height: chartHeight)
            let points = IndicatorGeometry.sparkline(values: values, ceiling: ceiling, in: box.size)
            guard let first = points.first else { return }
            let path = NSBezierPath()
            path.move(to: CGPoint(x: box.minX + first.x, y: box.minY + first.y))
            for point in points.dropFirst() { path.line(to: CGPoint(x: box.minX + point.x, y: box.minY + point.y)) }
            path.lineWidth = 1.3
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            color.setStroke()
            path.stroke()
        case .bars(let fraction):
            let box = CGRect(x: rect.minX, y: rect.midY - IndicatorGeometry.barSize.height / 2, width: rect.width, height: IndicatorGeometry.barSize.height)
            color.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
            if fraction > 0 {
                var fill = box
                fill.size.width = max(box.height, box.width * min(1, max(0, fraction)))
                color.setFill()
                NSBezierPath(roundedRect: fill, xRadius: box.height / 2, yRadius: box.height / 2).fill()
            }
        case .gauge(let fraction):
            let diameter = min(IndicatorGeometry.gaugeDiameter, rect.height)
            let box = CGRect(x: rect.midX - diameter / 2, y: rect.midY - diameter / 2, width: diameter, height: diameter).insetBy(dx: 1.25, dy: 1.25)
            let center = CGPoint(x: box.midX, y: box.midY)
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: box.width / 2, startAngle: 0, endAngle: 360)
            track.lineWidth = 2.5
            color.withAlphaComponent(0.25).setStroke()
            track.stroke()
            if fraction > 0 {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: box.width / 2, startAngle: 90, endAngle: 90 - 360 * min(1, max(0, fraction)), clockwise: true)
                arc.lineWidth = 2.5
                arc.lineCapStyle = .round
                color.setStroke()
                arc.stroke()
            }
        }
    }

    /// Draws `text` centered vertically in `rect`, in `color` (the attributed text is black and only carries font and alpha).
    private static func drawText(_ text: NSAttributedString, color: NSColor, in rect: CGRect, alignRight: Bool) {
        let colored = NSMutableAttributedString(attributedString: text)
        let alpha = (text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?.alphaComponent ?? 1
        colored.addAttribute(.foregroundColor, value: color.withAlphaComponent(alpha), range: NSRange(location: 0, length: colored.length))
        let size = colored.size()
        colored.draw(at: CGPoint(x: alignRight ? rect.maxX - size.width : rect.minX, y: rect.midY - size.height / 2))
    }
}
