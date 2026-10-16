import Foundation
import LivCore
import Testing
@testable import LivVitals

/// The English texts come out of the String Catalog, including its plural forms.
struct LocalizationTests {
    @Test func pluralFormsComeFromTheCatalog() {
        #expect(String(localized: "\(1) items cleaned") == "1 item cleaned")
        #expect(String(localized: "\(3) items cleaned") == "3 items cleaned")
        #expect(String(localized: "Put \(1) items back?") == "Put 1 item back?")
        #expect(String(localized: "\(2) ask for your password.") == "2 ask for your password.")
        #expect(String(localized: "\(1) ask for your password.") == "1 asks for your password.")
    }

    @Test func categoryAndHealthTitlesStayEnglishInTheDevelopmentLanguage() {
        #expect(AppModule.cleanup.title == "Cleanup")
        #expect(CleanupCategory.userCaches.localizedTitle == "User Caches")
        #expect(HealthScore.Level.good.localizedTitle == "Good")
    }
}
