import AppKit
import LivCore
import Testing
@testable import LivVitals

@MainActor
struct IndicatorImageTests {
    private let value = IndicatorValue(text: "21%", fraction: 0.21, chartValue: 21, spoken: "Processor, 21 percent")

    @Test(arguments: IndicatorStyle.allCases)
    func everyStyleDrawsAnImageOfTheMenuBarHeight(style: IndicatorStyle) {
        let setting = IndicatorSetting(metric: .cpu, enabled: true, style: style)
        let image = IndicatorImageRenderer.image(for: setting, value: value, history: [10, 30, 20, 40])
        #expect(image.size.height == IndicatorImageRenderer.height)
        #expect(image.size.width > 4)
    }

    @Test func theAutomaticTintIsATemplateAndACustomOneIsNot() {
        let automatic = IndicatorSetting(metric: .memory, enabled: true, tint: .system)
        let teal = IndicatorSetting(metric: .memory, enabled: true, tint: .teal)
        #expect(IndicatorImageRenderer.image(for: automatic, value: value, history: []).isTemplate)
        #expect(!IndicatorImageRenderer.image(for: teal, value: value, history: []).isTemplate)
    }

    @Test func anImageIsOnlyDrawnAgainWhenWhatItShowsChanges() {
        let setting = IndicatorSetting(metric: .gpu, enabled: true, style: .number)
        let first = IndicatorImageRenderer.image(for: setting, value: value, history: [1, 2, 3])
        let drawn = IndicatorImageRenderer.drawn

        // The history is not part of a number indicator, so a new sample with the same text changes nothing.
        let same = IndicatorImageRenderer.image(for: setting, value: value, history: [1, 2, 3, 4])
        #expect(same === first)
        #expect(IndicatorImageRenderer.drawn == drawn)

        let other = IndicatorValue(text: "22%", fraction: 0.22, chartValue: 22, spoken: "GPU, 22 percent")
        _ = IndicatorImageRenderer.image(for: setting, value: other, history: [])
        #expect(IndicatorImageRenderer.drawn == drawn + 1)
    }

    @Test func aChartIndicatorIsDrawnAgainWhenTheHistoryMoves() {
        let setting = IndicatorSetting(metric: .network, enabled: true, style: .chart)
        _ = IndicatorImageRenderer.image(for: setting, value: value, history: [1, 2, 3])
        let drawn = IndicatorImageRenderer.drawn
        _ = IndicatorImageRenderer.image(for: setting, value: value, history: [2, 3, 4])
        #expect(IndicatorImageRenderer.drawn == drawn + 1)
    }

    @Test func aMissingReadingStillDrawsADash() {
        let setting = IndicatorSetting(metric: .gpu, enabled: true, style: .gauge)
        let image = IndicatorImageRenderer.image(for: setting, value: IndicatorFormatter.unavailable(.gpu), history: [])
        #expect(image.size.height == IndicatorImageRenderer.height)
    }

    @Test func sparklinesStayInsideTheirBox() {
        let size = CGSize(width: 30, height: 12)
        let points = IndicatorGeometry.sparkline(values: [0, 150, -20, 50], ceiling: 100, in: size)
        #expect(points.count == 4)
        #expect(points.allSatisfy { $0.x >= 0 && $0.x <= size.width && $0.y >= 0 && $0.y <= size.height })
        #expect(points.first?.x == 0 && points.last?.x == size.width)
        #expect(IndicatorGeometry.sparkline(values: [5], ceiling: 100, in: size).isEmpty)
        #expect(IndicatorGeometry.sparkline(values: [1, 2], ceiling: 0, in: size).isEmpty)
    }

    @Test func aWiderTextMakesAWiderImageAndHidingTheLabelMakesItNarrower() {
        let short = IndicatorValue(text: "5%", fraction: 0.05, chartValue: 5, spoken: "")
        let long = IndicatorValue(text: "100%", fraction: 1, chartValue: 100, spoken: "")
        let setting = IndicatorSetting(metric: .battery, enabled: true, style: .number)
        var noLabel = setting
        noLabel.showLabel = false
        let narrow = IndicatorImageRenderer.image(for: setting, value: short, history: []).size.width
        let wide = IndicatorImageRenderer.image(for: setting, value: long, history: []).size.width
        let bare = IndicatorImageRenderer.image(for: noLabel, value: long, history: []).size.width
        #expect(wide > narrow)
        #expect(bare < wide)
    }

    /// The old SwiftUI renderer made the GPU renderer hold ~110 MB for the first minute; the images are drawn with Core
    /// Graphics now, so building one must not need a GPU surface. Drawing it into a bitmap proves it paints something.
    @Test func theImageDrawsRealPixels() throws {
        let setting = IndicatorSetting(metric: .cpu, enabled: true, style: .gauge, tint: .teal)
        let value = IndicatorValue(text: "50%", fraction: 0.5, chartValue: 50, spoken: "")
        let image = IndicatorImageRenderer.image(for: setting, value: value, history: [])
        let representation = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * 2), pixelsHigh: Int(image.size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
        image.draw(in: CGRect(origin: .zero, size: CGSize(width: image.size.width * 2, height: image.size.height * 2)))
        NSGraphicsContext.restoreGraphicsState()
        var painted = false
        for x in 0..<representation.pixelsWide { for y in 0..<representation.pixelsHigh where (representation.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 { painted = true } }
        #expect(painted)
    }

    @Test func everyMetricStyleAndTintHasATitleAndEveryIndicatorASpokenLabel() {
        for metric in MetricKind.allCases {
            #expect(!metric.localizedTitle.isEmpty)
            #expect(!IndicatorFormatter.value(metric, from: nil).spoken.isEmpty)
        }
        #expect(IndicatorStyle.allCases.allSatisfy { !$0.localizedTitle.isEmpty })
        #expect(IndicatorTint.allCases.allSatisfy { !$0.localizedTitle.isEmpty })
    }
}
