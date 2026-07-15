@testable import Repotra
import Testing

@Suite("Repotra smoke tests")
struct SmokeTests {
    @Test("filename sanitization")
    func filenameSanitization() {
        #expect(PathUtilities.sanitizedFilename("A/B") == "A-B")
    }
}
