import Foundation

/// Source seconds at 1x. Never reads or writes playback/mix settings or playheads.
struct RevoiceRecognitionRange:Codable,Equatable,Sendable {
    var start:Double
    var end:Double
    var duration:Double { end-start }
    static func fullIfShort(_ duration:Double) -> Self? {
        guard duration.isFinite,(AIAudioLimits.minimumSeconds...AIAudioLimits.maximumSeconds).contains(duration) else { return nil }
        return .init(start:0,end:duration)
    }
    func validate(duration:Double) throws {
        guard duration.isFinite,duration > 0,start.isFinite,end.isFinite,start >= 0,end <= duration,end > start else {
            throw LabError.message("识别片段超出音频范围，请在配音页重新设置开始和结束位置")
        }
        // Only tolerate floating point arithmetic noise, never clip a chosen range.
        guard self.duration >= AIAudioLimits.minimumSeconds-1e-9,self.duration <= AIAudioLimits.maximumSeconds+1e-9 else {
            throw LabError.message("请在配音页选择 0.3～60 秒的识别片段")
        }
    }
}
