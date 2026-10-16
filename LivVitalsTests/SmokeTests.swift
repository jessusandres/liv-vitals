import Testing
@testable import LivVitals

struct SmokeTests {
    @Test func moduleListIsComplete() {
        #expect(AppModule.allCases.count == 10)
    }
}
