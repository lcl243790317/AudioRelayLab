import AVFAudio

enum RecordedVoiceMixer {
    static func mix(voiceURL:URL, musicURL:URL, settings:AudioPlaybackSettings, volumes:AudioMixParameters,voiceAsset:AudioAsset? = nil,musicAsset:AudioAsset? = nil) throws -> AudioAsset {
        try volumes.validate()
        let voiceFile = try AVAudioFile(forReading:voiceURL)
        let seconds = Double(voiceFile.length)/voiceFile.processingFormat.sampleRate
        try RevoiceLimits.output(seconds)
        let musicCopy = try RateAdjustedAudio.copy(of:musicURL,startOffset:settings.startOffset,
            rate:settings.playbackRate,duration:seconds*Double(settings.playbackRate),endOffset:settings.endOffset)
        defer { try? FileManager.default.removeItem(at:musicCopy) }
        let musicFile = try AVAudioFile(forReading:musicCopy)
        let engine = AVAudioEngine(), voice = AVAudioPlayerNode(), music = AVAudioPlayerNode()
        guard let format = AVAudioFormat(standardFormatWithSampleRate:48000,channels:1),
            let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:4096) else { throw LabError.invalidFormat }
        engine.attach(voice); engine.attach(music)
        engine.connect(voice,to:engine.mainMixerNode,format:voiceFile.processingFormat)
        engine.connect(music,to:engine.mainMixerNode,format:musicFile.processingFormat)
        voice.volume = volumes.voice; music.volume = volumes.music
        engine.mainMixerNode.outputVolume = volumes.master
        try engine.enableManualRenderingMode(.offline,format:format,maximumFrameCount:4096)
        defer { voice.stop(); music.stop(); engine.stop(); engine.disableManualRenderingMode() }
        voice.scheduleFile(voiceFile,at:nil); music.scheduleFile(musicFile,at:nil)
        try engine.start(); voice.play(); music.play()
        let id = UUID()
        let revoice = voiceAsset?.revoice
        let name = revoice.map {
            AudioNaming.revoice(kind:"混音",voiceName:$0.voiceName ?? $0.voiceID,speaker:$0.speakerID,
                                instruction:$0.instruction,fixedReferenceID:$0.fixedReferenceID,id:id)
        } ?? AudioNaming.generated(kind:"混音",label:voiceAsset?.aiConversion?.voiceName ?? "人声与音乐",fileExtension:"wav",id:id)
        let destination = try AudioFileManager.audioDirectory().appendingPathComponent(name)
        do {
          // Close/finalize the WAV header before opening it for inspection.
          do {
            let writer = try AVAudioFile(forWriting:destination,settings:[AVFormatIDKey:kAudioFormatLinearPCM,
                AVSampleRateKey:48000,AVNumberOfChannelsKey:1,AVLinearPCMBitDepthKey:16,
                AVLinearPCMIsFloatKey:false,AVLinearPCMIsBigEndianKey:false])
            let frames = Int64(ceil(seconds*48000))
            var written:Int64 = 0, stalls = 0
            while written < frames {
                try Task.checkCancellation()
                let status = try engine.renderOffline(AVAudioFrameCount(min(4096,frames-written)),to:buffer)
                if status == .success {
                    guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else { throw LabError.invalidFormat }
                    for i in 0..<Int(buffer.frameLength) {
                        guard channel[i].isFinite else { throw LabError.invalidFormat }
                        channel[i] = min(0.98,max(-0.98,channel[i]))
                    }
                    try writer.write(from:buffer); written += Int64(buffer.frameLength); stalls = 0
                } else {
                    stalls += 1
                    guard status != .error, stalls <= 100 else { throw LabError.message("混音渲染无法继续") }
                }
            }
          }
            var asset = try AudioFileManager.inspect(url:destination,displayName:name,id:id,source:.mixedRecording)
            if let voiceAsset, let musicAsset {
                asset.mixSource = .init(voiceAssetID:voiceAsset.id,musicAssetID:musicAsset.id,
                    revoice:voiceAsset.revoice,settings:settings,volumes:volumes)
            }
            asset.addedAt = Date()
            try AudioFileManager.register(asset)
            return asset
        } catch { try? FileManager.default.removeItem(at:destination); throw error }
    }
}
