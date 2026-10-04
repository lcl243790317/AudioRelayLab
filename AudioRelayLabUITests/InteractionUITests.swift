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

    @MainActor func testCustomDraftEditorIsVisibleAndKeepsLatestEdits() {
        let app = XCUIApplication(); app.launchArguments = ["voice-custom-snapshot"]; app.launch()
        let editor = app.textViews["revoice.text"]
        XCTAssertTrue(editor.waitForExistence(timeout:5)); XCTAssertTrue(editor.isHittable)
        let generate = app.buttons["revoice.generate"]
        XCTAssertTrue(generate.exists); XCTAssertFalse(generate.isEnabled)
        app.buttons["select.Speaker"].tap(); app.buttons["choice.Vivian"].tap()
        let instruction = app.textFields["revoice.instruction"]
        instruction.tap(); instruction.typeText("relaxed and clear")
        app.buttons["keyboard.done"].tap()
        editor.tap(); editor.typeText(" Latest words.")
        app.buttons["keyboard.done"].tap()
        XCTAssertTrue((editor.value as? String ?? "").contains("Latest words."))
        XCTAssertEqual(instruction.value as? String,"relaxed and clear")
        XCTAssertTrue(app.buttons["select.Speaker"].label.contains("Vivian"))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        attach(app,"最新草稿与键盘完成")
    }

    @MainActor func testPendingTaskParametersStaySeparateFromEditedDraft() {
        let app = XCUIApplication(); app.launchArguments = ["voice-custom-snapshot","voice-recovery-snapshot"]; app.launch()
        let editor = app.textViews["revoice.text"]
        XCTAssertTrue(editor.waitForExistence(timeout:5))
        editor.tap(); editor.typeText(" Updated draft."); app.buttons["keyboard.done"].tap()
        let pendingText = app.staticTexts["revoice.pending.text"]
        reveal(pendingText,in:app)
        XCTAssertEqual(pendingText.label,"这是之前已提交的配音，恢复时请继续取回这一份。")
        XCTAssertTrue(app.staticTexts["revoice.pending.voice"].label.contains("Serena"))
        XCTAssertTrue(app.staticTexts["revoice.pending.instruction"].label.contains("轻柔、语速稍慢"))
        attach(app,"旧任务固定参数")
        reveal(app.buttons["revoice.pending.resume"],in:app)
        XCTAssertTrue(app.buttons["revoice.pending.resume"].isHittable)
        XCTAssertTrue(app.buttons["revoice.pending.stop"].exists)
        XCTAssertTrue(app.buttons["revoice.generate"].label.contains("当前内容"))
        XCTAssertTrue((editor.value as? String ?? "").contains("Updated draft."))
        attach(app,"旧任务与新草稿分开")
    }

    @MainActor func testLargeTextCustomLayoutCanReachAllInputsAndGenerate() {
        let app = XCUIApplication(); app.launchArguments = ["voice-custom-snapshot","voice-large-type","night-snapshot"]; app.launch()
        let speaker = app.buttons["select.Speaker"]
        XCTAssertTrue(speaker.waitForExistence(timeout:5)); reveal(speaker,in:app)
        speaker.tap(); app.buttons["choice.Dylan"].tap()
        let instruction = app.textFields["revoice.instruction"]
        reveal(instruction,in:app); instruction.tap(); instruction.typeText("slow and natural")
        app.buttons["keyboard.done"].tap()
        let editor = app.textViews["revoice.text"]
        reveal(editor,in:app); editor.tap(); editor.typeText(" Large text draft.")
        app.buttons["keyboard.done"].tap()
        let generate = app.buttons["revoice.generate"]
        reveal(generate,in:app); XCTAssertFalse(generate.isEnabled)
        XCTAssertEqual(instruction.value as? String,"slow and natural")
        XCTAssertTrue((editor.value as? String ?? "").contains("Large text draft."))
        attach(app,"大字体深色配音编辑")
    }

    @MainActor private func reveal(_ element:XCUIElement,in app:XCUIApplication) {
        for _ in 0..<14 {
            if element.isHittable { return }
            let start = app.coordinate(withNormalizedOffset:CGVector(dx:0.96,dy:0.80))
            let end = app.coordinate(withNormalizedOffset:CGVector(dx:0.96,dy:0.28))
            start.press(forDuration:0.05,thenDragTo:end)
        }
        XCTAssertTrue(element.isHittable)
    }

    @MainActor private func attach(_ app:XCUIApplication,_ name:String) {
        let shot = XCTAttachment(screenshot:app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
