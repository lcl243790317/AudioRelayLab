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
        let automatic = app.buttons["revoice.instruction.automatic"]
        reveal(automatic,in:app); XCTAssertTrue(automatic.isEnabled)
        XCTAssertEqual(automatic.value as? String,"已关闭")
        setAutomaticInstruction(automatic,to:true,in:app)
        let summary = app.staticTexts["revoice.instruction.summary"]
        reveal(summary,in:app); XCTAssertTrue(summary.waitForExistence(timeout:3))
        let previewText = app.textViews["revoice.instruction.preview"]
        reveal(previewText,in:app); previewText.tap(); previewText.typeText(" warm and slow")
        app.buttons["keyboard.done"].tap()
        XCTAssertTrue((previewText.value as? String ?? "").contains("warm and slow"))
        let edited = previewText.value as? String
        let content = app.textViews["revoice.text"]
        reveal(content,in:app); content.tap(); content.typeText(" Updated words."); app.buttons["keyboard.done"].tap()
        reveal(previewText,in:app); XCTAssertEqual(previewText.value as? String,edited)
        reveal(app.staticTexts["revoice.instruction.stale"],in:app)
        XCTAssertFalse(app.buttons["revoice.generate"].isEnabled)
        attach(app,"自动指令手改与正文变化提示")
        setAutomaticInstruction(automatic,to:false,in:app)
        XCTAssertFalse(app.staticTexts["revoice.instruction.summary"].exists)
        reveal(instruction,in:app)
        XCTAssertEqual(instruction.value as? String,original)
        setAutomaticInstruction(automatic,to:true,in:app)
        reveal(previewText,in:app); XCTAssertEqual(previewText.value as? String,edited)
        reveal(app.buttons["select.声线"],in:app)
        app.buttons["select.声线"].tap(); app.buttons["choice.vivian-original"].tap()
        XCTAssertTrue(app.alerts["放弃手动调整的指令？"].waitForExistence(timeout:5))
        app.alerts.buttons["取消"].tap()
        XCTAssertTrue(app.buttons["select.声线"].label.contains("Serena")); XCTAssertEqual(previewText.value as? String,edited)
        app.buttons["select.声线"].tap(); app.buttons["choice.vivian-original"].tap()
        XCTAssertTrue(app.alerts["放弃手动调整的指令？"].waitForExistence(timeout:5)); app.alerts.buttons["放弃并切换"].tap()
        reveal(previewText,in:app); XCTAssertFalse((previewText.value as? String ?? "").contains("warm and slow"))
        reveal(app.buttons["revoice.instruction.rematch"],in:app); app.buttons["revoice.instruction.rematch"].tap()
        reveal(app.buttons["select.声线"],in:app)
        app.buttons["select.声线"].tap(); app.buttons["choice.scholar-design"].tap()
        reveal(automatic,in:app); XCTAssertFalse(automatic.isEnabled)
        let fixedReferenceNotice = app.staticTexts["固定参考声线不支持自动表达指令。"]
        reveal(fixedReferenceNotice,in:app); XCTAssertTrue(fixedReferenceNotice.exists)
        attach(app,"自动表达指令开关与预览")
    }
    @MainActor func testBothLibraryScreensStopPreviewOnTabChangeAndNavigationBack() {
        let app = XCUIApplication(); app.launchArguments = ["mix-interaction-test","day-snapshot"]; app.launch()
        app.tabBars.buttons["音频库"].tap()
        for library in ["本地音频","录音与 AI"] {
            app.segmentedControls["library.scope"].buttons[library].tap()
            let stop = app.buttons["library.preview.stop"]
            XCTAssertTrue(stop.waitForExistence(timeout:5)); XCTAssertFalse(stop.isEnabled)
            app.buttons["回听"].firstMatch.tap()
            let playing = XCTNSPredicateExpectation(predicate:NSPredicate(format:"value == %@","正在回听"),object:stop)
            XCTAssertEqual(XCTWaiter.wait(for:[playing],timeout:5),.completed)
            XCTAssertTrue(stop.isEnabled)

            app.tabBars.buttons["播放"].tap()
            app.tabBars.buttons["音频库"].tap()
            XCTAssertTrue(stop.waitForExistence(timeout:3)); XCTAssertFalse(stop.isEnabled)
            XCTAssertEqual(stop.value as? String,"未在回听")

            app.buttons["回听"].firstMatch.tap()
            let replaying = XCTNSPredicateExpectation(predicate:NSPredicate(format:"value == %@","正在回听"),object:stop)
            XCTAssertEqual(XCTWaiter.wait(for:[replaying],timeout:5),.completed)
            app.buttons["workshop.tools"].tap(); app.buttons["实验历史"].tap()
            app.navigationBars.buttons["音频库"].tap()
            XCTAssertTrue(stop.waitForExistence(timeout:3)); XCTAssertFalse(stop.isEnabled)
            XCTAssertEqual(stop.value as? String,"未在回听")
            let other = library == "本地音频" ? "录音与 AI" : "本地音频"
            app.buttons["回听"].firstMatch.tap()
            app.segmentedControls["library.scope"].buttons[other].tap()
            XCTAssertFalse(stop.isEnabled)
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
        let order = app.buttons["select.起播顺序"]
        reveal(order,in:app); order.tap(); app.buttons["choice.musicFirst"].tap()
        let voiceDelay = app.sliders["mix.voiceStartDelay"]
        reveal(voiceDelay,in:app); voiceDelay.adjust(toNormalizedSliderPosition:0.1)
        XCTAssertTrue(app.textFields["mix.startDelay.seconds"].exists)
        reveal(order,in:app); order.tap(); app.buttons["choice.voiceFirst"].tap()
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
        reveal(instruction,in:app); instruction.tap(); instruction.typeText(" relaxed"); app.buttons["keyboard.done"].tap()
        XCTAssertTrue((instruction.value as? String ?? "").contains("relaxed"))
        reveal(app.buttons["revoice.instruction.reset"],in:app); app.buttons["revoice.instruction.reset"].tap(); XCTAssertEqual(instruction.value as? String,original)
        reveal(instruction,in:app); instruction.tap(); instruction.typeText(" temporary"); app.buttons["keyboard.done"].tap()
        reveal(app.buttons["select.声线"],in:app); app.buttons["select.声线"].tap(); app.buttons["choice.vivian-original"].tap()
        XCTAssertFalse((instruction.value as? String ?? "").contains("temporary"))
        app.buttons["select.声线"].tap(); app.buttons["choice.serena-original"].tap()
        XCTAssertEqual(instruction.value as? String,original); XCTAssertFalse(app.keyboards.firstMatch.exists)
        attach(app,"预设指令可编辑与恢复默认")
    }
    @MainActor func testLongMusicListKeepsScrollPositionWhileParentUpdates() {
        let app = XCUIApplication(); app.launchArguments = ["interaction-test"]; app.launch()
        app.buttons["select.背景音乐"].tap()
        let row = app.buttons["choice.100"]
        for _ in 0..<40 {
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
        XCTAssertTrue(app.tabBars.buttons["工坊"].exists); XCTAssertFalse(app.tabBars.buttons["变声"].exists)
        XCTAssertFalse(app.staticTexts["手机实时"].exists)
        reveal(app.buttons["select.Speaker"],in:app); app.buttons["select.Speaker"].tap()
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
        reveal(app.buttons["select.Speaker"],in:app); app.buttons["select.Speaker"].tap(); app.buttons["choice.Vivian"].tap()
        let instruction = app.textFields["revoice.instruction"]
        reveal(instruction,in:app); instruction.tap(); instruction.typeText("relaxed and clear")
        app.buttons["keyboard.done"].tap()
        reveal(editor,in:app); editor.tap(); editor.typeText(" Latest words.")
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
        speaker.tap(); XCTAssertTrue(app.buttons["choice.Dylan"].waitForExistence(timeout:5)); app.buttons["choice.Dylan"].tap()
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

    @MainActor func testBatchDeleteBothViewsProtectsBuiltinAndCancellationKeepsFiles() {
        let app = XCUIApplication()
        for scope in ["本地音频","录音与 AI"] {
            app.launchArguments = ["library-interaction-test","day-snapshot"]; app.launch()
            app.tabBars.buttons["音频库"].tap(); app.segmentedControls["library.scope"].buttons[scope].tap()
            app.buttons["library.selection"].tap()
            if scope == "本地音频" {
                let builtin = app.buttons["library.select.00000000-0000-4000-8000-000000000001"]
                reveal(builtin,in:app); XCTAssertFalse(builtin.isEnabled)
            }
            app.buttons["library.selectAll"].tap()
            let delete = app.buttons["library.delete.selected"]
            XCTAssertTrue(delete.isEnabled); delete.tap()
            XCTAssertTrue(app.buttons["library.delete.confirm"].waitForExistence(timeout:3))
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@","批删测试原声")).firstMatch.exists)
            app.buttons["取消"].tap()
            XCTAssertTrue(delete.isEnabled)
            app.buttons["library.selectAll"].tap(); XCTAssertFalse(delete.isEnabled)
            app.buttons["library.selectAll"].tap(); delete.tap()
            app.buttons["library.delete.confirm"].tap()
            let summary = app.staticTexts["library.delete.summary"]
            XCTAssertTrue(summary.waitForExistence(timeout:5)); XCTAssertFalse(summary.label.contains("未删除"))
            XCTAssertFalse(app.buttons["library.delete.selected"].exists)
            if scope == "本地音频" { XCTAssertTrue(app.buttons["回听"].exists) }
            else { XCTAssertFalse(app.buttons["回听"].exists) }
            attach(app,"批量删除_"+scope); app.terminate()
        }
    }

    @MainActor func testOutsideTapInputSwitchScrollAndExitDismissKeyboardWithoutSwallowingActions() {
        let app = XCUIApplication(); app.launchArguments = ["interaction-test"]; app.launch()
        let editor = app.textViews["interaction.text"]
        editor.tap(); editor.typeText("draft")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        app.buttons["interaction.once"].tap()
        XCTAssertEqual(app.staticTexts["interaction.clicks"].label,"点击次数 1")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        let address = app.textFields["interaction.connection"]
        reveal(address,in:app); address.tap(); address.typeText("local")
        let key = app.secureTextFields["interaction.key"]
        reveal(key,in:app); key.tap(); key.typeText("sample")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        let number = app.textFields["interaction.number"]
        reveal(number,in:app); number.tap(); number.typeText("12")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        app.navigationBars.staticTexts["交互验证"].tap()
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        let notes = app.textViews["interaction.notes"]
        reveal(notes,in:app); notes.tap(); notes.typeText("note\nsecond")
        let start = app.coordinate(withNormalizedOffset:CGVector(dx:0.96,dy:0.30))
        let end = app.coordinate(withNormalizedOffset:CGVector(dx:0.96,dy:0.15))
        start.press(forDuration:0.05,thenDragTo:end)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertEqual(notes.value as? String,"note\nsecond")
        reveal(editor,in:app); editor.tap()
        app.buttons["离开输入页"].tap()
        XCTAssertTrue(app.staticTexts["输入页已离开"].exists); XCTAssertFalse(app.keyboards.firstMatch.exists)
    }

    @MainActor func testSelectedMusicTimingScreenshotsAcrossThemesAndLargeType() {
        let app = XCUIApplication()
        for night in [false,true] {
            for large in [false,true] {
                app.launchArguments = ["mix-snapshot","mix-timing-snapshot",night ? "night-snapshot" : "day-snapshot"]
                if large { app.launchArguments.append("voice-large-type") }
                app.launch()
                let order = app.buttons["select.起播顺序"]
                XCTAssertTrue(order.waitForExistence(timeout:5)); reveal(order,in:app)
                XCTAssertTrue(order.label.contains("音乐先播"))
                let seconds = app.textFields["mix.startDelay.seconds"]
                reveal(seconds,in:app); XCTAssertTrue(seconds.exists)
                let name = "mix-selected-"+(night ? "dark" : "light")+(large ? "-large" : "-normal")
                attach(app,name+"-start")
                let tail = app.sliders["mix.musicTailDuration"]
                reveal(tail,in:app); XCTAssertTrue(tail.exists); attach(app,name+"-tail")
                app.terminate()
            }
        }
    }

    @MainActor private func reveal(_ element:XCUIElement,in app:XCUIApplication) {
        // The manual generate action lives outside the scroll view's viewport.
        if element.identifier == "revoice.generate", element.isHittable { return }
        for _ in 0..<18 {
            let scroll = app.scrollViews["screen.scroll"].firstMatch
            let viewport = scroll.exists ? scroll.frame : app.frame
            var top = max(viewport.minY,app.navigationBars.firstMatch.frame.maxY)+4
            let workshop = app.segmentedControls["workshop.mode"]
            if workshop.exists { top = max(top,workshop.frame.maxY+12) }
            let largeWorkshop = app.buttons["select.工坊功能"]
            if largeWorkshop.exists { top = max(top,largeWorkshop.frame.maxY+12) }
            var bottom = viewport.maxY-4
            let tabs = app.tabBars.firstMatch
            if tabs.exists { bottom = min(bottom,tabs.frame.minY-4) }
            let generate = app.buttons["revoice.generate"]
            if generate.exists { bottom = min(bottom,generate.frame.minY-4) }
            if app.keyboards.firstMatch.exists {
                bottom = min(bottom,app.keyboards.firstMatch.frame.minY-4)
                let done = app.buttons["keyboard.done"]
                if done.exists { bottom = min(bottom,done.frame.minY-4) }
            }
            if bottom-top < 80 { top = app.navigationBars.firstMatch.frame.maxY+4 }
            let rect = element.frame
            let fits = rect.height <= bottom-top
            let visible = fits ? rect.minY >= top && rect.maxY <= bottom : rect.midY > top+8 && rect.midY < bottom-8
            if element.isHittable && visible { return }
            let above = element.exists && rect.midY < top+(bottom-top)/2
            let upper = (top+24-app.frame.minY)/app.frame.height
            let lower = (bottom-24-app.frame.minY)/app.frame.height
            let start = app.coordinate(withNormalizedOffset:CGVector(dx:0.96,dy:above ? upper : lower))
            let end = app.coordinate(withNormalizedOffset:CGVector(dx:0.96,dy:above ? lower : upper))
            start.press(forDuration:0.05,thenDragTo:end)
        }
        XCTFail("控件未进入可点击区域：\(element.identifier)，frame=\(element.frame)")
    }

    @MainActor private func attach(_ app:XCUIApplication,_ name:String) {
        let shot = XCTAttachment(screenshot:app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
