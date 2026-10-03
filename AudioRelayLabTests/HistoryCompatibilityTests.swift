import Foundation
import XCTest
@testable import AudioRelayLab

final class HistoryCompatibilityTests: XCTestCase {
    private let firstID = "11111111-1111-4111-8111-111111111111"
    private let secondID = "22222222-2222-4222-8222-222222222222"

    // 匿名最小夹具：不复制真机日志、设备名称、路由 UID 或用户备注。
    private func record(profile: String = "A", id: String? = nil, notes: String = "人工备注示例") -> String {
        """
        {"id":"\(id ?? firstID)","date":"2026-01-01T00:00:00Z",
        "device":{"model":"Test","modelIdentifier":"TestDevice","systemVersion":"17.0","appVersion":"1.0","build":"1"},
        "audio":{"id":"33333333-3333-4333-8333-333333333333","fileName":"test.wav","sandboxFileName":"test.wav","duration":10,"sampleRate":44100,"channelCount":1,"byteCount":100},
        "settings":{"engine":"AVAudioPlayer","profile":"\(profile)","delay":5,"volume":0.04,"voiceOptimized":false,"speakerOverride":false},
        "finalState":"completed","result":"captured","resultReviewed":true,"notes":"\(notes)","logs":[]}
        """
    }

    private func decode(_ json: String) throws -> HistoryImportReport {
        try HistoryArchive.decode(Data(json.utf8))
    }

    func testAllOriginalProfilesDecodeAndDurationDefaultsToFullFile() throws {
        let profiles: [AudioSessionProfile] = [.mixingPlayback, .playback, .mixingSpeaker, .bluetooth, .ambient]
        for profile in profiles {
            let experiment = try XCTUnwrap(decode(record(profile: profile.rawValue)).experiments.first)
            XCTAssertEqual(experiment.settings.profile, profile)
            XCTAssertNil(experiment.settings.requestedDuration)
            XCTAssertEqual(experiment.schemaVersion, 2)
            XCTAssertTrue(experiment.sessionSnapshots.isEmpty)
            XCTAssertTrue(experiment.errorDetails.isEmpty)
        }
    }

    func testLegacyBIsReadableButCannotBeSelectedForNewExperiments() throws {
        let experiment = try XCTUnwrap(decode(record(profile: "B")).experiments.first)
        XCTAssertEqual(experiment.settings.profile, .playback)
        XCTAssertEqual(experiment.settings.profile.historyTitle, "B（旧版普通播放，已停用）")
        XCTAssertFalse(experiment.settings.profile.isSelectable)
        XCTAssertEqual(AudioSessionProfile.selectableCases.map(\.rawValue), ["A", "C", "D", "E"])
    }

    func testUnknownProfileAndEngineAreSafeHistoryValues() throws {
        let source = record(profile: "future-profile").replacingOccurrences(of: "AVAudioPlayer", with: "future-engine")
        let experiment = try XCTUnwrap(decode(source).experiments.first)
        XCTAssertEqual(experiment.settings.profile, .unknown)
        XCTAssertEqual(experiment.settings.engine, .unknown)
        XCTAssertFalse(experiment.settings.profile.isSelectable)
        XCTAssertFalse(experiment.migrationWarnings.isEmpty)
    }

    func testUnknownStateAndResultDoNotBreakHistory() throws {
        let source = record().replacingOccurrences(of: "completed", with: "future-state")
            .replacingOccurrences(of: "captured", with: "future-result")
        let experiment = try XCTUnwrap(decode(source).experiments.first)
        XCTAssertEqual(experiment.finalState, .failed)
        XCTAssertEqual(experiment.result, .unknown)
    }

    func testMissingFieldsRecoverWithoutInventingSelectableSettings() throws {
        let experiment = try XCTUnwrap(decode("{\"id\":\"\(firstID)\"}").experiments.first)
        XCTAssertEqual(experiment.settings.profile, .unknown)
        XCTAssertEqual(experiment.settings.engine, .unknown)
        XCTAssertFalse(experiment.resultReviewed)
        XCTAssertEqual(experiment.notes, "")
        XCTAssertFalse(experiment.migrationWarnings.isEmpty)
    }

