import XCTest
import UIKit

final class InteractionUITests: XCTestCase {
    // Let a native AX query finish before the outer waiter interrupts it.
    // Run 37's 10s waiter canceled a 30s query while audio was actually playing.
    private let previewStateTimeout:TimeInterval = 45
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor func testRevoiceMixAndLibraryUseNavigateWithCorrectAudioAndNeverStartPlayback() {
        let app = XCUIApplication()
        app.launchArguments = ["library-interaction-test","workshop-result-test","day-snapshot"]; app.launch()
        app.tabBars.buttons["工坊"].tap()
        for (mode,use,name) in [("配音","revoice.result.use","批删测试配音一"),("混音","mix.result.use","批删测试混音")] {
            app.segmentedControls["workshop.mode"].buttons[mode].tap()
            let button = app.buttons[use]; reveal(button,in:app); XCTAssertTrue(button.exists); button.tap()
            XCTAssertTrue(app.tabBars.buttons["播放"].isSelected)
            let notice = app.staticTexts["playback.selection.notice"]
            XCTAssertTrue(notice.waitForExistence(timeout:3)); XCTAssertTrue(notice.label.contains(name))
            XCTAssertTrue(notice.isHittable,"再次用于播放应显示新素材，不能停留在之前的滚动位置")
            attach(app,mode+"成品用于播放")
            let state = app.staticTexts["playback.state"]; reveal(state,in:app)
            XCTAssertTrue(state.label.contains("未准备")); XCTAssertFalse(app.buttons["playback.preview.stop"].isEnabled)
            app.tabBars.buttons["工坊"].tap()
        }
        app.tabBars.buttons["音频库"].tap()
        let use = app.buttons["library.use.16300000-0000-4000-8000-000000000015"]
        reveal(use,in:app); use.tap()
        XCTAssertTrue(app.tabBars.buttons["播放"].isSelected)
        XCTAssertTrue(app.staticTexts["playback.selection.notice"].label.contains("批删测试音乐一"))
        XCTAssertTrue(app.staticTexts["playback.selection.notice"].isHittable)
        let state = app.staticTexts["playback.state"]; reveal(state,in:app); XCTAssertTrue(state.label.contains("未准备"))
        attach(app,"工坊与音频库成品衔接播放页")
        app.terminate()
        app.launchArguments.append("workshop-missing-result-test"); app.launch()
        let selectedName = app.staticTexts["playback.selection.name"]
        XCTAssertTrue(selectedName.waitForExistence(timeout:5)); let previousName = selectedName.label
        app.tabBars.buttons["工坊"].tap()
        let missingUse = app.buttons["revoice.result.use"]; reveal(missingUse,in:app); missingUse.tap()
        let failure = app.alerts["无法用于播放"]
        XCTAssertTrue(failure.waitForExistence(timeout:3))
        XCTAssertTrue(failure.staticTexts.matching(NSPredicate(format:"label CONTAINS %@","原选择已保留")).firstMatch.exists)
        attach(app,"成品文件缺失时的明确提示")
        failure.buttons["知道了"].tap(); XCTAssertTrue(app.tabBars.buttons["工坊"].isSelected)
        app.tabBars.buttons["播放"].tap()
        XCTAssertTrue(selectedName.waitForExistence(timeout:3)); XCTAssertEqual(selectedName.label,previousName)
        let retainedState = app.staticTexts["playback.state"]; reveal(retainedState,in:app)
        XCTAssertTrue(retainedState.label.contains("未准备"))
    }

    @MainActor func testWorkshopPreviewsStopOnModesTabsSelectorsSettingsAndShare() {
        let app = XCUIApplication()
        app.launchArguments = ["library-interaction-test","workshop-result-test","preview-lifecycle-test","day-snapshot"]; app.launch()
        app.tabBars.buttons["工坊"].tap()
        for mode in ["配音","混音"] {
            app.segmentedControls["workshop.mode"].buttons[mode].tap()
            let prefix = mode == "配音" ? "revoice.result" : "mix.result"
            let play = app.buttons[prefix+".preview"],stop = app.buttons[prefix+".stop"]
            for destination in ["tab","mode","selector","cloud","share"] {
                reveal(play,in:app); play.tap()
                let playing = XCTNSPredicateExpectation(predicate:NSPredicate(format:"value == %@","正在回听"),object:stop)
                XCTAssertEqual(XCTWaiter.wait(for:[playing],timeout:previewStateTimeout),.completed)
                switch destination {
                case "tab": app.tabBars.buttons["音频库"].tap(); app.tabBars.buttons["工坊"].tap()
                case "mode":
                    app.segmentedControls["workshop.mode"].buttons[mode == "配音" ? "混音" : "配音"].tap()
                    app.segmentedControls["workshop.mode"].buttons[mode].tap()
                case "selector":
                    let picker = app.buttons[mode == "配音" ? "select.Speaker" : "select.人声"]
                    reveal(picker,in:app,towardTop:true); picker.tap(); app.buttons["取消"].tap()
                case "cloud":
                    app.buttons["workshop.tools"].tap(); app.buttons["云端连接设置"].tap()
                    XCTAssertTrue(app.buttons["cloud.connection.done"].waitForExistence(timeout:3)); app.buttons["cloud.connection.done"].tap()
                default:
                    let share = app.buttons["分享成品"]; reveal(share,in:app); share.tap()
                    let sheet = app.otherElements["ActivityListView"]
                    XCTAssertTrue(sheet.waitForExistence(timeout:3))
                    let close = app.buttons["header.closeButton"]
                    XCTAssertTrue(close.waitForExistence(timeout:3)); close.tap()
                    let dismissed = XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == false"),object:sheet)
                    XCTAssertEqual(XCTWaiter.wait(for:[dismissed],timeout:3),.completed)
                }
                reveal(stop,in:app); XCTAssertFalse(stop.isEnabled); XCTAssertEqual(stop.value as? String,"未在回听")
            }
        }
        attach(app,"工坊回听退出与取消")
    }

