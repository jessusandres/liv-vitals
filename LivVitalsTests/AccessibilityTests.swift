import Foundation
import LivCore
import Testing
@testable import LivVitals

/// The words VoiceOver reads for every control that shows no text of its own, by component. The view hierarchy is
/// not walked: these are the same functions the components call.
struct AccessibilityTextTests {
    @Test func checkBoxesReadTheirStateInWords() {
        #expect(AccessibilityText.selection(.all) == "Selected")
        #expect(AccessibilityText.selection(.some) == "Partly selected")
        #expect(AccessibilityText.selection(.none) == "Not selected")
    }

    @Test func ringsReadAPercentageThatStaysInRange() {
        #expect(AccessibilityText.percent(0) == "0 percent")
        #expect(AccessibilityText.percent(0.426) == "43 percent")
        #expect(AccessibilityText.percent(1.7) == "100 percent")
        #expect(AccessibilityText.percent(-1) == "0 percent")
    }

    @Test func theRoundButtonReadsItsTitleAndSubtitle() {
        #expect(AccessibilityText.circleButton(title: "Clean", subtitle: "4.2 GB") == "Clean, 4.2 GB")
        #expect(AccessibilityText.circleButton(title: "Scan", subtitle: nil) == "Scan")
    }

    @Test func expandButtonsSayWhatTheyWillDo() {
        #expect(AccessibilityText.expandButton("Caches", isExpanded: false) == "Expand Caches")
        #expect(AccessibilityText.expandButton("Caches", isExpanded: true) == "Collapse Caches")
    }

    @Test func sunburstSegmentsReadNameSizeAndKind() {
        #expect(AccessibilityText.sunburstSegment(name: "Library", size: "12 GB", isDirectory: true) == "Library, 12 GB, folder")
        #expect(AccessibilityText.sunburstSegment(name: "a.zip", size: "1 GB", isDirectory: false) == "a.zip, 1 GB")
    }

    @Test func badgesWithoutTextHaveAFallbackLabel() {
        #expect(!AccessibilityText.needsAdmin.isEmpty)
        #expect(!AccessibilityText.lockedFallback.isEmpty)
    }

    @Test func everyModuleAndCategoryHasATitleForTheirLabels() {
        for module in AppModule.allCases { #expect(!module.title.isEmpty) }
        for category in CleanupCategory.allCases { #expect(!category.title.isEmpty) }
    }
}