    func testPartlyDamagedArrayKeepsRecordsAfterBadEntries() throws {
        let json = "[\(record(profile: "B")),false,\"broken\",{\"unrelated\":1},\(record(profile: "D", id: secondID))]"
        let report = try decode(json)
        XCTAssertEqual(report.experiments.count, 2)
        XCTAssertEqual(report.skippedCount, 3)
        XCTAssertEqual(report.experiments.last?.settings.profile, .bluetooth)
    }

    func testDamagedNestedLogsAreSkippedIndividually() throws {
        let source = record().replacingOccurrences(of: "\"logs\":[]", with:
            "\"logs\":[false,{\"category\":\"test\",\"message\":\"anonymous\"}]")
        let experiment = try XCTUnwrap(decode(source).experiments.first)
        XCTAssertEqual(experiment.logs.count, 1)
        XCTAssertEqual(experiment.logs.first?.message, "anonymous")
        XCTAssertTrue(experiment.migrationWarnings.contains { $0.contains("损坏日志") })
    }

    func testFractionalDatesAndVersionedArchiveDecode() throws {
        let source = record().replacingOccurrences(of: "2026-01-01T00:00:00Z", with: "2026-01-01T00:00:00.123Z")
        let report = try decode("{\"schemaVersion\":2,\"experiments\":[\(source)]}")
        let experiment = try XCTUnwrap(report.experiments.first)
        XCTAssertEqual(experiment.date.timeIntervalSince1970, 1_767_225_600.123, accuracy: 0.001)
    }

    func testMalformedDocumentFailsClearlyAndSizeIsBounded() {
        XCTAssertThrowsError(try decode("[{bad json]"))
        XCTAssertThrowsError(try HistoryArchive.decode(Data(repeating: 0, count: HistoryArchive.maximumBytes + 1)))
    }

    func testInvalidHistoricalNumbersAreMadeSafeForDisplay() throws {
        let source = record().replacingOccurrences(of: "\"delay\":5", with: "\"delay\":-2")
            .replacingOccurrences(of: "\"volume\":0.04", with: "\"volume\":2")
            .replacingOccurrences(of: "\"speakerOverride\":false", with: "\"speakerOverride\":false,\"requestedDuration\":0")
        let experiment = try XCTUnwrap(decode(source).experiments.first)
        XCTAssertEqual(experiment.settings.delay, 0)
        XCTAssertEqual(experiment.settings.volume, 1)
        XCTAssertNil(experiment.settings.requestedDuration)
    }