    @MainActor func testAutomaticInstructionTogglePreviewAndFixedReferenceAvailability() {
        let app = XCUIApplication(); app.launchArguments = ["voice-snapshot","day-snapshot"]; app.launch()
        let instruction = openBaseInstruction(in:app)
        let original = instruction.value as? String
        let automatic = app.buttons["revoice.instruction.automatic"]
        reveal(automatic,in:app); XCTAssertTrue(automatic.isEnabled)
        XCTAssertEqual(automatic.value as? String,"已开启","新草稿应默认按内容自动匹配表达指令")
        let summary = app.staticTexts["revoice.instruction.summary"]
        reveal(summary,in:app); XCTAssertTrue(summary.waitForExistence(timeout:3))
        let previewText = app.textViews["revoice.instruction.preview"]
        reveal(previewText,in:app); previewText.tap(); previewText.typeText(" warm and slow")
        app.buttons["keyboard.done"].tap()
        XCTAssertTrue((previewText.value as? String ?? "").contains("warm and slow"))
        let edited = previewText.value as? String
        let content = app.textViews["revoice.text"]
        reveal(content,in:app,towardTop:true)
        // The native AX activation point can fall on the text-selection edge.
        // Use one interior tap, then verify actual keyboard focus and the edit.
        content.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout:3),"点击正文后应出现键盘，才能继续输入")
        content.typeText(" Updated words."); app.buttons["keyboard.done"].tap()
        XCTAssertTrue((content.value as? String ?? "").contains("Updated words."))
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
        let app = XCUIApplication(); app.launchArguments = ["mix-interaction-test","preview-lifecycle-test","day-snapshot"]; app.launch()
        app.tabBars.buttons["音频库"].tap()
        for library in ["本地音频","录音与 AI"] {
            app.segmentedControls["library.scope"].buttons[library].tap()
            let stop = app.buttons["library.preview.stop"]
            XCTAssertTrue(stop.waitForExistence(timeout:5)); XCTAssertFalse(stop.isEnabled)
            app.buttons["回听"].firstMatch.tap()
            let playing = XCTNSPredicateExpectation(predicate:NSPredicate(format:"value == %@","正在回听"),object:stop)
            XCTAssertEqual(XCTWaiter.wait(for:[playing],timeout:previewStateTimeout),.completed)
            XCTAssertTrue(stop.isEnabled)

            app.tabBars.buttons["播放"].tap()
            app.tabBars.buttons["音频库"].tap()
            XCTAssertTrue(stop.waitForExistence(timeout:3)); XCTAssertFalse(stop.isEnabled)
            XCTAssertEqual(stop.value as? String,"未在回听")

            app.buttons["回听"].firstMatch.tap()
            let replaying = XCTNSPredicateExpectation(predicate:NSPredicate(format:"value == %@","正在回听"),object:stop)
            XCTAssertEqual(XCTWaiter.wait(for:[replaying],timeout:previewStateTimeout),.completed)
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
        let instruction = openBaseInstruction(in:app)
        let original = instruction.value as? String
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
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout:3))
        let fullyVisible = {
            guard row.exists,row.isHittable else { return false }
            let frame = row.frame
            let top = max(list.frame.minY,app.navigationBars["背景音乐"].frame.maxY)
            let bottom = min(list.frame.maxY,app.frame.maxY-40)
            let viewport = CGRect(x:list.frame.minX,y:top,width:list.frame.width,height:max(0,bottom-top))
            return viewport.contains(frame)
        }
        for _ in 0..<40 {
            if fullyVisible() { break }
            // A partially clipped row can be hittable at the home indicator.
            // Keep the entire target inside the list before measuring stability.
            list.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.8))
                .press(forDuration:0.05,thenDragTo:list.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.4)),withVelocity:.slow,thenHoldForDuration:0.2)
        }
        XCTAssertTrue(fullyVisible())
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
        XCTAssertTrue(app.navigationBars["背景音乐"].waitForExistence(timeout:10))
        let hidden = XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == false"),object:app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for:[hidden],timeout:10),.completed)
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
        let instruction = openBaseInstruction(in:app)
        reveal(instruction,in:app); instruction.tap(); instruction.typeText("relaxed and clear")
        app.buttons["keyboard.done"].tap()
        reveal(editor,in:app,towardTop:true); editor.tap(); editor.typeText(" Latest words.")
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
        XCTAssertTrue(app.buttons["revoice.generate"].label.contains("旧任务")); XCTAssertFalse(app.buttons["revoice.generate"].isEnabled)
        XCTAssertTrue((editor.value as? String ?? "").contains("Updated draft."))
        attach(app,"旧任务与新草稿分开")
        app.terminate()
        app.launchArguments += ["mix-interaction-test","voice-recovery-empty-input-test"]; app.launch()
        XCTAssertTrue(editor.waitForExistence(timeout:10)); XCTAssertEqual(editor.value as? String,"")
        let recognize = app.buttons["revoice.generate"]
        XCTAssertTrue(recognize.waitForExistence(timeout:5)); XCTAssertEqual(recognize.label,"识别文字")
        XCTAssertTrue(recognize.isEnabled,"旧任务只阻止新云端提交，空草稿的设备端识别仍可操作")
        reveal(pendingText,in:app); XCTAssertEqual(pendingText.label,"这是之前已提交的配音，恢复时请继续取回这一份。")
        XCTAssertTrue(app.buttons["revoice.pending.stop"].exists)
        attach(app,"旧任务保留时空草稿仍可识别")
    }

    @MainActor func testLargeTextCustomLayoutCanReachAllInputsAndGenerate() {
        let app = XCUIApplication(); app.launchArguments = ["voice-custom-snapshot","voice-large-type","night-snapshot"]; app.launch()
        let speaker = app.buttons["select.Speaker"]
        XCTAssertTrue(speaker.waitForExistence(timeout:5)); reveal(speaker,in:app)
        speaker.tap(); XCTAssertTrue(app.buttons["choice.Dylan"].waitForExistence(timeout:5)); app.buttons["choice.Dylan"].tap()
        let instruction = openBaseInstruction(in:app)
        reveal(instruction,in:app); instruction.tap(); instruction.typeText("slow and natural")
        app.buttons["keyboard.done"].tap()
        let editor = app.textViews["revoice.text"]
        reveal(editor,in:app,towardTop:true); editor.tap(); editor.typeText(" Large text draft.")
        app.buttons["keyboard.done"].tap()
        let generate = app.buttons["revoice.generate"]
        XCTAssertTrue(generate.exists); XCTAssertTrue(app.frame.contains(generate.frame)); XCTAssertFalse(generate.isEnabled)
        XCTAssertEqual(instruction.value as? String,"slow and natural")
        XCTAssertTrue((editor.value as? String ?? "").contains("Large text draft."))
        attach(app,"大字体深色配音编辑")
    }

    @MainActor func testRecognizedDraftKeepsKeyboardForRealPunctuationSymbolAndLetterKeys() {
        let app = XCUIApplication()
        app.launchArguments = ["voice-recognition-keyboard-test","day-snapshot"]
        app.launchEnvironment["REVOICE_KEYBOARD_DRAFT_ID"] = UUID().uuidString
        app.launchEnvironment["KEYBOARD_DIAGNOSTICS"] = "1"
        app.launch()
        let editor = app.textViews["revoice.text"]
        XCTAssertTrue(editor.waitForExistence(timeout:5)); XCTAssertEqual(editor.value as? String,"")
        let automatic = app.buttons["revoice.instruction.automatic"]
        reveal(automatic,in:app); XCTAssertEqual(automatic.value as? String,"已开启")
        XCTAssertFalse(app.buttons["revoice.range.open"].exists)
        XCTAssertFalse(app.buttons["设置识别片段"].exists)

        // Press the real production action, which prepares PCM and calls recognize().
        let recognize = app.buttons["revoice.generate"]
        XCTAssertEqual(recognize.label,"识别文字"); XCTAssertTrue(recognize.isEnabled); recognize.tap()
        let undo = app.buttons["revoice.speech.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout:15),"识别成功应产生真实的撤销状态")
        reveal(editor,in:app,towardTop:true)
        var expected = "语音识别后的文字"
        XCTAssertEqual(editor.value as? String,expected)
        // Focus once. Every subsequent event is an actual soft-key tap, with no refocus.
        editor.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout:3))
        attachKeyboardDescription(keyboard,name:"识别后字母键盘 AX")
        tapKeyboardKey(["more","more, numbers","123","Numbers","numbers"],in:keyboard)
        XCTAssertTrue(keyboard.exists,"切换数字键盘不能收起键盘")
        attachKeyboardDescription(keyboard,name:"识别后数字与符号键盘 AX")
        for character in [".","@"] {
            tapKeyboardKey([character],in:keyboard)
            expected += character
            assertKeyboardEdit(expected,editor:editor,keyboard:keyboard)
            XCTAssertFalse(undo.exists,"手工修改后旧识别撤销入口应消失")
        }
        attach(app,"识别后实际标点符号按键保持键盘")
        tapKeyboardKey(["letters","more, letters","ABC","Letters"],in:keyboard)
        XCTAssertTrue(keyboard.exists,"切回字母键盘不能收起键盘")
        // A complete dictionary word avoids committing a correction for a
        // deliberate non-word (run 42 changed "ab" to "an" on Done).
        for labels in [["c","C"],["a","A"]] {
            expected += tapKeyboardKey(labels,in:keyboard)
            assertKeyboardEdit(expected,editor:editor,keyboard:keyboard)
        }

        waitForSavedDraft(in:app)
        XCTAssertTrue(keyboard.exists,"草稿保存更新不能打断正文键盘焦点")
        expected += tapKeyboardKey(["t","T"],in:keyboard)
        assertKeyboardEdit(expected,editor:editor,keyboard:keyboard)
        attach(app,"识别后实际字母按键及草稿保存保持键盘")
        app.buttons["keyboard.done"].tap(); XCTAssertFalse(keyboard.exists)
        XCTAssertEqual(editor.value as? String,expected,"完成输入后保留完整单词，再验证草稿重启恢复")

        // The isolated store is real. Explicit off/on choices must survive relaunch.
        setAutomaticInstruction(automatic,to:false,in:app)
        waitForSavedDraft(in:app)
        app.terminate(); app.launchArguments.append("voice-recognition-keyboard-resume-test"); app.launch()
        XCTAssertTrue(editor.waitForExistence(timeout:10)); XCTAssertEqual(editor.value as? String,expected)
        reveal(automatic,in:app); XCTAssertEqual(automatic.value as? String,"已关闭")
        XCTAssertFalse(app.buttons["revoice.range.open"].exists)
        setAutomaticInstruction(automatic,to:true,in:app)
        waitForSavedDraft(in:app)
        app.terminate(); app.launch()
        XCTAssertTrue(editor.waitForExistence(timeout:10)); XCTAssertEqual(editor.value as? String,expected)
        reveal(automatic,in:app); XCTAssertEqual(automatic.value as? String,"已开启")
        attach(app,"自动表达默认开启与手动开关恢复")
    }

    @MainActor func testKeyboardControlledIsolationAcrossAllProductionEditors() {
        executionTimeAllowance = 1200
        // Each comparison changes ONE factor relative to the 1.6.7 baseline.
        // Simulator passing in A does not establish the user's device root cause.
        for variant in ["legacy","no-outside","no-disappear","coalesced-state"] {
            XCTContext.runActivity(named:"keyboard-isolation-"+variant) { _ in
                let app = keyboardApp(experiment:variant)
                let text = app.textViews["revoice.text"]
                focusOnce(text,in:app)
                var expected = softWord("cat",editor:text,in:app,starting:"")
                waitForSavedDraft(in:app); XCTAssertTrue(app.keyboards.firstMatch.exists)
                pressSoft(["space"],in:app); expected += " "
                assertKeyboardEdit(expected,editor:text,keyboard:app.keyboards.firstMatch)
                app.buttons["keyboard.done"].tap(); assertKeyboardHidden(in:app)
                let baseline = openBaseInstruction(in:app)
                XCTAssertTrue(baseline.isEnabled,"自定义 Speaker 模式合法支持基础风格编辑")
                focusOnce(baseline,in:app)
                _ = softWord("calm",editor:baseline,in:app,starting:"")
                app.buttons["keyboard.done"].tap(); assertKeyboardHidden(in:app)
                let automatic = app.textViews["revoice.instruction.preview"]
                reveal(automatic,in:app); focusOnce(automatic,in:app)
                clearWithSystemMenu(automatic,in:app)
                _ = softWord("clear",editor:automatic,in:app,starting:"")
                waitForSavedDraft(in:app); XCTAssertTrue(app.keyboards.firstMatch.exists)
                attach(app,"keyboard-isolation-"+variant+"-automatic")
                app.buttons["keyboard.done"].tap(); assertKeyboardHidden(in:app)
                app.terminate()
            }
        }
    }

    @MainActor func testEmptyAndRestoredTextContinuousSoftKeysDeleteReturnAndEditorSwitch() {
        let app = keyboardApp()
        let editor = app.textViews["revoice.text"]
        focusOnce(editor,in:app)
        var expected = softWord("cat",editor:editor,in:app,starting:"")
        pressSoft(["delete","Delete"],in:app); expected.removeLast()
        assertKeyboardEdit(expected,editor:editor,keyboard:app.keyboards.firstMatch)
        expected += pressSoft(["t","T"],in:app)
        assertKeyboardEdit(expected,editor:editor,keyboard:app.keyboards.firstMatch)
        pressSoft(["return","Return"],in:app); expected += "\n"
        assertKeyboardEdit(expected,editor:editor,keyboard:app.keyboards.firstMatch)
        expected = softWord("dog",editor:editor,in:app,starting:expected)
        pressSoft(["numbers","123","more, numbers"],in:app)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        for symbol in [".","@"] {
            pressSoft([symbol],in:app); expected += symbol
            assertKeyboardEdit(expected,editor:editor,keyboard:app.keyboards.firstMatch)
        }
        pressSoft(["letters","ABC","more, letters"],in:app)
        waitForSavedDraft(in:app); XCTAssertTrue(app.keyboards.firstMatch.exists)
        expected = softWord("cat",editor:editor,in:app,starting:expected)
        attach(app,"empty-text-soft-keys-delete-return-autosave")
        // Switching inputs is intentional; no per-character refocusing occurs.
        let baseline = openBaseInstruction(in:app); focusOnce(baseline,in:app)
        _ = softWord("calm",editor:baseline,in:app,starting:"")
        reveal(editor,in:app,towardTop:true); focusOnce(editor,in:app,atBeginning:true)
        pressSoft(["numbers","123","more, numbers"],in:app)
        pressSoft(["!"],in:app); expected = "!" + expected
        assertKeyboardEdit(expected,editor:editor,keyboard:app.keyboards.firstMatch)
        app.buttons["keyboard.done"].tap(); assertKeyboardHidden(in:app)
        XCTAssertEqual(editor.value as? String,expected)
        waitForSavedDraft(in:app)
        app.terminate(); app.launchArguments.append("voice-recognition-keyboard-resume-test"); app.launch()
        XCTAssertTrue(editor.waitForExistence(timeout:10)); XCTAssertEqual(editor.value as? String,expected)
        focusOnce(editor,in:app,atBeginning:true)
        pressSoft(["numbers","123","more, numbers"],in:app)
        pressSoft(["."],in:app); expected = "." + expected
        assertKeyboardEdit(expected,editor:editor,keyboard:app.keyboards.firstMatch)
        // The tab bar is covered by the system keyboard. Exercise a real page
        // exit through the visible workshop selector without dismissing first,
        // and require the destination before checking keyboard disappearance.
        let workshop = app.segmentedControls["workshop.mode"]
        let mix = workshop.buttons["混音"]
        XCTAssertTrue(mix.exists); XCTAssertTrue(mix.isHittable)
        XCTAssertLessThan(mix.frame.maxY,app.keyboards.firstMatch.frame.minY)
        mix.tap()
        XCTAssertTrue(app.buttons["mix.save"].waitForExistence(timeout:5),"必须确实离开正文编辑页")
        XCTAssertFalse(editor.exists)
        assertKeyboardHidden(in:app)
        attach(app,"restored-text-mode-exit-keyboard-hidden")
        XCTAssertTrue(workshop.buttons["配音"].isHittable); workshop.buttons["配音"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout:5)); XCTAssertEqual(editor.value as? String,expected)
        assertKeyboardHidden(in:app); waitForSavedDraft(in:app)
        let library = app.tabBars.buttons["音频库"]
        XCTAssertTrue(library.isHittable); library.tap()
        XCTAssertTrue(app.segmentedControls["library.scope"].waitForExistence(timeout:5))
        assertKeyboardHidden(in:app)
        XCTAssertTrue(app.tabBars.buttons["工坊"].isHittable); app.tabBars.buttons["工坊"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout:5)); XCTAssertEqual(editor.value as? String,expected)
        assertKeyboardHidden(in:app)
        attach(app,"restored-text-edit-and-tab-exit")
    }

    @MainActor func testBaseStyleFirstTapContinuousSoftKeysAutomaticOnOffAndRestore() {
        let app = keyboardApp()
        let automatic = app.buttons["revoice.instruction.automatic"]
        let baseline = openBaseInstruction(in:app)
        XCTAssertTrue(baseline.isEnabled)
        focusOnce(baseline,in:app)
        var expected = softWord("calm",editor:baseline,in:app,starting:"")
        waitForSavedDraft(in:app); XCTAssertTrue(app.keyboards.firstMatch.exists)
        pressSoft(["numbers","123","more, numbers"],in:app); pressSoft(["."],in:app); expected += "."
        assertKeyboardEdit(expected,editor:baseline,keyboard:app.keyboards.firstMatch)
        attach(app,"baseline-first-tap-soft-keys-automatic-on")
        app.buttons["keyboard.done"].tap(); assertKeyboardHidden(in:app)
        setAutomaticInstruction(automatic,to:false,in:app)
        let manualBaseline = openBaseInstruction(in:app)
        XCTAssertEqual(manualBaseline.value as? String,expected)
        focusOnce(manualBaseline,in:app,atBeginning:true)
        pressSoft(["numbers","123","more, numbers"],in:app); pressSoft(["!"],in:app); expected = "!" + expected
        assertKeyboardEdit(expected,editor:manualBaseline,keyboard:app.keyboards.firstMatch)
        app.buttons["keyboard.done"].tap(); assertKeyboardHidden(in:app); waitForSavedDraft(in:app)
        // Exercise default reset under a legitimately editable preset, with its
        // catalog loaded before the offline resume fixture; no capability bypass.
        let mode = app.segmentedControls["revoice.mode"]
        reveal(mode,in:app,towardTop:true); mode.buttons["预设声线"].tap()
        let preset = openBaseInstruction(in:app)
        XCTAssertEqual(preset.value as? String,"自然、放松的日常表达。")
        focusOnce(preset,in:app); clearWithSystemMenu(preset,in:app)
        _ = softWord("calm",editor:preset,in:app,starting:"")
        app.buttons["keyboard.done"].tap(); assertKeyboardHidden(in:app)
        app.buttons["revoice.instruction.reset"].tap()
        XCTAssertEqual(preset.value as? String,"自然、放松的日常表达。")
        reveal(mode,in:app,towardTop:true); mode.buttons["自定义配音"].tap()
        XCTAssertEqual(openBaseInstruction(in:app).value as? String,expected)
        waitForSavedDraft(in:app)
        app.terminate(); app.launchArguments.append("voice-recognition-keyboard-resume-test"); app.launch()
        let restored = openBaseInstruction(in:app)
        XCTAssertEqual(restored.value as? String,expected)
        reveal(automatic,in:app); XCTAssertEqual(automatic.value as? String,"已关闭")
        attach(app,"baseline-restored-and-preset-reset")
    }

    @MainActor func testAutomaticInstructionContinuousSoftKeysManualPreservationStaleRematchAndRestore() {
        let app = keyboardApp()
        let text = app.textViews["revoice.text"]
        focusOnce(text,in:app); _ = softWord("cat",editor:text,in:app,starting:"")
        app.buttons["keyboard.done"].tap(); assertKeyboardHidden(in:app)
        let automatic = app.textViews["revoice.instruction.preview"]
        reveal(automatic,in:app); XCTAssertFalse((automatic.value as? String ?? "").isEmpty)
        focusOnce(automatic,in:app); clearWithSystemMenu(automatic,in:app)
        let manual = softWord("clear",editor:automatic,in:app,starting:"")
        waitForSavedDraft(in:app); XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertTrue(app.staticTexts["revoice.instruction.summary"].label.contains("已手动调整"))
        attach(app,"automatic-manual-soft-keys-and-autosave")
        app.buttons["keyboard.done"].tap(); assertKeyboardHidden(in:app)
        reveal(text,in:app,towardTop:true); focusOnce(text,in:app)
        pressSoft(["numbers","123","more, numbers"],in:app); pressSoft(["!"],in:app)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        app.buttons["keyboard.done"].tap(); assertKeyboardHidden(in:app)
        let baseline = openBaseInstruction(in:app); focusOnce(baseline,in:app)
        let baselineText = softWord("calm",editor:baseline,in:app,starting:"")
        app.buttons["keyboard.done"].tap(); assertKeyboardHidden(in:app)
        reveal(automatic,in:app); XCTAssertEqual(automatic.value as? String,manual)
        XCTAssertTrue(app.staticTexts["revoice.instruction.stale"].exists)
        waitForSavedDraft(in:app)
        app.terminate(); app.launchArguments.append("voice-recognition-keyboard-resume-test"); app.launch()
        reveal(automatic,in:app); XCTAssertEqual(automatic.value as? String,manual)
        XCTAssertTrue(app.staticTexts["revoice.instruction.summary"].label.contains("已手动调整"))
        // Voice change retains the existing explicit cancel/discard confirmation.
        reveal(app.buttons["select.Speaker"],in:app,towardTop:true)
        app.buttons["select.Speaker"].tap(); app.buttons["choice.Dylan"].tap()
        XCTAssertTrue(app.alerts["放弃手动调整的指令？"].waitForExistence(timeout:5))
        app.alerts.buttons["取消"].tap()
        reveal(automatic,in:app); XCTAssertEqual(automatic.value as? String,manual)
        let rematch = app.buttons["revoice.instruction.rematch"]
        reveal(rematch,in:app); rematch.tap()
        XCTAssertFalse(app.staticTexts["revoice.instruction.summary"].label.contains("已手动调整"))
        XCTAssertFalse(app.staticTexts["revoice.instruction.stale"].exists)
        XCTAssertNotEqual(automatic.value as? String,manual)
        setAutomaticInstruction(app.buttons["revoice.instruction.automatic"],to:false,in:app)
        XCTAssertFalse(automatic.exists)
        XCTAssertEqual(openBaseInstruction(in:app).value as? String,baselineText)
        attach(app,"automatic-restored-manual-cancel-rematch-off")
    }

    @MainActor private func keyboardApp(experiment:String = "fixed") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["voice-recognition-keyboard-test","day-snapshot"]
        app.launchEnvironment["REVOICE_KEYBOARD_DRAFT_ID"] = UUID().uuidString
        app.launchEnvironment["KEYBOARD_DIAGNOSTICS"] = "1"
        app.launchEnvironment["KEYBOARD_EXPERIMENT"] = experiment
        app.launch(); XCTAssertTrue(app.textViews["revoice.text"].waitForExistence(timeout:10))
        return app
    }
    @MainActor private func focusOnce(_ editor:XCUIElement,in app:XCUIApplication,atBeginning:Bool = false) {
        XCTAssertTrue(editor.isEnabled); XCTAssertTrue(editor.isHittable)
        let before = editor.value as? String
        if atBeginning {
            // This single tap establishes focus and chooses the first line.
            // UIKit can snap a tap after leading punctuation even at its edge;
            // move the caret with the native keyboard trackpad below.
            editor.coordinate(withNormalizedOffset:CGVector(dx:0,dy:0.1)).tap()
        } else { editor.tap() }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout:3),"首次点击必须唤起键盘，禁止重试聚焦")
        if atBeginning { XCTAssertEqual(editor.value as? String,before,"首次聚焦不能修改现有文字") }
        if app.launchEnvironment["KEYBOARD_EXPERIMENT"] == "fixed" {
            let visible = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in
                let frame = editor.frame
                let top = max(app.navigationBars.firstMatch.frame.maxY,app.segmentedControls["workshop.mode"].frame.maxY)
                var bottom = app.keyboards.firstMatch.frame.minY
                for control in [app.buttons["keyboard.done"],app.buttons["revoice.generate"]] where control.exists {
                    bottom = min(bottom,control.frame.minY)
                }
                return editor.isHittable && frame.minY > top && frame.maxY < bottom
            },object:nil)
            XCTAssertEqual(XCTWaiter.wait(for:[visible],timeout:3),.completed,"首次聚焦后编辑器必须在键盘和固定按钮上方，无测试滚动或再次聚焦")
            XCTAssertTrue(app.keyboards.firstMatch.exists)
            attach(app,"keyboard-visible-first-focus-"+editor.identifier)
        }
        attachKeyboardDescription(app.keyboards.firstMatch,name:"keyboard-first-focus-"+editor.identifier)
        if atBeginning {
            let keyboard = app.keyboards.firstMatch
            XCTAssertTrue(keyboard.exists)
            let space = keyboard.descendants(matching:.any)
                .matching(NSPredicate(format:"label IN %@ OR identifier IN %@",["space","Space","空格"],["space","Space","空格"])).firstMatch
            XCTAssertTrue(space.waitForExistence(timeout:3)); XCTAssertTrue(space.isHittable)
            // Apple's native Space-bar trackpad moves the insertion point while
            // keeping the existing editor focused. Drag within the keyboard to
            // its leading edge; do not tap the editor again or use hardware keys.
            let endY = (space.frame.midY-app.frame.minY)/app.frame.height
            space.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5))
                .press(forDuration:1,thenDragTo:app.coordinate(withNormalizedOffset:CGVector(dx:0.01,dy:endY)),
                       withVelocity:.slow,thenHoldForDuration:0.2)
            XCTAssertTrue(keyboard.exists,"系统光标移动期间键盘必须保持")
            XCTAssertEqual(editor.value as? String,before,"系统触控板只能移动光标，不能改变原稿")
            attach(app,"keyboard-native-trackpad-start-"+editor.identifier)
            // A real Delete at the document start must leave the entire draft
            // unchanged. Verify position before inserting, rather than assuming
            // that a focus tap places the caret before the first glyph.
            pressSoft(["delete","Delete"],in:app)
            XCTAssertEqual(editor.value as? String,before,"开头 Delete 必须保留原稿，不能把光标位置错误当作失焦")
        }
    }
    @discardableResult @MainActor private func pressSoft(_ labels:[String],in app:XCUIApplication) -> String {
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.exists,"按下软键之前键盘必须存在")
        let key = keyboard.descendants(matching:.any).matching(NSPredicate(format:"label IN %@ OR identifier IN %@",labels,labels)).firstMatch
        XCTAssertTrue(key.waitForExistence(timeout:3)); XCTAssertTrue(key.isHittable)
        let label = key.label; key.tap()
        XCTAssertTrue(keyboard.exists,"每个真实软键后键盘必须持续存在")
        return label
    }
    @MainActor private func softWord(_ word:String,editor:XCUIElement,in app:XCUIApplication,starting:String) -> String {
        // Choose lowercase with the real system Shift key. A capitalized word
        // can be autocorrected on punctuation/Done after the per-key checks.
        // Keep autocorrection enabled and keep exact committed-value assertions.
        let keyboard = app.keyboards.firstMatch
        if let first = word.first {
            let lower = String(first).lowercased()
            if !keyboard.keys[lower].exists && keyboard.keys[lower.uppercased()].exists {
                pressSoft(["shift","Shift"],in:app)
            }
            XCTAssertTrue(keyboard.keys[lower].exists,"真实 Shift 操作后必须显示小写软键")
        }
        var expected = starting
        for character in word {
            let value = String(character)
            expected += pressSoft([value],in:app)
            assertKeyboardEdit(expected,editor:editor,keyboard:app.keyboards.firstMatch)
        }
        return expected
    }
    @MainActor private func clearWithSystemMenu(_ editor:XCUIElement,in app:XCUIApplication) {
        editor.press(forDuration:1.2)
        let select = app.descendants(matching:.any).matching(NSPredicate(format:"label IN %@",["Select All","全选"])).firstMatch
        XCTAssertTrue(select.waitForExistence(timeout:3),"必须通过系统选择菜单清空生成的内容")
        select.tap(); pressSoft(["delete","Delete"],in:app)
        assertKeyboardEdit("",editor:editor,keyboard:app.keyboards.firstMatch)
    }
    @MainActor private func assertKeyboardHidden(in app:XCUIApplication) {
        let hidden = XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == false"),object:app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for:[hidden],timeout:3),.completed)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
    }

    @MainActor private func openBaseInstruction(in app:XCUIApplication) -> XCUIElement {
        let instruction = app.textFields["revoice.instruction"]
        if !instruction.exists {
            let disclosure = app.buttons["角色基础风格 · 可选"]
            reveal(disclosure,in:app)
            XCTAssertTrue(disclosure.exists); disclosure.tap()
        }
        reveal(instruction,in:app)
        XCTAssertTrue(instruction.waitForExistence(timeout:5))
        return instruction
    }

    @MainActor private func attachKeyboardDescription(_ keyboard:XCUIElement,name:String) {
        let attachment = XCTAttachment(string:keyboard.debugDescription)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    @discardableResult
    @MainActor private func tapKeyboardKey(_ labels:[String],in keyboard:XCUIElement) -> String {
        let key = keyboard.keys.matching(NSPredicate(format:"label IN %@",labels)).firstMatch
        XCTAssertTrue(key.waitForExistence(timeout:3),"缺少实际键盘按键 \(labels)，请查看键盘 AX 附件")
        XCTAssertTrue(key.isHittable)
        let label = key.label
        key.tap()
        return label
    }

    @MainActor private func assertKeyboardEdit(_ expected:String,editor:XCUIElement,keyboard:XCUIElement) {
        let changed = XCTNSPredicateExpectation(predicate:NSPredicate(format:"value == %@",expected),object:editor)
        XCTAssertEqual(XCTWaiter.wait(for:[changed],timeout:3),.completed)
        XCTAssertTrue(keyboard.exists,"输入一个字符之后键盘必须继续显示")
        XCTAssertEqual(editor.value as? String,expected)
    }

    @MainActor private func waitForSavedDraft(in app:XCUIApplication) {
        let saved = app.staticTexts["草稿已保存到本机"]
        // Let the debounce elapse before accepting a saved label from an earlier edit.
        // Relaunch assertions below independently verify the actual persisted choices.
        let settledAfter = Date().addingTimeInterval(0.6)
        let savedCurrentEdit = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in
            Date() >= settledAfter && saved.exists
        },object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[savedCurrentEdit],timeout:5),.completed)
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
        executionTimeAllowance = 1800
        let app = XCUIApplication()
        for scope in ["本地音频","录音与 AI"] {
            app.launchArguments = ["library-interaction-test","day-snapshot"]; app.launch()
            app.tabBars.buttons["音频库"].tap(); app.segmentedControls["library.scope"].buttons[scope].tap()
            app.buttons["library.selection"].tap()
            if scope == "本地音频" {
                let builtin = app.buttons["library.select.00000000-0000-4000-8000-000000000001"]
                reveal(builtin,in:app); XCTAssertFalse(builtin.isEnabled)
            }
            let suffixes = scope == "本地音频" ? [19,18,17,15,14] : [19,18,17,14,13]
            var names:[String:String] = [:]
            for suffix in suffixes {
                let id = String(format:"16300000-0000-4000-8000-%012d",suffix)
                let select = app.buttons["library.select."+id]
                reveal(select,in:app,towardTop:true)
                names[id] = app.staticTexts["library.name."+id].label
                select.tap(); XCTAssertEqual(select.value as? String,"已选择")
            }
            let delete = app.buttons["library.delete.selected"]
            XCTAssertTrue(delete.isEnabled); delete.tap()
            assertDeletion(names,in:app)
            attach(app,"first-five-delete-"+(scope == "本地音频" ? "local" : "recordings"))
            app.buttons["取消"].tap()
            XCTAssertTrue(delete.isEnabled); XCTAssertTrue(delete.label.contains("5"))
            delete.tap(); assertDeletion(names,in:app); app.buttons["取消"].tap()
            let changedID = "16300000-0000-4000-8000-000000000019"
            let changed = app.buttons["library.select."+changedID]
            reveal(changed,in:app,towardTop:true); changed.tap()
            var fewer = names; fewer.removeValue(forKey:changedID)
            delete.tap(); assertDeletion(fewer,in:app); app.buttons["取消"].tap()
            reveal(changed,in:app,towardTop:true); changed.tap()
            delete.tap(); assertDeletion(names,in:app)
            app.buttons["library.delete.confirm"].tap()
            let summary = deletionSummary(in:app)
            XCTAssertFalse(summary.label.contains("未删除"))
            XCTAssertTrue(summary.label.contains("已删除 5 项"))
            XCTAssertFalse(app.buttons["library.delete.selected"].exists)
            if scope == "本地音频" { XCTAssertTrue(app.buttons["回听"].exists) }
            else { XCTAssertFalse(app.buttons["回听"].exists) }
            attach(app,"批量删除_"+scope); app.terminate()
        }
    }

    @MainActor func testSelectionModeClosesDetailsAndRestoresCollapsedEntries() {
        let app = XCUIApplication(); app.launchArguments = ["library-interaction-test","day-snapshot"]; app.launch()
        app.tabBars.buttons["音频库"].tap()
        let revoiceID = "16300000-0000-4000-8000-000000000017"
        let mixID = "16300000-0000-4000-8000-000000000019"
        let revoice = app.buttons["library.revoice.details."+revoiceID]
        let mix = app.buttons["library.mix.details."+mixID]
        reveal(revoice,in:app); revoice.tap()
        XCTAssertTrue(app.staticTexts["批删测试配音正文 17"].exists)
        reveal(mix,in:app,towardTop:true); mix.tap()
        // DisclosureGroup propagates its identifier to content in the actual AX tree.
        // Match the source text for this asset, excluding the volume caption.
        let origin = app.staticTexts.matching(identifier:"library.mix.details."+mixID)
            .matching(NSPredicate(format:"label BEGINSWITH %@","人声：")).firstMatch
        XCTAssertTrue(origin.waitForExistence(timeout:3))
        XCTAssertTrue(origin.label.contains("人声：批删测试原声")); XCTAssertTrue(origin.label.contains("音乐：内置测试音"))
        XCTAssertFalse(origin.label.contains("16300000"))
        app.buttons["library.selection"].tap()
        XCTAssertFalse(revoice.exists); XCTAssertFalse(mix.exists)
        XCTAssertFalse(app.staticTexts["批删测试配音正文 17"].exists); XCTAssertFalse(origin.exists)
        XCTAssertFalse(app.buttons["回听"].exists); XCTAssertFalse(app.buttons["用于播放"].exists); XCTAssertFalse(app.buttons["分享"].exists)
        let select = app.buttons["library.select."+mixID]
        reveal(select,in:app,towardTop:true); select.tap(); XCTAssertEqual(select.value as? String,"已选择")
        app.buttons["library.selection"].tap()
        reveal(revoice,in:app)
        XCTAssertFalse(app.staticTexts["批删测试配音正文 17"].exists)
        revoice.tap(); XCTAssertTrue(app.staticTexts["批删测试配音正文 17"].exists)
        reveal(mix,in:app,towardTop:true); XCTAssertFalse(origin.exists)
        mix.tap(); XCTAssertTrue(origin.waitForExistence(timeout:3))
        XCTAssertTrue(origin.label.contains("人声：批删测试原声")); XCTAssertTrue(origin.label.contains("音乐：内置测试音"))
        XCTAssertFalse(origin.label.contains("16300000"))
        attach(app,"selection-details-restored")
    }

    @MainActor func testSingleDeletionShowsSameFileAfterCancelAndReopen() {
        let app = XCUIApplication(); app.launchArguments = ["library-interaction-test","day-snapshot"]; app.launch()
        app.tabBars.buttons["音频库"].tap()
        let id = "16300000-0000-4000-8000-000000000015"
        let name = app.staticTexts["library.name."+id]
        reveal(name,in:app); let label = name.label
        for _ in 0..<2 {
            reveal(name,in:app); name.swipeLeft()
            let remove = app.buttons["library.delete.single."+id]
            XCTAssertTrue(remove.waitForExistence(timeout:3)); remove.tap()
            assertDeletion([id:label],in:app)
            app.buttons["取消"].tap()
            XCTAssertTrue(name.waitForExistence(timeout:3))
            XCTAssertEqual(name.label,label)
        }
        reveal(name,in:app); name.swipeLeft(); app.buttons["library.delete.single."+id].tap()
        assertDeletion([id:label],in:app); attach(app,"single-delete-after-cancel")
        app.buttons["library.delete.confirm"].tap()
        let summary = deletionSummary(in:app)
        XCTAssertTrue(summary.label.contains("已删除 1 项"))
    }

    @MainActor func testCloudConnectionBothEntriesFollowThemeAndLargeType() {
        // Ten settings visits across themes/type sizes exceeded 600 s on run 35.
        executionTimeAllowance = 1800
        let app = XCUIApplication()
        var normalCaptionHeights:[String:CGFloat] = [:]
        for night in [false,true] {
            for large in [false,true] {
                app.launchArguments = ["voice-snapshot",night ? "night-snapshot" : "day-snapshot"]
                if large { app.launchArguments.append("voice-large-type") }
                app.launch()
                for entry in ["tools","workshop"] {
                    if entry == "tools" {
                        app.buttons["workshop.tools"].tap(); app.buttons["云端连接设置"].tap()
                    } else {
                        let open = app.buttons["revoice.connection"]
                        reveal(open,in:app); open.tap()
                    }
                    let field = app.secureTextFields["cloud.connection.configuration"]
                    XCTAssertTrue(field.waitForExistence(timeout:5)); reveal(field,in:app)
                    let captionHeight = app.staticTexts["一次设置，随时重新配音。"].frame.height
                    let captionKey = entry+(night ? "-dark" : "-light")
                    if large {
                        XCTAssertGreaterThan(captionHeight,(normalCaptionHeights[captionKey] ?? captionHeight)*1.3)
                    } else { normalCaptionHeights[captionKey] = captionHeight }
                    assertCloudBackground(night:night,in:app)
                    attach(app,"cloud-"+entry+(night ? "-dark" : "-light")+(large ? "-large" : "-normal"))
                    app.buttons["cloud.connection.done"].tap()
                }
                app.terminate()
            }
        }
        app.launchArguments = ["voice-snapshot"]; app.launch()
        app.buttons["workshop.tools"].tap(); app.buttons["云端连接设置"].tap()
        XCTAssertTrue(app.secureTextFields["cloud.connection.configuration"].waitForExistence(timeout:5))
        assertCloudBackground(night:true,in:app); app.buttons["cloud.connection.done"].tap()
        app.buttons["切换到日间主题"].tap()
        app.buttons["workshop.tools"].tap(); app.buttons["云端连接设置"].tap()
        XCTAssertTrue(app.secureTextFields["cloud.connection.configuration"].waitForExistence(timeout:5))
        assertCloudBackground(night:false,in:app)
    }

    @MainActor func testApplyKeepsAppVolumeSeparateFromPreviewVolume() {
        let app = XCUIApplication(); app.launchArguments = ["day-snapshot"]; app.launch()
        let disclosure = app.buttons["试听音量与时长"]
        reveal(disclosure,in:app); disclosure.tap()
        let previewVolume = app.sliders["playback.preview.volume"]
        reveal(previewVolume,in:app); previewVolume.adjust(toNormalizedSliderPosition:0.9)
        let formal = app.sliders["playback.volume"]
        for value in [0.04,0.20] {
            reveal(formal,in:app); formal.adjust(toNormalizedSliderPosition:value)
            let chosen = formal.value as? String
            XCTAssertNotEqual(chosen,"50%")
            for _ in 0..<2 {
                let apply = app.buttons["playback.apply"]
                reveal(apply,in:app,towardTop:true); apply.tap()
                reveal(formal,in:app); XCTAssertEqual(formal.value as? String,chosen)
            }
        }
        attach(app,"playback-volume-after-apply")
    }

    @MainActor func testPlaybackPreviewsStopOnTabsPickerNavigationAndConnection() {
        executionTimeAllowance = 1800
        let app = XCUIApplication(); app.launchArguments = ["mix-interaction-test","preview-lifecycle-test","day-snapshot"]; app.launch()
        let stop = app.buttons["playback.preview.stop"]
        let progress = app.descendants(matching:.any)["playback.preview.progress"]
        for mode in ["playback.preview.full","playback.preview.fiveSeconds"] {
            for destination in ["工坊","音频库","picker","history","cloud","speed"] {
                let start = app.buttons[mode]
                reveal(start,in:app,towardTop:true); start.tap()
                if mode == "playback.preview.fiveSeconds" {
                    // Five seconds can finish before a hosted runner returns its AX snapshot.
                    // Require real audio progress; completion preserves it until this page exits.
                    let advanced = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in
                        guard let value = progress.value as? String,let seconds = Double(value) else { return false }
                        return seconds > 0 && seconds < 6
                    },object:nil)
                    XCTAssertEqual(XCTWaiter.wait(for:[advanced],timeout:previewStateTimeout),.completed)
                } else {
                    let playing = XCTNSPredicateExpectation(predicate:NSPredicate(format:"value == %@","正在试听"),object:stop)
                    XCTAssertEqual(XCTWaiter.wait(for:[playing],timeout:previewStateTimeout),.completed)
                }
                switch destination {
                case "工坊","音频库":
                    app.tabBars.buttons[destination].tap(); app.tabBars.buttons["播放"].tap()
                case "picker":
                    let choose = app.buttons["playback.chooseAudio"]; reveal(choose,in:app,towardTop:true); choose.tap()
                    XCTAssertTrue(app.navigationBars["选择播放音频"].waitForExistence(timeout:3)); app.buttons["取消"].tap()
                case "history":
                    app.buttons["workshop.tools"].tap(); app.buttons["实验历史"].tap()
                    app.navigationBars.buttons["播放"].tap()
                case "cloud":
                    app.buttons["workshop.tools"].tap(); app.buttons["云端连接设置"].tap()
                    XCTAssertTrue(app.buttons["cloud.connection.done"].waitForExistence(timeout:3)); app.buttons["cloud.connection.done"].tap()
                default:
                    let speed = app.buttons["select.播放速度"]; reveal(speed,in:app,towardTop:true); speed.tap()
                    XCTAssertTrue(app.buttons["choice.1.0"].waitForExistence(timeout:3)); app.buttons["取消"].tap()
                }
                XCTAssertTrue(stop.waitForExistence(timeout:3)); XCTAssertFalse(stop.isEnabled)
                XCTAssertEqual(stop.value as? String,"未在试听")
                XCTAssertEqual(progress.value as? String,"0.000")
            }
        }
        attach(app,"playback-preview-stopped-after-exit")
    }

    @MainActor private func deletionSummary(in app:XCUIApplication) -> XCUIElement {
        let dismissed = XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == false"),object:app.buttons["library.delete.confirm"])
        XCTAssertEqual(XCTWaiter.wait(for:[dismissed],timeout:5),.completed)
        let summary = app.staticTexts["library.delete.summary"]
        // List virtualizes offscreen rows; deleting a middle row preserves the scroll position.
        reveal(summary,in:app,towardTop:true)
        XCTAssertTrue(summary.exists)
        return summary
    }

    @MainActor private func assertDeletion(_ names:[String:String],in app:XCUIApplication) {
        let confirm = app.buttons["library.delete.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout:3))
        XCTAssertTrue(confirm.label.contains("删除 \(names.count) 项"))
        XCTAssertTrue(app.staticTexts["library.delete.count"].label.contains("永久删除 \(names.count) 项"))
        for (id,name) in names {
            let item = app.staticTexts["library.delete.item."+id]
            reveal(item,in:app); XCTAssertEqual(item.label,name)
        }
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format:"identifier BEGINSWITH %@","library.delete.item.")).count,names.count)
    }

    @MainActor private func assertCloudBackground(night:Bool,in app:XCUIApplication) {
        let scroll = app.scrollViews["cloud.connection.screen"]
        XCTAssertTrue(scroll.waitForExistence(timeout:3))
        let image = app.screenshot().image.cgImage!
        let scale = CGFloat(image.width)/app.frame.width
        let point = CGPoint(x:(scroll.frame.minX+8)*scale,y:scroll.frame.midY*scale)
        let pixelImage = image.cropping(to:CGRect(x:point.x.rounded(),y:point.y.rounded(),width:1,height:1))!
        var pixel:[UInt8] = [0,0,0,0]
        let space = CGColorSpace(name:CGColorSpace.sRGB)!
        pixel.withUnsafeMutableBytes { bytes in
            let context = CGContext(data:bytes.baseAddress,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,space:space,
                bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.draw(pixelImage,in:CGRect(x:0,y:0,width:1,height:1))
        }
        let expected = night ? [17,19,43] : [247,248,244]
        for channel in 0..<3 { XCTAssertEqual(Double(pixel[channel]),Double(expected[channel]),accuracy:12,"连接弹窗必须使用 App 主题背景") }
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
        reveal(editor,in:app,towardTop:true); editor.tap()
        app.buttons["离开输入页"].tap()
        XCTAssertTrue(app.staticTexts["输入页已离开"].exists)
        let hidden = XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == false"),object:app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for:[hidden],timeout:3),.completed)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
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

    @MainActor private func reveal(_ element:XCUIElement,in app:XCUIApplication,towardTop:Bool = false) {
        var lastFrame = CGRect.null
        for attempt in 0..<12 {
            let scroll = app.scrollViews["screen.scroll"].firstMatch
            let candidate = scroll.exists && scroll.isHittable ? scroll.frame : app.frame
            let viewport = candidate.minY.isFinite && candidate.maxY.isFinite ? candidate.intersection(app.frame) : app.frame
            var top = max(viewport.minY,app.navigationBars.firstMatch.frame.maxY)+4
            let workshop = app.segmentedControls["workshop.mode"]
            if workshop.exists { top = max(top,workshop.frame.maxY+12) }
            let largeWorkshop = app.buttons["select.工坊功能"]
            if largeWorkshop.exists { top = max(top,largeWorkshop.frame.maxY+12) }
            let tabs = app.tabBars.firstMatch
            let hasTabs = tabs.exists
            // Keep gestures inside the app, away from the home indicator and
            // floating tab background even when an AX frame extends offscreen.
            var bottom = min(viewport.maxY-4,app.frame.maxY-(hasTabs ? 110 : 40))
            // Floating tab chrome extends above its accessibility frame.
            if tabs.exists { bottom = min(bottom,tabs.frame.minY-32) }
            let generate = app.buttons["revoice.generate"]
            if (workshop.exists || largeWorkshop.exists) && generate.exists { bottom = min(bottom,generate.frame.minY-20) }
            let delete = app.buttons["library.delete.selected"]
            if delete.exists { bottom = min(bottom,delete.frame.minY-20) }
            if app.keyboards.firstMatch.exists {
                bottom = min(bottom,app.keyboards.firstMatch.frame.minY-4)
                let done = app.buttons["keyboard.done"]
                if done.exists { bottom = min(bottom,done.frame.minY-4) }
            }
            if bottom-top < 80 { top = app.navigationBars.firstMatch.frame.maxY+4 }
            let exists = element.exists
            let rect = exists ? element.frame : CGRect.null
            lastFrame = rect
            let finite = rect.midY.isFinite && rect.height > 0
            let visible = finite && rect.midY > top+12 && rect.midY < bottom-12
            // Protected/disabled controls are inspected without tapping them.
            if exists && visible && (element.isHittable || !element.isEnabled) { return }
            let center = (top+bottom)/2
            let above = finite ? rect.midY < center : (attempt < 6 ? towardTop : !towardTop)
            let lower = min(hasTabs ? 0.86 : 0.92,(bottom-24-app.frame.minY)/app.frame.height)
            let upper = max(0.12,min(lower-0.05,(top+24-app.frame.minY)/app.frame.height))
            let travel = max(0.03,lower-upper)
            let distance = finite ? min(travel*0.75,max(40/app.frame.height,abs(rect.midY-center)/app.frame.height)) : travel*0.75
            let start = app.coordinate(withNormalizedOffset:CGVector(dx:0.96,dy:above ? upper : lower))
            let end = app.coordinate(withNormalizedOffset:CGVector(dx:0.96,dy:above ? upper+distance : lower-distance))
            if app.frame.height < 750 || app.keyboards.firstMatch.exists {
                // A keyboard also makes a tall phone's viewport short. A fling can
                // overshoot the target and oscillate around the pinned controls.
                // Hold the finger at the end so the scroll settles at the requested offset.
                start.press(forDuration:0.05,thenDragTo:end,withVelocity:.slow,thenHoldForDuration:0.2)
            } else {
                start.press(forDuration:0.05,thenDragTo:end)
            }
            XCTAssertEqual(app.state,.runningForeground,"滚动手势必须留在 App 内")
        }
        XCTFail("控件未进入可点击区域，最后坐标=\(lastFrame)")
    }

    @MainActor private func attach(_ app:XCUIApplication,_ name:String) {
        let shot = XCTAttachment(screenshot:app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
