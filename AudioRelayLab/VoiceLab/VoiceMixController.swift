import Combine
import Foundation

struct VoiceMixRequest {
    let voice:AudioAsset
    let music:AudioAsset
    let settings:AudioPlaybackSettings
    let volumes:AudioMixParameters
}

@MainActor final class VoiceMixController:ObservableObject {
    @Published var voiceID:UUID?
    @Published var musicID:UUID? { didSet { if oldValue != musicID { settings = .init() } } }
    @Published var settings = AudioPlaybackSettings()
    @Published private(set) var result:AudioAsset?
    @Published private(set) var busy = false
    @Published private(set) var status = "选择人声和音乐，保存一份新的混音。"
    @Published private(set) var errorMessage:String?
    private var task:Task<Void,Never>?
    static func voices(in library:[AudioAsset]) -> [AudioAsset] {
        library.filter { [.voiceLabRecording,.aiConverted].contains($0.source) }
    }
    static func music(in library:[AudioAsset]) -> [AudioAsset] {
        library.filter { [.imported,.bundled].contains($0.source) }
    }
    func forgetAsset(_ id:UUID) {
        if voiceID == id { voiceID = nil }
        if musicID == id { musicID = nil }
        if result?.id == id { result = nil }
    }
    func request(library:[AudioAsset],volumes:AudioMixParameters) throws -> VoiceMixRequest {
        guard let voice = Self.voices(in:library).first(where:{$0.id == voiceID}),
              let music = Self.music(in:library).first(where:{$0.id == musicID}),voice.id != music.id else {
            throw LabError.message("请选择仍在库中的人声和背景音乐")
        }
        try RevoiceLimits.output(voice.duration); try volumes.validate()
        return .init(voice:voice,music:music,settings:try settings.validated(duration:music.duration),volumes:volumes)
    }
    func generate(coordinator:ExperimentCoordinator) {
        guard !busy else { return }
        do {
            let request = try request(library:coordinator.library,volumes:coordinator.mixVolumes.parameters)
            try coordinator.beginMixing(); coordinator.preview.stop()
            busy = true; errorMessage = nil; status = "保存混音中…"
            task = Task {
                defer { busy = false; task = nil; coordinator.endMixing() }
                do {
                    let voiceURL = try AudioFileManager.url(for:request.voice),musicURL = try AudioFileManager.url(for:request.music)
                    result = try await Task.detached {
                        try RecordedVoiceMixer.mix(voiceURL:voiceURL,musicURL:musicURL,settings:request.settings,
                            volumes:request.volumes,voiceAsset:request.voice,musicAsset:request.music)
                    }.value
                    coordinator.refreshLibrary(); status = "混音已保存到录音库"
                } catch { errorMessage = userFacingAudioError(error); status = "混音未保存，请检查所选音频" }
            }
        } catch { errorMessage = userFacingAudioError(error) }
    }
}
