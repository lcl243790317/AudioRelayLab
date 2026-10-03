import AVFoundation
import Combine
import CryptoKit
import Security

struct AIVoice: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let referenceOrigin: String
}

enum AIEndpoint {
    static func validate(_ text: String) throws -> URL {
        guard let url = URL(string:text.trimmingCharacters(in:.whitespacesAndNewlines)),
            let host = url.host?.lowercased(), url.user == nil, url.password == nil,
            url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/",
            ["http","https"].contains(url.scheme?.lowercased() ?? "") else {
            throw LabError.message("请输入电脑地址，例如 http://192.168.1.8:7867")
        }
        let octets = host.split(separator:".").compactMap { Int($0) }
        let privateIP = octets.count == 4 && octets.allSatisfy { (0...255).contains($0) } &&
            (octets[0] == 10 || octets[0] == 127 || (octets[0] == 192 && octets[1] == 168) ||
             (octets[0] == 172 && (16...31).contains(octets[1])))
        guard url.scheme == "https" || privateIP || host == "localhost" || host.hasSuffix(".local") else {
            throw LabError.message("HTTP 仅用于同一局域网的电脑；远程服务请使用 HTTPS")
        }
        return url
    }
}

enum AIConnectionKey {
    private static let base: [String:Any] = [kSecClass as String:kSecClassGenericPassword,
        kSecAttrService as String:"AudioRelayLab.AI", kSecAttrAccount as String:"connection"]
    static func load() -> String {
        var query = base; query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary,&result) == errSecSuccess,
            let data = result as? Data else { return "" }
        return String(data:data,encoding:.utf8) ?? ""
    }
    static func save(_ text:String) throws {
        let attributes = [kSecValueData as String:Data(text.utf8)]
        var status = SecItemUpdate(base as CFDictionary,attributes as CFDictionary)
        if status == errSecItemNotFound {
            var query = base; query.merge(attributes) { _,new in new }
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(query as CFDictionary,nil)
        }
        guard status == errSecSuccess else { throw LabError.message("连接密钥无法保存到钥匙串") }
    }
}

enum AIRequestAudio {
    /// Decode the chosen range and use AVAudioConverter to produce speech-rate mono PCM.
    static func make(url:URL, start:Double = 0, limit:Double? = nil) throws -> URL {
        let file = try AVAudioFile(forReading:url)
        let format = file.processingFormat
        let available = Double(file.length)/format.sampleRate-start
        let seconds = limit.map { min($0,available) } ?? available
        guard start.isFinite, start >= 0, seconds.isFinite, (0.3...25).contains(seconds),
            format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else {
            throw LabError.message("请选择 0.3–25 秒的纯人声；长文件可在音频页设置起点和限制时长")
        }
        file.framePosition = try AudioPlaybackSettings.frame(start,sampleRate:format.sampleRate,length:file.length)
        let frames = AVAudioFrameCount(seconds*format.sampleRate)
        guard let decoded = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:frames),
            let monoFormat = AVAudioFormat(standardFormatWithSampleRate:format.sampleRate,channels:1),
            let mono = AVAudioPCMBuffer(pcmFormat:monoFormat,frameCapacity:frames),
            let targetFormat = AVAudioFormat(standardFormatWithSampleRate:22050,channels:1),
            let converter = AVAudioConverter(from:monoFormat,to:targetFormat),
            let output = AVAudioPCMBuffer(pcmFormat:targetFormat,frameCapacity:AVAudioFrameCount(seconds*22050)+32) else {
            throw LabError.invalidFormat
        }
        try file.read(into:decoded,frameCount:frames)
        mono.frameLength = decoded.frameLength
        guard let input = decoded.floatChannelData, let channel = mono.floatChannelData?[0] else { throw LabError.invalidFormat }
        for i in 0..<Int(decoded.frameLength) {
            var sample:Float = 0
            for c in 0..<Int(format.channelCount) { sample += input[c][i]/Float(format.channelCount) }
            guard sample.isFinite else { throw LabError.invalidFormat }
            channel[i] = min(1,max(-1,sample))
        }
        converter.primeMethod = .none
        var supplied = false, error:NSError?
        let status = converter.convert(to:output,error:&error) { _,inputStatus in
            if supplied { inputStatus.pointee = .endOfStream; return nil }
            supplied = true; inputStatus.pointee = .haveData; return mono
        }
        if let error { throw error }
        guard status != .error, output.frameLength > 0 else { throw LabError.invalidFormat }
        output.frameLength = min(output.frameLength,AVAudioFrameCount(seconds*22050))
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("ai-input-\(UUID()).wav")
        do {
            let writer = try AVAudioFile(forWriting:destination,settings:[AVFormatIDKey:kAudioFormatLinearPCM,
                AVSampleRateKey:22050,AVNumberOfChannelsKey:1,AVLinearPCMBitDepthKey:16,
                AVLinearPCMIsFloatKey:false,AVLinearPCMIsBigEndianKey:false])
            try writer.write(from:output)
            return destination
        } catch { try? FileManager.default.removeItem(at:destination); throw error }
    }
}

