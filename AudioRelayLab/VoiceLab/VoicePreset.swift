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
    enum CodingKeys: String, CodingKey { case id,name,pitch,formant,highpass,lowmid,presence,air,compression,deesser,wet,outputGain,robot }
    func validate() throws {
        let values = [pitch,formant,highpass,lowmid,presence,air,compression,deesser,wet,outputGain,robot]
        guard values.allSatisfy(\.isFinite), (-12...12).contains(pitch), (-8...8).contains(formant),
            (20...500).contains(highpass), [lowmid,presence,air].allSatisfy({ (-12...12).contains($0) }),
            [compression,deesser,wet,robot].allSatisfy({ (0...1).contains($0) }), (0...2).contains(outputGain) else { throw LabError.invalidFormat }
    }
    static let all: [VoicePreset] = [
        .init(id:"original",name:"原声",pitch:0,formant:0,highpass:20,lowmid:0,presence:0,compression:0,deesser:0,wet:0,outputGain:1),
        .init(id:"female",name:"自然女声",pitch:7,formant:2.8,highpass:100,lowmid:-3,presence:1.2,air:0.8,compression:0.3,deesser:0.5),
        .init(id:"girl",name:"少女声",pitch:9,formant:3.5,highpass:110,lowmid:-3,presence:1.5,air:1,compression:0.3,deesser:0.5),
        .init(id:"loli",name:"萝莉音",pitch:11,formant:4,highpass:130,lowmid:-4,presence:1.5,air:0.8,compression:0.35,deesser:0.55),
        .init(id:"sweet",name:"甜美女声",pitch:7.5,formant:3,highpass:100,lowmid:-2.5,presence:1,air:1.2,compression:0.3,deesser:0.5),
        .init(id:"mature",name:"成熟女声",pitch:5,formant:2.2,highpass:85,lowmid:-2,presence:0.8,air:0.5,compression:0.35,deesser:0.45),
        .init(id:"boy",name:"正太音",pitch:3.5,formant:1.4,highpass:100,lowmid:-1,presence:1.5,air:0.5),
        .init(id:"male",name:"自然男声",pitch:-2.5,formant:-1.5,highpass:65,lowmid:1,presence:1),
        .init(id:"young",name:"青年男声",pitch:-1,formant:-0.8,highpass:75,lowmid:-1,presence:2),
        .init(id:"magnetic",name:"磁性男声",pitch:-3,formant:-1.8,highpass:55,lowmid:2,presence:0.5,compression:0.65),
        .init(id:"deep",name:"低沉男声",pitch:-4.5,formant:-2.5,highpass:50,lowmid:2.5,presence:-1,compression:0.55,deesser:0.2),
        .init(id:"clear",name:"清晰人声",pitch:0,formant:0,highpass:100,lowmid:-3,presence:3,air:1,deesser:0.6),
        .init(id:"broadcast",name:"广播人声",pitch:-0.5,formant:-0.3,highpass:70,lowmid:1.5,presence:2,compression:0.8,deesser:0.6),
        .init(id:"telephone",name:"电话音",pitch:0,formant:0,highpass:300,lowmid:-6,presence:-6,air:-12,compression:0.7,deesser:1),
        .init(id:"robot",name:"机器人",pitch:-1,formant:-0.5,highpass:120,lowmid:0,presence:1,compression:0.6,deesser:0.3,robot:0.9)
    ]
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
            wet:number(.wet,1),outputGain:number(.outputGain,0.85),robot:number(.robot,0))
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
            asset:try c.decode(AudioAsset.self,forKey:.asset),preset:(try? c.decode(VoicePreset.self,forKey:.preset)) ?? VoicePreset.all[0],
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
