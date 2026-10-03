import AVFAudio
import UIKit
import XCTest
@testable import AudioRelayLab

final class DeviceBugRegressionTests: XCTestCase {
    func testRepeatedTestSelectionReusesIDFileAndModificationDate() throws {
        let first = try AudioFileManager.loadBundledAudio()
        let url = try AudioFileManager.url(for:first)
        let date = try FileManager.default.attributesOfItem(atPath:url.path)[.modificationDate] as? Date
        let before = try Data(contentsOf:url)
        for _ in 0..<5 {
            let next = try AudioFileManager.loadBundledAudio()
            XCTAssertEqual(next.id,first.id); XCTAssertEqual(try AudioFileManager.url(for:next),url)
        }
        XCTAssertEqual(try Data(contentsOf:url),before)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath:url.path)[.modificationDate] as? Date,date)
        XCTAssertEqual(try AudioFileManager.listLocalAudio().filter { $0.source == .bundled }.count,1)
    }
    func testOldBundleCopiesAreMigratedWithoutBreakingHistoryOrImportedAudio() throws {
        let fixture = try XCTUnwrap(Bundle(for:Self.self).url(forResource:"fixture",withExtension:"wav"))
        let imported = try AudioFileManager.importFile(from:fixture)
        defer { try? AudioFileManager.removeAudio(imported) }
        var old = try AudioFileManager.importFile(from:fixture)
        let oldURL = try AudioFileManager.url(for:old)
        old.source = .bundled
        try JSONEncoder().encode(old).write(to:oldURL.appendingPathExtension("metadata.json"),options:.atomic)
        let canonical = try AudioFileManager.loadBundledAudio()
        XCTAssertFalse(FileManager.default.fileExists(atPath:oldURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:oldURL.appendingPathExtension("metadata.json").path))
        XCTAssertEqual(try AudioFileManager.url(for:old),try AudioFileManager.url(for:canonical))
        XCTAssertTrue(FileManager.default.fileExists(atPath:try AudioFileManager.url(for:imported).path))
        XCTAssertEqual(try AudioFileManager.listLocalAudio().filter { $0.source == .bundled }.count,1)
    }
    @MainActor func testNativePickerDelegateDeliversActualImportOnlyOnce() async throws {
        let coordinator = ExperimentCoordinator()
        let input = try XCTUnwrap(Bundle(for:Self.self).url(forResource:"fixture",withExtension:"mp3"))
        var calls=0
        let delegate = AudioDocumentPicker.Delegate(onSelection:{ url in calls+=1; coordinator.importAudio(url) },onCancel:{ XCTFail("unexpected cancellation") })
        let picker = AudioDocumentPicker.makePicker(delegate:delegate)
        XCTAssertFalse(picker.allowsMultipleSelection); XCTAssertTrue(picker.shouldShowFileExtensions)
        delegate.documentPicker(picker,didPickDocumentsAt:[input])
        delegate.documentPicker(picker,didPickDocumentsAt:[input])
        for _ in 0..<100 where coordinator.isImporting { try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertEqual(calls,1); XCTAssertFalse(coordinator.isImporting)
        let asset = try XCTUnwrap(coordinator.audio)
        XCTAssertEqual(asset.source,.imported); XCTAssertGreaterThan(asset.duration,1)
        XCTAssertEqual(try Data(contentsOf:AudioFileManager.url(for:asset)),try Data(contentsOf:input))
        coordinator.useTestAudio(); try AudioFileManager.removeAudio(asset)
    }
    @MainActor func testPickerCancelDoesNotImportOrChangeCurrentAudio() {
        let coordinator=ExperimentCoordinator(), initial=coordinator.audio?.id
        var cancelled=0
        let delegate=AudioDocumentPicker.Delegate(onSelection:{ _ in XCTFail("cancel must not import") },onCancel:{ cancelled+=1 })
        let picker=AudioDocumentPicker.makePicker(delegate:delegate)
        delegate.documentPickerWasCancelled(picker); delegate.documentPickerWasCancelled(picker)
        XCTAssertEqual(cancelled,1); XCTAssertEqual(coordinator.audio?.id,initial); XCTAssertFalse(coordinator.isImporting)
    }
    func testActualSpeedRenderedPCMHasExpectedLengthAndAudibleData() throws {
        let original=try AudioFileManager.url(for:AudioFileManager.loadBundledAudio())
        for rate in [Float(0.5),1,2] {
            let url=try RateAdjustedAudio.copy(of:original,startOffset:0.3,rate:rate,duration:0.6)
            defer { try? FileManager.default.removeItem(at:url) }
            let file=try AVAudioFile(forReading:url)
            XCTAssertEqual(Double(file.length)/file.processingFormat.sampleRate,0.6/Double(rate),accuracy:1/44100.0)
            let buffer=try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:UInt32(file.length)))
            try file.read(into:buffer)
            let samples=try XCTUnwrap(buffer.floatChannelData?[0])
            let energy=(0..<Int(buffer.frameLength)).reduce(0.0) { $0+Double(samples[$1]*samples[$1]) }
            XCTAssertGreaterThan(energy/Double(buffer.frameLength),0.001)
        }
    }
    @MainActor func testTwoTimesSpeedUsesOneTimesFutureDeviceClock() async throws {
        let logger=DiagnosticsLogger(), session=AudioSessionManager(logger:logger)
        try session.beginManualAttempt(); try session.configure(profile:.mixingPlayback,speakerOverride:false)
        let player=AVAudioPlayerPlaybackEngine(logger:logger,validateEnvironment:{ try session.validateForPlayback() })
        defer { player.teardown(); session.deactivate() }
        player.volume=0
        try await player.prepare(url:AudioFileManager.url(for:AudioFileManager.loadBundledAudio()),voiceOptimized:false,requestedDuration:nil,startOffset:0.3,playbackRate:2)
        XCTAssertEqual(player.nativeRate,1)
        let before=ProcessInfo.processInfo.systemUptime
        let schedule=try player.schedule(delay:0.8,requestedTime:Date())
        XCTAssertEqual(schedule.requestedDelay,0.8); XCTAssertEqual(schedule.playbackRate,2)
        XCTAssertGreaterThanOrEqual(schedule.targetUptime-before,0.79)
        try await Task.sleep(for:.milliseconds(350))
        XCTAssertLessThan(try XCTUnwrap(player.nativePlaybackTime),0.02)
        try await Task.sleep(for:.milliseconds(700))
        XCTAssertGreaterThan(try XCTUnwrap(player.nativePlaybackTime),0.03)
    }
    private func route(rate:Double=48000,input:Int=1,output:Int=2,port:String="speaker") -> VoiceHardwareRoute {
        .init(sampleRate:rate,inputChannels:input,outputChannels:output,inputPorts:["mic"],outputPorts:[port])
    }
    @MainActor func testEngineTwoTimesSpeedKeepsHostTimeGateIndependent() async throws {
        let logger=DiagnosticsLogger(), session=AudioSessionManager(logger:logger)
        try session.beginManualAttempt(); try session.configure(profile:.mixingPlayback,speakerOverride:false)
        let player=AVAudioEnginePlaybackEngine(logger:logger,validateEnvironment:{ try session.validateForPlayback() })
        defer { player.teardown(); session.deactivate() }
        player.volume=0
        try await player.prepare(url:AudioFileManager.url(for:AudioFileManager.loadBundledAudio()),voiceOptimized:false,requestedDuration:nil,startOffset:0.3,playbackRate:2)
        XCTAssertEqual(player.nativeRate,1)
        let schedule=try player.schedule(delay:0.8,requestedTime:Date())
        XCTAssertEqual(schedule.requestedDelay,0.8); XCTAssertEqual(schedule.playbackRate,2)
        try await Task.sleep(for:.milliseconds(350))
        XCTAssertLessThan(player.nativePlaybackTime ?? 0,0.02)
        try await Task.sleep(for:.milliseconds(700))
        XCTAssertGreaterThan(try XCTUnwrap(player.nativePlaybackTime),0.03)
    }
    func testUnchangedRouteNotificationsKeepRunningAndOnlyRestartStoppedGraphOnce() {
        let baseline=route()
        XCTAssertEqual(baseline.action(comparedTo:route(),engineRunning:true,alreadyRestarted:false),.keepRunning)
        XCTAssertEqual(baseline.action(comparedTo:route(),engineRunning:false,alreadyRestarted:false),.restartSameFormat)
        XCTAssertEqual(baseline.action(comparedTo:route(),engineRunning:false,alreadyRestarted:true),.stop)
    }
    func testRealDeviceFormatAndUnavailableRoutesStillStopSafely() {
        for changed in [route(rate:44100),route(input:2),route(port:"headphones"),route(rate:0),route(input:0)] {
            XCTAssertEqual(route().action(comparedTo:changed,engineRunning:true,alreadyRestarted:false),.stop)
        }
    }
    @MainActor private func awaitRunning(_ voice:VoiceProcessingEngine) async throws {
        for _ in 0..<80 where voice.state == .preparing { try await Task.sleep(for:.milliseconds(50)) }
        XCTAssertEqual(voice.state,.running,voice.errorMessage ?? voice.status)
    }
    @MainActor func testRealSimulatorMicGraphIgnoresOwnCategoryNotificationAndWritesCAF() async throws {
        let coordinator=ExperimentCoordinator(), voice=coordinator.voiceLab
        defer { voice.stop(saveRecording:false) }
        voice.start(.voiceRecording); try await awaitRunning(voice)
        guard voice.state == .running else { return }
        NotificationCenter.default.post(name:AVAudioSession.routeChangeNotification,object:AVAudioSession.sharedInstance(),
            userInfo:[AVAudioSessionRouteChangeReasonKey:AVAudioSession.RouteChangeReason.categoryChange.rawValue])
        try await Task.sleep(for:.milliseconds(700))
        XCTAssertEqual(voice.state,.running,voice.errorMessage ?? voice.status)
        voice.stop()
        XCTAssertEqual(voice.state,.idle,voice.errorMessage ?? voice.status)
        let record=try XCTUnwrap(voice.recordings.first)
        XCTAssertEqual(record.asset.source,.voiceLabRecording); XCTAssertGreaterThan(record.asset.duration,0.2)
        voice.delete(record)
    }
    @MainActor func testRealSimulatorMixerCapturesMusicThroughProductionGraph() async throws {
        let coordinator=ExperimentCoordinator(), voice=coordinator.voiceLab
        defer { voice.stop(saveRecording:false) }
        voice.voiceVolume=0; voice.musicVolume=0.4
        voice.start(.mixedRecording,music:coordinator.audio,settings:.init(startOffset:0.3,playbackRate:2,volume:0.4))
        try await awaitRunning(voice)
        guard voice.state == .running else { return }
        try await Task.sleep(for:.milliseconds(700))
        XCTAssertEqual(voice.state,.running,voice.errorMessage ?? voice.status)
        XCTAssertGreaterThan(voice.musicPosition,0.3)
        voice.stop(); XCTAssertEqual(voice.state,.idle,voice.errorMessage ?? voice.status)
        let record=try XCTUnwrap(voice.recordings.first)
        let file=try AVAudioFile(forReading:AudioFileManager.url(for:record.asset))
        let buffer=try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:UInt32(file.length)))
        try file.read(into:buffer)
        let samples=try XCTUnwrap(buffer.floatChannelData?[0])
        let peak=(0..<Int(buffer.frameLength)).reduce(Float(0)) { max($0,abs(samples[$1])) }
        XCTAssertGreaterThan(peak,0.005); XCTAssertEqual(record.asset.source,.mixedRecording)
        voice.delete(record)
    }
}