@MainActor final class AIConversionController: ObservableObject {
    @Published var address = UserDefaults.standard.string(forKey:"aiAddress") ?? ""
    @Published var key = AIConnectionKey.load()
    @Published private(set) var voices:[AIVoice] = []
    @Published var selectedVoice = ""
    @Published var input:AudioAsset?
    @Published private(set) var result:AudioAsset?
    @Published private(set) var busy = false
    @Published private(set) var connecting = false
    @Published private(set) var status = "连接电脑后，录制或选择一段纯人声"
    @Published private(set) var errorMessage:String?
    var onResult:((AudioAsset)->Void)?
    var beforeConvert:(()->Void)?
    private var task:Task<Void,Never>?
    private var generation = UUID()
    private var remoteID:String?
    private var activeConnection:(URL,String)?
    private let client:URLSession
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 180
        client = URLSession(configuration:config)
    }
    deinit { task?.cancel() }
    private struct VoicesResponse:Decodable { let voices:[AIVoice] }
    private struct Job:Decodable {
        let id:String; let state:String; let message:String
        let metadata:AIConversionMetadata?
    }
    private struct Failure:Decodable { let message:String }
    private func request(_ base:URL, key:String, path:String, method:String="GET", body:Data?=nil) async throws -> (Data,HTTPURLResponse) {
        var request = URLRequest(url:base.appendingPathComponent(path))
        request.httpMethod = method; request.httpBody = body
        request.setValue("Bearer \(key)",forHTTPHeaderField:"Authorization")
        if body != nil { request.setValue("audio/wav",forHTTPHeaderField:"Content-Type") }
        let (data,response) = try await client.data(for:request)
        guard let http = response as? HTTPURLResponse else { throw LabError.audioUnavailable }
        guard (200...299).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(Failure.self,from:data).message) ?? "电脑服务返回 \(http.statusCode)"
            throw LabError.message(message)
        }
        return (data,http)
    }
    func connect() {
        guard !busy, !connecting else { return }
        connecting = true; errorMessage = nil
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.connecting = false; self.task = nil }
            do {
                let base = try AIEndpoint.validate(self.address)
                guard !self.key.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw LabError.message("请复制电脑连接文件中的密钥") }
                let (data,_) = try await self.request(base,key:self.key,path:"v1/voices")
                try Task.checkCancellation()
                let voices = try JSONDecoder().decode(VoicesResponse.self,from:data).voices
                guard !voices.isEmpty else { throw LabError.message("电脑没有可用音色") }
                try AIConnectionKey.save(self.key)
                UserDefaults.standard.set(self.address,forKey:"aiAddress")
                self.voices = voices
                if !voices.contains(where:{$0.id == self.selectedVoice}) { self.selectedVoice = voices[0].id }
                self.status = "电脑已连接 · 首次生成可能需要下载模型"
            } catch { self.voices = []; self.errorMessage = userFacingAudioError(error) }
        }
    }
    func convert(start:Double=0, limit:Double?=nil) {
        guard !busy, !connecting, let input, voices.contains(where:{$0.id == selectedVoice}) else { return }
        beforeConvert?()
        let token = UUID(); generation = token; busy = true; result = nil; errorMessage = nil
        let profile = selectedVoice
        task = Task { [weak self] in
            guard let self else { return }
            var temporary:URL?
            defer {
                if let temporary { try? FileManager.default.removeItem(at:temporary) }
                if self.generation == token { self.busy = false; self.remoteID = nil; self.activeConnection = nil; self.task = nil }
            }
            do {
                let base = try AIEndpoint.validate(self.address), key = self.key
                self.activeConnection = (base,key); self.status = "正在准备与上传这段人声"
                let source = try AudioFileManager.url(for:input)
                let work = Task.detached { try AIRequestAudio.make(url:source,start:start,limit:limit) }
                temporary = try await work.value
                try Task.checkCancellation()
                var submitURL = base.appendingPathComponent("v1/jobs")
                guard var components = URLComponents(url:submitURL,resolvingAgainstBaseURL:false) else { throw LabError.invalidFormat }
                components.queryItems = [.init(name:"voice",value:profile)]
                guard let withQuery = components.url, let temporary else { throw LabError.invalidFormat }
                submitURL = withQuery
                var upload = URLRequest(url:submitURL)
                upload.httpMethod = "POST"; upload.setValue("Bearer \(key)",forHTTPHeaderField:"Authorization")
                upload.setValue("audio/wav",forHTTPHeaderField:"Content-Type")
                let (data,response) = try await self.client.upload(for:upload,fromFile:temporary)
                guard let http = response as? HTTPURLResponse, http.statusCode == 202 else {
                    throw LabError.message((try? JSONDecoder().decode(Failure.self,from:data).message) ?? "人声上传失败")
                }
                let submitted = try JSONDecoder().decode(Job.self,from:data)
                self.remoteID = submitted.id
                try Task.checkCancellation()
                for _ in 0..<1800 {
                    try Task.checkCancellation()
                    let (data,_) = try await self.request(base,key:key,path:"v1/jobs/\(submitted.id)")
                    let job = try JSONDecoder().decode(Job.self,from:data)
                    self.status = job.message
                    if job.state == "failed" || job.state == "cancelled" { throw LabError.message(job.message) }
                    if job.state == "complete" {
                        guard let metadata = job.metadata else { throw LabError.message("转换缺少来源信息") }
                        let (audio,response) = try await self.request(base,key:key,path:"v1/jobs/\(job.id)/audio")
                        let hash = SHA256.hash(data:audio).map { String(format:"%02x",$0) }.joined()
                        guard hash == metadata.sha256, hash == response.value(forHTTPHeaderField:"X-Audio-SHA256"),
                            audio.count <= 16*1024*1024 else { throw LabError.message("转换文件校验失败") }
                        try Task.checkCancellation()
                        guard self.generation == token else { return }
                        let local = try AudioFileManager.audioDirectory().appendingPathComponent("\(UUID()).wav")
                        do {
                            try audio.write(to:local,options:.atomic)
                            var asset = try AudioFileManager.inspect(url:local,displayName:"AI \(metadata.voiceName).wav",source:.aiConverted,presetName:metadata.voiceName)
                            guard asset.duration >= 0.3, asset.duration <= 40 else { throw LabError.invalidFormat }
                            asset.aiConversion = metadata
                            try AudioFileManager.register(asset)
                            self.result = asset; self.busy = false
                            self.status = "已保存 AI 声音，可以回听或应用到音频页"
                            self.onResult?(asset)
                        } catch { try? FileManager.default.removeItem(at:local); throw error }
                        return
                    }
                    try await Task.sleep(for:.seconds(1))
                }
                throw LabError.message("转换等待超过 30 分钟，请检查电脑日志")
            } catch {
                if let id = self.remoteID, let connection = self.activeConnection {
                    Task { _ = try? await self.request(connection.0,key:connection.1,path:"v1/jobs/\(id)",method:"DELETE") }
                }
                guard self.generation == token else { return }
                if !Task.isCancelled { self.errorMessage = userFacingAudioError(error); self.status = "转换未完成，可检查连接后重试" }
            }
        }
    }
    func cancel() {
        generation = UUID(); task?.cancel(); task = nil; busy = false
        let id = remoteID, connection = activeConnection
        remoteID = nil; activeConnection = nil; status = "已取消转换"
        if let id, let connection { Task { _ = try? await request(connection.0,key:connection.1,path:"v1/jobs/\(id)",method:"DELETE") } }
    }
}

struct AIConversionMetadata: Codable {
    let engine:String
    let sourceRevision:String
    let device:String
    let sampleRate:Int
    let duration:Double
    let sha256:String
    let voiceID:String
    let voiceName:String
    let referenceOrigin:String
    let conversionSeconds:Double
    let settings:[String:Double]
}