    func testExportImportRoundTripPreservesLegacyBNotesAndVolume() throws {
        let original = try XCTUnwrap(decode(record(profile: "B")).experiments.first)
        let url = try ExportManager.jsonFile(experiments: [original])
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try HistoryArchive.decode(Data(contentsOf: url))
        let restored = try XCTUnwrap(result.experiments.first)
        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.settings.profile, .playback)
        XCTAssertEqual(restored.notes, "人工备注示例")
        XCTAssertEqual(restored.settings.volume, 0.04, accuracy: 0.0001)
        XCTAssertEqual(restored.result, .captured)
        XCTAssertTrue(restored.resultReviewed)
    }

    func testNewDurationSnapshotsErrorsAndLogOwnershipRoundTrip() throws {
        let source = record().replacingOccurrences(of: "\"speakerOverride\":false", with:
            "\"speakerOverride\":false,\"requestedDuration\":2.5")
            .replacingOccurrences(of: "\"logs\":[]", with:
                "\"logs\":[{\"category\":\"test\",\"message\":\"anonymous\",\"experimentID\":\"\(firstID)\"}],\"sessionSnapshots\":[{\"category\":\"test\",\"sampleRate\":44100}],\"errorDetails\":[\"anonymous error\"],\"schemaVersion\":2")
        let original = try decode(source).experiments
        let restored = try XCTUnwrap(HistoryArchive.decode(HistoryArchive.encode(original)).experiments.first)
        XCTAssertEqual(restored.settings.requestedDuration, 2.5)
        XCTAssertEqual(restored.sessionSnapshots.count, 1)
        XCTAssertEqual(restored.sessionSnapshots.first?.sampleRate, 44100)
        XCTAssertEqual(restored.errorDetails, ["anonymous error"])
        XCTAssertEqual(restored.logs.first?.experimentID?.uuidString, firstID)
    }

    func testPartialErrorArrayKeepsValidTechnicalDetails() throws {
        let source = record().replacingOccurrences(of: "\"logs\":[]", with:
            "\"logs\":[],\"errorDetails\":[\"first error\",false,\"second error\"]")
        let restored = try XCTUnwrap(decode(source).experiments.first)
        XCTAssertEqual(restored.errorDetails, ["first error", "second error"])
        XCTAssertTrue(restored.migrationWarnings.contains { $0.contains("损坏技术错误") })
    }

    func testFutureSchemaVersionDoesNotPreventHistoryViewing() throws {
        let source = record().replacingOccurrences(of: "\"logs\":[]", with: "\"logs\":[],\"schemaVersion\":99")
        let restored = try XCTUnwrap(decode(source).experiments.first)
        XCTAssertEqual(restored.schemaVersion, 99)
        XCTAssertEqual(restored.settings.profile, .mixingPlayback)
    }

    func testAnonymizedTwelveRecordOldExportImportsAndReexports() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "history-v1-anonymous", withExtension: "json"))
        let report = try HistoryArchive.decode(Data(contentsOf: url))
        XCTAssertEqual(report.experiments.count, 12)
        XCTAssertEqual(report.skippedCount, 0)
        XCTAssertEqual(report.experiments.filter { $0.settings.profile == .playback }.count, 3)
        XCTAssertEqual(report.experiments.filter(\.resultReviewed).count, 8)
        XCTAssertTrue(report.experiments.allSatisfy { $0.settings.requestedDuration == nil && $0.schedule != nil })
        let restored = try HistoryArchive.decode(HistoryArchive.encode(report.experiments))
        XCTAssertEqual(restored.experiments.map(\.id), report.experiments.map(\.id))
        XCTAssertEqual(restored.experiments.map { $0.settings.profile }, report.experiments.map { $0.settings.profile })
    }

    func testCSVProtectsFormulaAndKeepsLegacyLabel() throws {
        let experiment = try XCTUnwrap(decode(record(profile: "B", notes: "=1+1")).experiments.first)
        let url = try ExportManager.csvFile(experiments: [experiment])
        defer { try? FileManager.default.removeItem(at: url) }
        let csv = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(csv.contains("\"'=1+1\""))
        XCTAssertTrue(csv.contains("B（旧版普通播放，已停用）"))
        XCTAssertTrue(csv.contains("请求播放时长秒"))
    }

    @MainActor func testImportSavesRecordsAndDoesNotOverwriteDuplicateIDs() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HistoryTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ExperimentStore(logger: DiagnosticsLogger(), directoryURL: directory)
        let summary = try store.importData(Data("[\(record(profile: "B")),null,\(record(profile: "C", id: secondID))]".utf8))
        XCTAssertEqual(summary.importedCount, 2)
        XCTAssertEqual(summary.skippedCount, 1)
        let duplicate = try store.importData(Data(record(profile: "B", notes: "不应覆盖").utf8))
        XCTAssertEqual(duplicate.importedCount, 0)
        XCTAssertEqual(duplicate.duplicateCount, 1)
        XCTAssertEqual(store.experiments.first { $0.id.uuidString == firstID }?.notes, "人工备注示例")
        let reloaded = ExperimentStore(logger: DiagnosticsLogger(), directoryURL: directory)
        XCTAssertEqual(reloaded.experiments.count, 2)
    }

    @MainActor func testCorruptLocalFileDoesNotHideOtherSavedRecords() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HistoryTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(record(profile: "B").utf8).write(to: directory.appendingPathComponent("valid.json"))
        let damaged = directory.appendingPathComponent("damaged.json")
        try Data("not-json".utf8).write(to: damaged)
        let store = ExperimentStore(logger: DiagnosticsLogger(), directoryURL: directory)
        XCTAssertEqual(store.experiments.count, 1)
        XCTAssertEqual(store.experiments.first?.settings.profile, .playback)
        XCTAssertNotNil(store.storageError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: damaged.path))
    }
}
