import XCTest

final class InteractionUITests: XCTestCase {
    @MainActor func testLongMusicListKeepsScrollPositionWhileParentUpdates() {
        let app = XCUIApplication(); app.launchArguments = ["interaction-test"]; app.launch()
        app.buttons["select.背景音乐"].tap()
        let row = app.buttons["choice.100"]
        for _ in 0..<20 {
            if row.isHittable { break }
            app.swipeUp(velocity:400)
        }
        XCTAssertTrue(row.isHittable)
        let before = row.frame
        let idle = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in row.isHittable && abs(row.frame.minY-before.minY)<2 },object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[idle],timeout:3),.completed)
        Thread.sleep(forTimeInterval:3)
        XCTAssertTrue(row.isHittable); XCTAssertEqual(row.frame.minY,before.minY,accuracy:2)
        let shot = XCTAttachment(screenshot:app.screenshot()); shot.name = "稳定选择页"; shot.lifetime = .keepAlways; add(shot)
        row.tap()
        XCTAssertTrue(app.staticTexts["已选择 100"].waitForExistence(timeout:3))
    }
    @MainActor func testKeyboardDonePreservesNewlinesAndSelectionDismissesKeyboard() {
        let app = XCUIApplication(); app.launchArguments = ["interaction-test"]; app.launch()
        let editor = app.textViews["interaction.text"]; editor.tap(); editor.typeText("first\nsecond")
        let done = app.buttons["keyboard.done"]; XCTAssertTrue(done.waitForExistence(timeout:3)); done.tap()
        XCTAssertFalse(app.keyboards.firstMatch.exists); XCTAssertEqual(editor.value as? String,"first\nsecond")
        editor.tap(); XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout:3))
        app.buttons["select.背景音乐"].tap()
        let hidden = XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == false"),object:app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for:[hidden],timeout:3),.completed)
        app.buttons["取消"].tap()
        XCTAssertEqual(editor.value as? String,"first\nsecond")
    }
    @MainActor func testProductionSpeakerSelectionReturnsAndRealtimeTabIsGone() {
        let app = XCUIApplication(); app.launchArguments = ["voice-custom-snapshot"]; app.launch()
        XCTAssertTrue(app.tabBars.buttons["配音"].exists); XCTAssertFalse(app.tabBars.buttons["变声"].exists)
        XCTAssertFalse(app.staticTexts["手机实时"].exists)
        app.buttons["select.Speaker"].tap()
        app.buttons["choice.Vivian"].tap()
        XCTAssertTrue(app.buttons["select.Speaker"].label.contains("Vivian"))
        let shot = XCTAttachment(screenshot:app.screenshot()); shot.name = "自定义配音"; shot.lifetime = .keepAlways; add(shot)
    }
}
