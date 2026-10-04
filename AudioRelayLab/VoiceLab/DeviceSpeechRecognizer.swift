import Foundation
import Speech

@MainActor protocol RevoiceTranscribing: AnyObject {
    func transcribe(url:URL) async throws -> String
    func cancel()
}

@MainActor final class DeviceSpeechRecognizer: RevoiceTranscribing {
    private var speechTask:SFSpeechRecognitionTask?
    private var continuation:CheckedContinuation<String,Error>?
    private var timeout:Task<Void,Never>?
    private var generation = UUID()
    static func requireDeviceRecognition(authorized:Bool, available:Bool, supported:Bool) throws {
        guard authorized else { throw LabError.message("语音识别权限未开启，请在系统设置中允许，或手动输入文字") }
        guard supported else { throw LabError.message("此设备暂不支持设备端普通话识别，请手动输入文字") }
        guard available else { throw LabError.message("设备端语音识别暂不可用，请稍后重试或手动输入文字") }
    }
    func transcribe(url:URL) async throws -> String {
        cancel()
        let token = UUID(); generation = token
        let authorization = await withCheckedContinuation { (continuation:CheckedContinuation<SFSpeechRecognizerAuthorizationStatus,Never>) in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning:$0) }
        }
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        guard let recognizer = SFSpeechRecognizer(locale:Locale(identifier:"zh-CN")) else {
            throw LabError.message("此设备暂不支持普通话识别，请手动输入文字")
        }
        try Self.requireDeviceRecognition(authorized:authorization == .authorized, available:recognizer.isAvailable,
                                          supported:recognizer.supportsOnDeviceRecognition)
        let request = SFSpeechURLRecognitionRequest(url:url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<String,Error>) in
                self.continuation = continuation
                speechTask = recognizer.recognitionTask(with:request) { [weak self] result,error in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == token else { return }
                        if let result, result.isFinal {
                            self.finish(.success(result.bestTranscription.formattedString))
                        } else if error != nil {
                            self.finish(.failure(LabError.message("设备端识别未完成，原录音已保留，请重试或手动输入文字")))
                        }
                    }
                }
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for:.seconds(90)) } catch { return }
                    guard let self, self.generation == token else { return }
                    self.finish(.failure(LabError.message("设备端识别超时，原录音已保留，请重试或手动输入文字")))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in if self?.generation == token { self?.cancel() } }
        }
    }
    private func finish(_ result:Result<String,Error>) {
        let pending = continuation; continuation = nil
        generation = UUID(); timeout?.cancel(); timeout = nil
        speechTask?.cancel(); speechTask = nil
        pending?.resume(with:result)
    }
    func cancel() { finish(.failure(CancellationError())) }
}
