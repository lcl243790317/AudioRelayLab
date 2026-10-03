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
        guard status == errSecSuccess else {
            throw NSError(domain:NSOSStatusErrorDomain,code:Int(status),
                userInfo:[NSLocalizedDescriptionKey:"连接密钥无法保存到钥匙串"])
        }
    }
}

enum AIConnectionError {
    static func message(_ error: Error) -> String {
        if let error = error as? LabError { return error.errorDescription ?? "AI 操作未完成" }
        let value = error as NSError
        if value.domain == NSURLErrorDomain {
            switch URLError.Code(rawValue:value.code) {
            case .cannotConnectToHost: return "电脑 AI 服务未启动或端口不可达。请在电脑运行 server/run.ps1，确认同一 Wi-Fi 和防火墙后重新连接。"
            case .cannotFindHost, .dnsLookupFailed: return "找不到电脑地址。请重新复制 CONNECTION-ZH.txt 中的当前局域网地址。"
            case .notConnectedToInternet, .networkConnectionLost: return "手机与电脑的连接已断开。请确认同一 Wi-Fi、电脑保持唤醒，然后直接重试连接。"
            case .timedOut: return "电脑服务响应超时。请检查电脑是否休眠或正在下载模型，再重试。"
            case .appTransportSecurityRequiresSecureConnection: return "此地址被系统网络策略拒绝。局域网请使用电脑连接文件中的地址，远程服务需使用 HTTPS。"
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot:
                return "无法验证电脑的 HTTPS 连接。请检查服务证书或使用同一局域网的连接地址。"
            case .cancelled: return "已取消 AI 操作"
            default: return "AI 网络请求失败（\(value.code)）。请检查电脑服务与手机的局域网权限后重试；详情已写入诊断。"
            }
        }
        if error is DecodingError { return "电脑服务返回的数据格式不兼容。请更新电脑服务后重新连接。" }
        return "AI 操作未完成；技术详情已写入诊断。请重新选择原声或连接电脑后重试。"
    }
}

