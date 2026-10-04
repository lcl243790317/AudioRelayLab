import Foundation

struct VoicePreset: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    var pitch: Float
    var formant: Float
    var highpass: Float = 80
    var lowmid: Float = -2
    var presence: Float = 1
    var air: Float = 0
    var compression: Float = 0.4
    var deesser: Float = 0.35
    var wet: Float = 1
    var outputGain: Float = 0.85
    var robot: Float = 0
    var inputGainDB: Float = 0
    var gateThresholdDB: Float = -65
    var gateDepth: Float = 0.6
    var compressorThresholdDB: Float = -18
    var compressorRatio: Float = 3
    var attackMS: Float = 10
    var releaseMS: Float = 120
    var presenceHz: Float = 2500
    var presenceQ: Float = 0.75
    var deesserHz: Float = 6500
    var consonantProtection: Float = 0.6
    var formantBaseHz: Float = 0
    enum CodingKeys: String, CodingKey { case id,name,pitch,formant,highpass,lowmid,presence,air,compression,deesser,wet,outputGain,robot,
        inputGainDB,gateThresholdDB,gateDepth,compressorThresholdDB,compressorRatio,attackMS,releaseMS,presenceHz,presenceQ,deesserHz,consonantProtection,formantBaseHz }
    func validate() throws {
        let values = [pitch,formant,highpass,lowmid,presence,air,compression,deesser,wet,outputGain,robot,
            inputGainDB,gateThresholdDB,gateDepth,compressorThresholdDB,compressorRatio,attackMS,releaseMS,presenceHz,presenceQ,deesserHz,consonantProtection,formantBaseHz]
        guard values.allSatisfy(\.isFinite), (-12...12).contains(pitch), (-8...8).contains(formant),
            (20...500).contains(highpass), [lowmid,presence,air].allSatisfy({ (-12...12).contains($0) }),
            [compression,deesser,wet,robot,gateDepth,consonantProtection].allSatisfy({ (0...1).contains($0) }), (0...2).contains(outputGain),
            (-18...18).contains(inputGainDB), (-80 ... -20).contains(gateThresholdDB), (-40...0).contains(compressorThresholdDB),
            (1...10).contains(compressorRatio), (1...80).contains(attackMS), (20...500).contains(releaseMS),
            (800...6000).contains(presenceHz), (0.3...3).contains(presenceQ), (3000...10000).contains(deesserHz),
            (0...400).contains(formantBaseHz) else { throw LabError.invalidFormat }
    }
    // Decoding compatibility for recordings made before removal of phone DSP.
    static let original = VoicePreset(id:"original",name:"原声",pitch:0,formant:0,highpass:20,
        lowmid:0,presence:0,compression:0,deesser:0,wet:0,outputGain:1)
}

struct VoiceLabRecord: Codable, Identifiable {
    let id: UUID
    let date: Date
    let asset: AudioAsset
    let preset: VoicePreset
    let strength: Float
    let mixed: Bool
    let voiceVolume: Float
    let musicVolume: Float
    let masterVolume: Float
    let musicSettings: AudioPlaybackSettings?
    var parameterEvents: [VoiceParameterEvent] = []
    enum CodingKeys: String, CodingKey { case id,date,asset,preset,strength,mixed,voiceVolume,musicVolume,masterVolume,musicSettings,parameterEvents }
}

extension VoicePreset {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        func number(_ key: CodingKeys, _ fallback: Float) -> Float {
            let value = (try? c.decode(Float.self,forKey:key)) ?? fallback
            return value.isFinite ? value : fallback
        }
        self.init(id:(try? c.decode(String.self,forKey:.id)) ?? "legacy",name:(try? c.decode(String.self,forKey:.name)) ?? "旧音色",
            pitch:number(.pitch,0),formant:number(.formant,0),highpass:number(.highpass,80),lowmid:number(.lowmid,0),
            presence:number(.presence,0),air:number(.air,0),compression:number(.compression,0.4),deesser:number(.deesser,0.35),
            wet:number(.wet,1),outputGain:number(.outputGain,0.85),robot:number(.robot,0),
            inputGainDB:number(.inputGainDB,0),gateThresholdDB:number(.gateThresholdDB,-65),gateDepth:number(.gateDepth,0.6),
            compressorThresholdDB:number(.compressorThresholdDB,-18),compressorRatio:number(.compressorRatio,3),
            attackMS:number(.attackMS,10),releaseMS:number(.releaseMS,120),presenceHz:number(.presenceHz,2500),presenceQ:number(.presenceQ,0.75),
            deesserHz:number(.deesserHz,6500),consonantProtection:number(.consonantProtection,0.6),formantBaseHz:number(.formantBaseHz,0))
        try validate()
    }
}

extension VoiceLabRecord {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        func volume(_ key:CodingKeys,_ fallback:Float) -> Float {
            let value = (try? c.decode(Float.self,forKey:key)) ?? fallback
            return value.isFinite ? min(1,max(0,value)) : fallback
        }
        self.init(id:(try? c.decode(UUID.self,forKey:.id)) ?? UUID(),date:(try? c.decode(Date.self,forKey:.date)) ?? .distantPast,
            asset:try c.decode(AudioAsset.self,forKey:.asset),preset:(try? c.decode(VoicePreset.self,forKey:.preset)) ?? VoicePreset.original,
            strength:volume(.strength,1),mixed:(try? c.decode(Bool.self,forKey:.mixed)) ?? false,
            voiceVolume:volume(.voiceVolume,1),musicVolume:volume(.musicVolume,0.04),masterVolume:volume(.masterVolume,0.9),
            musicSettings:try? c.decode(AudioPlaybackSettings.self,forKey:.musicSettings),
            parameterEvents:(try? c.decode([VoiceParameterEvent].self,forKey:.parameterEvents)) ?? [])
    }
}

struct VoiceParameterEvent: Codable {
    let date: Date
    let preset: VoicePreset
    let strength: Float
    let volumes: AudioMixParameters
    let musicSettings: AudioPlaybackSettings?
}
