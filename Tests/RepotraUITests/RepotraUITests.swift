import XCTest

final class RepotraUITests: XCTestCase {
    func testWelcomeScreenCanChooseLibrary() {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["选择资料库…"].waitForExistence(timeout: 3))
    }
}
