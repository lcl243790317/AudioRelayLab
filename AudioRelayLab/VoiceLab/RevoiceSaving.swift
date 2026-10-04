import Foundation
import CryptoKit

enum RevoiceSaving {
    static func save(_ audio:RevoiceAudio,context:RevoiceSaveContext,jobID:String? = nil) throws -> AudioAsset {
        // Recovery after a crash between library registration and job completion.
        if let existing = try AudioFileManager.listLocalAudio().first(where:{$0.id == context.id}) {
            let stored = try Data(contentsOf:AudioFileManager.url(for:existing))
            let digest = SHA256.hash(data:stored).map { String(format:"%02x",$0) }.joined()
            guard existing.revoice?.sha256 == audio.sha256,digest == audio.sha256 else { throw LabError.invalidFormat }
            return existing
        }
        let name = AudioNaming.revoice(voiceName:context.voiceName,speaker:audio.speaker,instruction:context.instruction,
            fixedReferenceID:context.fixedReferenceID,date:context.createdAt,id:context.id)
        let destination = try AudioFileManager.audioDirectory().appendingPathComponent(name)
        do {
            try audio.data.write(to:destination,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
            var asset = try AudioFileManager.inspect(url:destination,displayName:name,id:context.id,source:.aiConverted,presetName:context.voiceName)
            try RevoiceLimits.output(asset.duration)
            guard abs(asset.duration-audio.duration) <= 1.0/24000 else { throw LabError.invalidFormat }
            asset.revoice = .init(provider:"Modal Qwen3-TTS 1.7B",generationMode:context.choice.mode,
                voiceID:context.choice.voiceID,speakerID:audio.speaker,instruction:context.instruction,
                recognizedText:context.recognizedText,synthesisText:context.text,sourceAudioID:context.sourceAudioID,
                modelVariant:context.choice.variant,modelRevision:audio.revision,sha256:audio.sha256,
                generationSeconds:audio.generationSeconds,totalSeconds:audio.totalSeconds,
                voiceName:context.voiceName,fixedReferenceID:context.fixedReferenceID,jobID:jobID)
            asset.addedAt = Date(); try AudioFileManager.register(asset)
            return asset
        } catch {
            try? FileManager.default.removeItem(at:destination)
            try? FileManager.default.removeItem(at:destination.appendingPathExtension("metadata.json"))
            throw error
        }
    }
}