enum AIRequestAudio {
    /// Decode the chosen range and use AVAudioConverter to produce speech-rate mono PCM.
    static func make(url:URL, start:Double = 0, limit:Double? = nil) throws -> URL {
        let file = try AVAudioFile(forReading:url)
        let format = file.processingFormat
        let available = Double(file.length)/format.sampleRate-start
        let seconds = limit.map { min($0,available) } ?? available
        if let limit { guard limit.isFinite, limit >= AIAudioLimits.minimumSeconds else { throw LabError.invalidFormat } }
        guard start.isFinite, start >= 0, seconds.isFinite, (AIAudioLimits.minimumSeconds...AIAudioLimits.maximumSeconds).contains(seconds),
            format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else {
            throw LabError.message("请选择 0.3–60 秒的纯人声；长文件可在音频页设置起止区间")
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
    @Published var mode = AIConversionMode.naturalSpeech
    @Published private(set) var availableModes: [AIConversionMode] = [.preserveProsody]
    @Published var customSettings = false
    @Published var diffusionSteps: Double = 40
    @Published var clarity: Double = 0.9
    @Published var similarity: Double = 0.65
    @Published var pitchShift: Double = 0
    @Published var input:AudioAsset?
    @Published private(set) var result:AudioAsset?
    @Published private(set) var busy = false
    @Published private(set) var connecting = false
    @Published private(set) var status = "连接电脑后，录制或选择一段纯人声"
    @Published private(set) var errorMessage:String?
    @Published private(set) var connectionWarning:String?
    var onResult:((AudioAsset)->Void)?
    var beforeConvert:(()->Void)?
    private var task:Task<Void,Never>?
    private var generation = UUID()
    private var remoteID:String?
    private var activeConnection:(URL,String)?
    private let client:URLSession
    private let logger:DiagnosticsLogger?
    private let saveKey:(String) throws -> Void
    init(logger:DiagnosticsLogger? = nil, session:URLSession? = nil,
         saveKey:@escaping (String) throws -> Void = AIConnectionKey.save) {
        self.logger = logger
        self.saveKey = saveKey
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 180
        client = session ?? URLSession(configuration:config)
    }
    deinit { task?.cancel() }
    func selectInput(_ asset:AudioAsset?) {
        guard !busy, !connecting else { return }
        input = asset; result = nil; errorMessage = nil
        status = asset == nil ? "正在准备录制新原声" : "原声已就绪，可以生成 AI 声音"
    }
    func forgetAsset(_ id: UUID) {
        guard !busy else { return }
        if input?.id == id { input = nil }
        if result?.id == id { result = nil }
    }
    private struct VoicesResponse:Decodable { let voices:[AIVoice] }
    private struct Health:Decodable { let engine:String; let modelState:String; let protocolVersion:Int?; let conversionModes:[String]? }
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
        if path == "v1/health" || path == "v1/voices" { request.timeoutInterval = 12 }
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
        let token = UUID(); generation = token
        connecting = true; errorMessage = nil; connectionWarning = nil; status = "正在检查电脑连接"
        logger?.log("AI 连接", "用户连接电脑；不记录地址、密钥或录音内容。")
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.connecting = false; self.task = nil } }
            do {
                let base = try AIEndpoint.validate(self.address)
                let key = self.key.trimmingCharacters(in:.whitespacesAndNewlines)
                guard !key.isEmpty else { throw LabError.message("请复制电脑连接文件中的密钥") }
                let (healthData,_) = try await self.request(base,key:key,path:"v1/health")
                let health = try JSONDecoder().decode(Health.self,from:healthData)
                guard (health.protocolVersion ?? 1) >= 2 else { throw LabError.message("电脑服务需要更新。请在电脑重新运行 server/run.ps1 后再连接，启用保留原话与语调的转换。") }
                let (data,_) = try await self.request(base,key:key,path:"v1/voices")
                try Task.checkCancellation()
                guard self.generation == token else { return }
                let voices = try JSONDecoder().decode(VoicesResponse.self,from:data).voices
                guard !voices.isEmpty else { throw LabError.message("电脑没有可用音色") }
                do { try self.saveKey(key) }
                catch {
                    self.connectionWarning = "电脑已连接。密钥无法保留，重新打开 App 后需再输入。"
                    self.logger?.log("AI 密钥保存失败", diagnosticError(error))
                }
                UserDefaults.standard.set(self.address,forKey:"aiAddress")
                self.voices = voices
                self.availableModes = health.conversionModes?.compactMap(AIConversionMode.init(rawValue:)) ?? [.preserveProsody]
                guard !self.availableModes.isEmpty else { throw LabError.message("电脑服务没有兼容的转换方式，请更新电脑服务") }
                if !self.availableModes.contains(self.mode) { self.mode = self.availableModes[0] }
                if !voices.contains(where:{$0.id == self.selectedVoice}) { self.selectedVoice = voices[0].id }
                self.status = "电脑已连接 · 首次生成可能需要下载模型"
                self.logger?.log("AI 已连接", "引擎=\(health.engine)，模型状态=\(health.modelState)，音色数=\(voices.count)，协议=\(health.protocolVersion ?? 1)")
            } catch {
                guard self.generation == token else { return }
                self.voices = []; self.errorMessage = AIConnectionError.message(error)
                self.status = "连接未完成，可以直接重试"
                self.logger?.log("AI 连接失败", diagnosticError(error))
            }
        }
    }
    func convert(start:Double=0, limit:Double?=nil) {
        guard !busy, !connecting, let input, voices.contains(where:{$0.id == selectedVoice}), availableModes.contains(mode) else { return }
        beforeConvert?()
        let token = UUID(); generation = token; busy = true; result = nil; errorMessage = nil
        logger?.log("AI 准备", "来源=\(input.source.rawValue)，时长=\(input.duration)，起点=\(start)，限制=\(limit.map { String($0) } ?? "完整")")
        let profile = selectedVoice
        let conversionMode = mode
        var options: [URLQueryItem] = [.init(name:"voice",value:profile),.init(name:"mode",value:conversionMode.rawValue)]
        if customSettings {
            guard diffusionSteps.isFinite, (20...80).contains(diffusionSteps), clarity.isFinite, (0...1).contains(clarity),
                similarity.isFinite, (0...1).contains(similarity), pitchShift.isFinite, (-6...6).contains(pitchShift) else {
                busy = false; errorMessage = "AI 微调参数超出范围"; return
            }
            options.append(.init(name:"steps",value:String(Int(diffusionSteps))))
            if conversionMode.isV2 {
                options.append(.init(name:"intelligibility",value:String(clarity)))
                options.append(.init(name:"similarity",value:String(similarity)))
            }
            if conversionMode == .preserveProsody { options.append(.init(name:"pitchShift",value:String(pitchShift))) }
        }
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
                components.queryItems = options
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
                guard self.generation == token else {
                    Task { _ = try? await self.request(base,key:key,path:"v1/jobs/\(submitted.id)",method:"DELETE") }
                    return
                }
                self.remoteID = submitted.id
                self.logger?.log("AI 已提交", "任务=\(submitted.id)，音色=\(profile)，模式=\(conversionMode.rawValue)，参数=\(self.customSettings ? "自定义" : "推荐")")
                try Task.checkCancellation()
                var previousState = ""
                for _ in 0..<1800 {
                    try Task.checkCancellation()
                    let (data,_) = try await self.request(base,key:key,path:"v1/jobs/\(submitted.id)")
                    let job = try JSONDecoder().decode(Job.self,from:data)
                    try Task.checkCancellation()
                    guard self.generation == token else { return }
                    self.status = job.message
                    if job.state != previousState {
                        self.logger?.log("AI 任务状态", "任务=\(job.id)，状态=\(job.state)")
                        previousState = job.state
                    }
                    if job.state == "failed" || job.state == "cancelled" { throw LabError.message(job.message) }
                    if job.state == "complete" {
                        guard let metadata = job.metadata else { throw LabError.message("转换缺少来源信息") }
                        let (audio,response) = try await self.request(base,key:key,path:"v1/jobs/\(job.id)/audio")
                        let hash = SHA256.hash(data:audio).map { String(format:"%02x",$0) }.joined()
                        guard hash == metadata.sha256, hash == response.value(forHTTPHeaderField:"X-Audio-SHA256"),
                            audio.count <= 16*1024*1024 else { throw LabError.message("转换文件校验失败") }
                        try Task.checkCancellation()
                        guard self.generation == token else { return }
                        let id = UUID()
                        let name = AudioNaming.generated(kind:"AI成品",label:metadata.voiceName+"-"+metadata.modeTitle,fileExtension:"wav",id:id)
                        let local = try AudioFileManager.audioDirectory().appendingPathComponent(name)
                        do {
                            try audio.write(to:local,options:.atomic)
                            var asset = try AudioFileManager.inspect(url:local,displayName:name,id:id,source:.aiConverted,presetName:metadata.voiceName)
                            guard asset.duration >= AIAudioLimits.minimumSeconds, asset.duration <= AIAudioLimits.maximumSeconds else { throw LabError.invalidFormat }
                            asset.aiConversion = metadata
                            try AudioFileManager.register(asset)
                            self.result = asset; self.busy = false
                            self.status = "已保存 AI 声音，可以回听或应用到音频页"
                            self.logger?.log("AI 已保存", "任务=\(job.id)，引擎=\(metadata.engine)，时长=\(asset.duration)，sha256=\(hash)，耗时=\(metadata.conversionSeconds)")
                            self.onResult?(asset)
                        } catch { try? FileManager.default.removeItem(at:local); throw error }
                        return
                    }
                    try await Task.sleep(for:.seconds(1))
                }
                throw LabError.message("转换等待超过 30 分钟，请检查电脑日志")
            } catch {
                guard self.generation == token else { return }
                if let id = self.remoteID, let connection = self.activeConnection {
                    Task { _ = try? await self.request(connection.0,key:connection.1,path:"v1/jobs/\(id)",method:"DELETE") }
                }
                if !Task.isCancelled {
                    self.errorMessage = AIConnectionError.message(error); self.status = "转换未完成，可直接重试或重新连接"
                    self.logger?.log("AI 转换失败", diagnosticError(error))
                }
            }
        }
    }
    func cancel() {
        generation = UUID(); task?.cancel(); task = nil; busy = false; connecting = false
        logger?.log("AI 取消", "用户取消当前 AI 请求；可以开始下一次操作。")
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
    var conversionMode: String? = nil
    var modeTitle: String {
        AIConversionMode(rawValue:conversionMode ?? "preserveProsody")?.title ?? "旧版转换"
    }
}
