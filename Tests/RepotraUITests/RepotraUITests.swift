import XCTest

final class RepotraUITests: XCTestCase {
    func testWelcomeScreenCanChooseLibrary() {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["选择资料库…"].waitForExistence(timeout: 3))
    }

    func testLibraryChooserOpensAsynchronouslyAndCanReopenAfterCancel() {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "--ui-testing"]
        app.launch()

        let chooseButton = app.buttons["选择资料库…"]
        XCTAssertTrue(chooseButton.waitForExistence(timeout: 3))
        chooseButton.click()

        let openButton = app.buttons["打开资料库"]
        XCTAssertTrue(openButton.waitForExistence(timeout: 3))
        app.typeKey(.escape, modifierFlags: [])
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: openButton)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 3), .completed)

        chooseButton.click()
        XCTAssertTrue(openButton.waitForExistence(timeout: 3))
        app.typeKey(.escape, modifierFlags: [])
    }
}
