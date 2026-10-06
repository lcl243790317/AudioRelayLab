import XCTest

final class InteractionUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor func testAutomaticInstructionTogglePreviewAndFixedReferenceAvailability() {
        let app = XCUIApplication(); app.launchArguments = ["voice-snapshot","day-snapshot"]; app.launch()
        let instruction = app.textFields["revoice.instruction"]
        XCTAssertTrue(instruction.waitForExistence(timeout:5)); let original = instruction.value as? String
        print("Automatic instruction screen: \(app.debugDescription)")
        let automatic = app.buttons["revoice.instruction.automatic"]
        reveal(automatic,in:app); XCTAssertTrue(automatic.isEnabled)
        XCTAssertEqual(automatic.value as? String,"已关闭")
        setAutomaticInstruction(automatic,to:true,in:app)
        let summary = app.staticTexts["revoice.instruction.summary"]
        reveal(summary,in:app); XCTAssertTrue(summary.waitForExistence(timeout:3))
        let preview = app.buttons["查看本次自动指令"]
        reveal(preview,in:app); preview.tap()
        let previewText = app.staticTexts["revoice.instruction.preview"]
        reveal(previewText,in:app); XCTAssertTrue(previewText.waitForExistence(timeout:3))
        attach(app,"自动表达指令已开启与展开")
        setAutomaticInstruction(automatic,to:false,in:app)
        XCTAssertFalse(app.staticTexts["revoice.instruction.summary"].exists)
        for _ in 0..<6 {
            if app.buttons["select.声线"].isHittable { break }
            let start = app.coordinate(withNormalizedOffset:CGVector(dx:0.96,dy:0.28))
            let end = app.coordinate(withNormalizedOffset:CGVector(dx:0.96,dy:0.80))
            start.press(forDuration:0.05,thenDragTo:end)
        }
        XCTAssertEqual(instruction.value as? String,original)
        app.buttons["select.声线"].tap(); app.buttons["choice.scholar-design"].tap()
        reveal(automatic,in:app); XCTAssertFalse(automatic.isEnabled)
        let fixedReferenceNotice = app.staticTexts["固定参考声线不支持自动表达指令。"]
        reveal(fixedReferenceNotice,in:app); XCTAssertTrue(fixedReferenceNotice.exists)
        attach(app,"自动表达指令开关与预览")
    }
    @MainActor func testBothLibraryScreensStopPreviewOnTabChangeAndNavigationBack() {
        let app = XCUIApplication(); app.launchArguments = ["mix-interaction-test","day-snapshot"]; app.launch()
        app.tabBars.buttons["资料"].tap()
        for library in ["本地音频库","录音与 AI 声音"] {
            app.buttons[library].tap()
            let stop = app.buttons["library.preview.stop"]
            XCTAssertTrue(stop.waitForExistence(timeout:5)); XCTAssertFalse(stop.isEnabled)
            app.buttons["回听"].firstMatch.tap()
            let playing = XCTNSPredicateExpectation(predicate:NSPredicate(format:"value == %@","正在回听"),object:stop)
            XCTAssertEqual(XCTWaiter.wait(for:[playing],timeout:5),.completed)
            XCTAssertTrue(stop.isEnabled)

            app.tabBars.buttons["音频"].tap()
            app.tabBars.buttons["资料"].tap()
            XCTAssertTrue(stop.waitForExistence(timeout:3)); XCTAssertFalse(stop.isEnabled)
            XCTAssertEqual(stop.value as? String,"未在回听")

            app.buttons["回听"].firstMatch.tap()
            let replaying = XCTNSPredicateExpectation(predicate:NSPredicate(format:"value == %@","正在回听"),object:stop)
            XCTAssertEqual(XCTWaiter.wait(for:[replaying],timeout:5),.completed)
            app.navigationBars.buttons["资料"].tap()
            app.buttons[library].tap()
            XCTAssertTrue(stop.waitForExistence(timeout:3)); XCTAssertFalse(stop.isEnabled)
            XCTAssertEqual(stop.value as? String,"未在回听")
            app.navigationBars.buttons["资料"].tap()
        }
        attach(app,"两个音频库退出后停止回听")
    }

    @MainActor func testIndependentMixWorksWithoutLatestRevoiceResult() {
        let app = XCUIApplication(); app.launchArguments = ["mix-snapshot","mix-interaction-test","day-snapshot"]; app.launch()
        let save = app.buttons["mix.save"]
        XCTAssertTrue(save.waitForExistence(timeout:5)); XCTAssertFalse(save.isEnabled)
        app.buttons["select.人声"].tap()
        let voice = app.buttons.matching(NSPredicate(format:"identifier CONTAINS %@","16300000-0000-4000-8000-000000000013")).firstMatch
        XCTAssertTrue(voice.waitForExistence(timeout:3)); voice.tap()
        app.buttons["select.背景音乐"].tap()
        let music = app.buttons.matching(NSPredicate(format:"identifier CONTAINS %@","00000000-0000-4000-8000-000000000001")).firstMatch
        XCTAssertTrue(music.waitForExistence(timeout:3)); music.tap()
        let startDelay = app.sliders["mix.musicStartDelay"],tail = app.sliders["mix.musicTailDuration"]
        reveal(tail,in:app); tail.adjust(toNormalizedSliderPosition:0.05)
        reveal(startDelay,in:app); startDelay.adjust(toNormalizedSliderPosition:0.1)
        reveal(save,in:app); XCTAssertTrue(save.isEnabled); save.tap()
        XCTAssertTrue(app.staticTexts["混音已保存到录音库"].waitForExistence(timeout:15))
        reveal(app.buttons["分享成品"],in:app); XCTAssertTrue(app.buttons["用于延迟播放"].exists)
        attach(app,"独立混音成品")
    }
    @MainActor func testPresetInstructionEditResetAndSwitchRestoreDefault() {
        let app = XCUIApplication(); app.launchArguments = ["voice-snapshot","day-snapshot"]; app.launch()
        let instruction = app.textFields["revoice.instruction"]
        XCTAssertTrue(instruction.waitForExistence(timeout:5)); let original = instruction.value as? String
        instruction.tap(); instruction.typeText(" relaxed"); app.buttons["keyboard.done"].tap()
        XCTAssertTrue((instruction.value as? String ?? "").contains("relaxed"))
        app.buttons["revoice.instruction.reset"].tap(); XCTAssertEqual(instruction.value as? String,original)
        instruction.tap(); instruction.typeText(" temporary"); app.buttons["keyboard.done"].tap()
        app.buttons["select.声线"].tap(); app.buttons["choice.vivian-original"].tap()
        XCTAssertFalse((instruction.value as? String ?? "").contains("temporary"))
        app.buttons["select.声线"].tap(); app.buttons["choice.serena-original"].tap()
        XCTAssertEqual(instruction.value as? String,original); XCTAssertFalse(app.keyboards.firstMatch.exists)
        attach(app,"预设指令可编辑与恢复默认")
    }
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

    @MainActor private func setAutomaticInstruction(_ element:XCUIElement,to value:Bool,in app:XCUIApplication) {
        reveal(element,in:app)
        element.tap()
        let changed = XCTNSPredicateExpectation(
            predicate:NSPredicate(format:"value == %@",value ? "已开启" : "已关闭"),object:element)
        let result = XCTWaiter.wait(for:[changed],timeout:3)
        XCTAssertEqual(result,.completed)
    }

    @MainActor private func reveal(_ element:XCUIElement,in app:XCUIApplication) {
        for _ in 0..<14 {
            if element.isHittable { return }
            let above = element.exists && element.frame.midY < app.frame.minY + 120
            let start = app.coordinate(withNormalizedOffset:CGVector(dx:0.96,dy:above ? 0.28 : 0.80))
            let end = app.coordinate(withNormalizedOffset:CGVector(dx:0.96,dy:above ? 0.80 : 0.28))
            start.press(forDuration:0.05,thenDragTo:end)
        }
        XCTAssertTrue(element.isHittable)
    }

    @MainActor private func attach(_ app:XCUIApplication,_ name:String) {
        let shot = XCTAttachment(screenshot:app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
