import AVFoundation
import XCTest
@testable import AudioRelayLab

final class AudioRangeAndDurationTests: XCTestCase {
    private func fixture() throws -> URL {
        try XCTUnwrap(Bundle(for:Self.self).url(forResource:"fixture",withExtension:"wav"))
    }
    private func tone(seconds:Double) throws -> URL {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("long-\(UUID()).wav")
        let format=try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate:22050,channels:1))
        let buffer=try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:8192))
        let samples=try XCTUnwrap(buffer.floatChannelData?[0])
        let total=Int64((seconds*22050).rounded())
        do {
            let writer=try AVAudioFile(forWriting:url,settings:[AVFormatIDKey:kAudioFormatLinearPCM,
                AVSampleRateKey:22050,AVNumberOfChannelsKey:1,AVLinearPCMBitDepthKey:16,
                AVLinearPCMIsFloatKey:false,AVLinearPCMIsBigEndianKey:false])
            var written:Int64=0
            while written<total {
                buffer.frameLength=UInt32(min(8192,total-written))
                for i in 0..<Int(buffer.frameLength) { samples[i]=Float(0.2*sin(2*Double.pi*180*Double(written+Int64(i))/22050)) }
                try writer.write(from:buffer); written+=Int64(buffer.frameLength)
            }
        }
        return url
    }
    func testOldPlaybackAndExperimentSettingsKeepFullEnd() throws {
        let playback=try JSONDecoder().decode(AudioPlaybackSettings.self,
            from:Data(#"{"startOffset":1,"playbackRate":1,"volume":0.5}"#.utf8))
        XCTAssertNil(playback.endOffset); XCTAssertEqual(playback.remaining(duration:10),9)
        let old=try JSONDecoder().decode(ExperimentSettings.self,from:Data(#"{"engine":"AVAudioPlayer","profile":"B"}"#.utf8))
        XCTAssertNil(old.endOffset)
        let selected=ExperimentSettings(engine:.audioPlayer,profile:.mixingPlayback,delay:5,volume:0.5,
            voiceOptimized:false,speakerOverride:false,startOffset:1,playbackRate:2,endOffset:4)
        let decoded=try JSONDecoder().decode(ExperimentSettings.self,from:JSONEncoder().encode(selected))
        XCTAssertEqual(decoded.startOffset,1); XCTAssertEqual(decoded.endOffset,4); XCTAssertEqual(decoded.playbackRate,2)
    }
    func testInvalidEndPositionsAreRejected() {
        for end in [0.0,1,11,Double.nan,Double.infinity] {
            XCTAssertThrowsError(try AudioPlaybackSettings(startOffset:1,endOffset:end).validated(duration:10))
        }
        XCTAssertNoThrow(try AudioPlaybackSettings(startOffset:1,endOffset:10).validated(duration:10))
    }
    func testBothThumbsClampWithoutCrossingAndAllowFullRange() {
        XCTAssertEqual(AudioRangeSelection.start(9,end:4,duration:10),3.9,accuracy:0.0001)
        XCTAssertEqual(AudioRangeSelection.end(0,start:4,duration:10),4.1,accuracy:0.0001)
        XCTAssertEqual(AudioRangeSelection.start(-2,end:10,duration:10),0)
        XCTAssertEqual(AudioRangeSelection.end(20,start:0,duration:10),10)
        XCTAssertEqual(AudioRangeSelection.start(0.1,end:0.05,duration:0.05),0)
    }
    func testSelectedDurationAndRequestedLimitUseEndAtAllRates() throws {
        for rate in [Float(0.5),1,2] {
            let selected=AudioPlaybackSettings(startOffset:2,playbackRate:rate,endOffset:6)
            XCTAssertEqual(selected.estimatedDuration(duration:10),4/Double(rate))
            XCTAssertEqual(selected.estimatedDuration(duration:10,sourceLimit:1),1/Double(rate))
            XCTAssertEqual(selected.sourceLimit(duration:10,requested:8),4)
            XCTAssertEqual(try selected.selectedFrameCount(sampleRate:44100,length:441000),176400)
            XCTAssertEqual(try selected.selectedFrameCount(sampleRate:44100,length:441000,sourceLimit:1),44100)
        }
    }
    func testRealCropEndsAtChosenFrameAndKeepsOriginalSamples() throws {
        let original=try fixture()
        let copy=try AudioProcessor.rangeCopy(of:original,settings:.init(startOffset:0.3,endOffset:0.7))
        defer { try? FileManager.default.removeItem(at:copy) }
        let source=try AVAudioFile(forReading:original), segment=try AVAudioFile(forReading:copy)
        XCTAssertEqual(segment.length,17640)
        source.framePosition=13230
        let a=try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:source.processingFormat,frameCapacity:256))
        let b=try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:segment.processingFormat,frameCapacity:256))
        try source.read(into:a); try segment.read(into:b)
        let ac=try XCTUnwrap(a.floatChannelData?[0]),bc=try XCTUnwrap(b.floatChannelData?[0])
        for i in 0..<256 { XCTAssertEqual(ac[i],bc[i],accuracy:0.00001) }
    }
    @MainActor func testBothRealEnginesPrepareOnlySelectedIntervalAtEveryRate() async throws {
        let logger=DiagnosticsLogger(),session=AudioSessionManager(logger:logger)
        try session.beginManualAttempt(); try session.configure(profile:.mixingPlayback,speakerOverride:false)
        defer { session.deactivate() }
        let url=try fixture()
        for rate in [Float(0.5),1,2] {
            let a=AVAudioPlayerPlaybackEngine(logger:logger,validateEnvironment:{ try session.validateForPlayback() })
            let b=AVAudioEnginePlaybackEngine(logger:logger,validateEnvironment:{ try session.validateForPlayback() })
            defer { a.teardown(); b.teardown() }
            try await a.prepare(url:url,voiceOptimized:false,requestedDuration:nil,startOffset:0.3,playbackRate:rate,endOffset:0.7)
            try await b.prepare(url:url,voiceOptimized:false,requestedDuration:nil,startOffset:0.3,playbackRate:rate,endOffset:0.7)
            XCTAssertEqual(try XCTUnwrap(a.preparedDuration),0.4/Double(rate),accuracy:1/44100.0)
            XCTAssertEqual(try XCTUnwrap(b.preparedDuration),0.4/Double(rate),accuracy:1/44100.0)
            let schedule=try a.schedule(delay:0.5,requestedTime:Date())
            XCTAssertEqual(schedule.endOffset,0.7)
            let restored=try JSONDecoder().decode(PlaybackSchedule.self,from:JSONEncoder().encode(schedule))
            XCTAssertEqual(restored.endOffset,0.7)
        }
    }
    @MainActor func testPreviewNaturallyEndsAtSelectedSourceEnd() async throws {
        let logger=DiagnosticsLogger(),session=AudioSessionManager(logger:logger)
        let preview=PreviewPlaybackController(session:session,logger:logger)
        defer { preview.stop() }
        let asset=try AudioFileManager.importFile(from:fixture())
        defer { try? AudioFileManager.removeAudio(asset) }
        preview.play(asset:asset,settings:.init(startOffset:0.3,playbackRate:2,volume:0,endOffset:0.7),fiveSeconds:false)
        for _ in 0..<100 where preview.state == .preparing { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertEqual(preview.state,.playing,preview.errorMessage ?? "")
        XCTAssertEqual(try XCTUnwrap(preview.preparedDuration),0.4,accuracy:1/44100.0)
        for _ in 0..<100 where preview.isActive { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertEqual(preview.state,.idle,preview.errorMessage ?? "")
        XCTAssertEqual(preview.currentTime,0.7,accuracy:1/44100.0)
    }
    func testPhoneUploadEncodesSixtySecondsAndRejectsOverLimit() throws {
        let source=try tone(seconds:60.1)
        defer { try? FileManager.default.removeItem(at:source) }
        for seconds in [31.0,60] {
            let upload=try AIRequestAudio.make(url:source,limit:seconds)
            defer { try? FileManager.default.removeItem(at:upload) }
            let file=try AVAudioFile(forReading:upload)
            XCTAssertEqual(file.processingFormat.sampleRate,22050)
            XCTAssertEqual(Double(file.length)/22050,seconds,accuracy:1/22050.0)
        }
        XCTAssertThrowsError(try AIRequestAudio.make(url:source))
    }
    func testSixtySecondAIVoiceMixContinuesAfterSelectedMusicEnds() throws {
        let source=try tone(seconds:60)
        defer { try? FileManager.default.removeItem(at:source) }
        let asset=try RecordedVoiceMixer.mix(voiceURL:source,musicURL:fixture(),
            settings:.init(startOffset:0.3,playbackRate:2,endOffset:0.7),volumes:.init(voice:1,music:0.04,master:0.9))
        defer { try? AudioFileManager.removeAudio(asset) }
        XCTAssertEqual(asset.duration,60,accuracy:1/48000.0)
        let file=try AVAudioFile(forReading:AudioFileManager.url(for:asset))
        file.framePosition=59*48000
        let buffer=try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:1024))
        try file.read(into:buffer)
        let samples=try XCTUnwrap(buffer.floatChannelData?[0])
        XCTAssertGreaterThan((0..<Int(buffer.frameLength)).map { abs(samples[$0]) }.max() ?? 0,0.01)
    }
    func testRecordingWriterTruncatesLastBlockExactlyAndSavesWithoutFailure() throws {
        let context=try VoiceDSPContext(sampleRate:44100)
        let writer=try VoiceRecordingWriter(context:context,sampleRate:44100,maximumSeconds:0.02,automaticallyFinishAtLimit:true)
        let format=try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate:44100,channels:1))
        let buffer=try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:1024))
        buffer.frameLength=1024
        let samples=try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0..<1024 { samples[i]=0.2 }
        context.enqueueRecording(buffer)
        let url=try writer.finish()
        defer { try? FileManager.default.removeItem(at:url) }
        XCTAssertTrue(writer.hasReachedLimit); XCTAssertNil(writer.currentFailure())
        XCTAssertEqual(try AVAudioFile(forReading:url).length,882)
    }
    @MainActor func testRealRawRecordingAutomaticallySavesExactlySixtySeconds() async throws {
        let coordinator=ExperimentCoordinator(),voice=coordinator.voiceLab
        defer { voice.stop(saveRecording:false) }
        voice.start(.rawRecording)
        for _ in 0..<100 where voice.state == .preparing { try await Task.sleep(for:.milliseconds(50)) }
        XCTAssertEqual(voice.state,.running,voice.errorMessage ?? voice.status)
        guard voice.state == .running else { return }
        for _ in 0..<700 where voice.isActive { try await Task.sleep(for:.milliseconds(100)) }
        XCTAssertEqual(voice.state,.idle,voice.errorMessage ?? voice.status)
        let record=try XCTUnwrap(voice.recordings.first)
        defer { coordinator.deleteAudio(record.asset) }
        XCTAssertEqual(record.preset.id,VoicePreset.all[0].id)
        XCTAssertTrue(record.asset.fileName.hasPrefix("原声_"))
        XCTAssertEqual(record.asset.duration,60,accuracy:1/record.asset.sampleRate)
        let upload=try AIRequestAudio.make(url:AudioFileManager.url(for:record.asset))
        defer { try? FileManager.default.removeItem(at:upload) }
        XCTAssertEqual(try AVAudioFile(forReading:upload).length,1_323_000)
    }
}
