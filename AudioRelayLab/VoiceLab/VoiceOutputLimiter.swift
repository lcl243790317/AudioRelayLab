import AVFAudio
import AudioToolbox

enum VoiceOutputLimiter {
    static func make() throws -> AVAudioUnitEffect {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_DynamicsProcessor, componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard AudioComponentFindNext(nil, &description) != nil else { throw LabError.message("当前系统没有可用的输出动态处理器") }
        let effect = AVAudioUnitEffect(audioComponentDescription: description)
        let parameters: [(AudioUnitParameterID, Float)] = [
            (kDynamicsProcessorParam_Threshold,-3), (kDynamicsProcessorParam_HeadRoom,0.1),
            (kDynamicsProcessorParam_AttackTime,0.001), (kDynamicsProcessorParam_ReleaseTime,0.05),
            (kDynamicsProcessorParam_ExpansionRatio,1)
        ]
        for (parameter, value) in parameters {
            let status = AudioUnitSetParameter(effect.audioUnit, parameter, kAudioUnitScope_Global, 0, value, 0)
            guard status == noErr else { throw NSError(domain:NSOSStatusErrorDomain,code:Int(status)) }
        }
        return effect
    }
}
