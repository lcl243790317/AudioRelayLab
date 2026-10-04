import Combine
import Foundation

@MainActor final class MixVolumeSettings: ObservableObject {
    @Published var voice: Float = 1 { didSet { persist() } }
    @Published var music: Float = 0.04 { didSet { persist() } }
    @Published var master: Float = 0.9 { didSet { persist() } }
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey:"mix.volumes"),
           let settings = try? JSONDecoder().decode(AudioMixParameters.self,from:data),
           (try? settings.validate()) != nil {
            voice = settings.voice; music = settings.music; master = settings.master
        }
    }
    var parameters: AudioMixParameters { .init(voice:voice,music:music,master:master) }
    private func persist() {
        guard (try? parameters.validate()) != nil, let data = try? JSONEncoder().encode(parameters) else { return }
        defaults.set(data,forKey:"mix.volumes")
    }
}
