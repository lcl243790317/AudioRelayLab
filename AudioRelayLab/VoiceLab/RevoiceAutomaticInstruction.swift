import Foundation

/// A local, deterministic reading of words and punctuation, not a semantic model.
/// It cannot reliably understand irony, implied emotions or the speaker's intent.
/// Only predefined delivery phrases enter the instruction; input text is never quoted.
enum RevoiceAutomaticInstruction {
    static let maximumBaseScalars = 240
    static let maximumInstructionScalars = 500
    private static let maximumAnalysisScalars = 1000
    private static let identity = "保持所选声线、音色与角色身份。"
    private static let expressionPrefix = "\n本次表达（情绪与语速按下列要求调整，其余保留角色基础）："

    enum Emotion:String, Equatable, Sendable {
        case neutral, happy, sad, angry, reassuring, urgent, mixed
        var label:String {
            switch self {
            case .neutral: return "自然平静"
            case .happy: return "欣喜轻快"
            case .sad: return "低落克制"
            case .angry: return "不满克制"
            case .reassuring: return "温柔安抚"
            case .urgent: return "紧迫专注"
            case .mixed: return "随句意克制变化"
            }
        }
    }

    struct Profile:Equatable, Sendable {
        let emotion:Emotion
        let pace:String
        let tone:String
        let breath:String
        let pauses:String
        let diction:String
        var summary:String { "\(emotion.label) · \(pace) · \(tone)" }
        var instruction:String {
            "情绪：\(emotion.label)；语速：\(pace)；口吻与腔调：\(tone)；气声：\(breath)；停顿：\(pauses)；咬字：\(diction)。"
        }
    }

    static func make(text:String,baseInstruction:String) -> String {
        let expression = profile(text:text).instruction
        let baseline = baseInstruction.trimmingCharacters(in:.whitespacesAndNewlines)
        let budget = baseInstructionBudget(text:text)
        let kept:String
        if baseline.unicodeScalars.count > budget {
            kept = scalarPrefix(baseline,max(0,budget-1)) + "…"
        } else { kept = baseline }
        let base = kept.isEmpty ? "" : "角色基础：" + kept
        return identity + base + expressionPrefix + expression
    }

    static func baseInstructionBudget(text:String) -> Int {
        let reserved = (identity + "角色基础：" + expressionPrefix + profile(text:text).instruction).unicodeScalars.count
        return min(maximumBaseScalars,max(0,maximumInstructionScalars-reserved))
    }

    static func baseWasShortened(text:String,baseInstruction:String) -> Bool {
        baseInstruction.trimmingCharacters(in:.whitespacesAndNewlines).unicodeScalars.count > baseInstructionBudget(text:text)
    }

    static func profile(text:String) -> Profile {
        // Generation trims the draft before validation. Match its text here so a
        // padded preview never loses a cue at the analysis limit or adds a paragraph.
        let source = scalarPrefix(text.trimmingCharacters(in:.whitespacesAndNewlines),maximumAnalysisScalars)
            .lowercased(with:Locale(identifier:"en_US_POSIX"))
            .replacingOccurrences(of:"’",with:"'")
        let moods:[(Emotion,[String])] = [
            (.happy,["开心","開心","高兴","高興","太好了","好耶","真棒","恭喜","哈哈",
                "happy","glad","wonderful","great","congratulations","excited","hurray",
                "嬉し","うれしい","やった","おめでとう","楽し","たのしい","행복","기뻐","축하","신난"]),
            (.sad,["难过","難過","伤心","傷心","悲伤","悲傷","心痛","想哭","哭了","遗憾","遺憾","舍不得","失去","孤独","孤獨","对不起","抱歉","再也见不到","好想你",
                "sad","miss you","heartbroken","grief","grieving","sorry","lonely","tears","goodbye",
                "悲し","かなしい","寂し","さみしい","泣きたい","ごめん","会いたい","슬프","눈물","그리워","외로","미안","죄송"]),
            (.angry,["生气","生氣","愤怒","憤怒","可恶","可惡","气死","氣死","闭嘴","閉嘴","滚开","受夠了","受够了","凭什么","不可原谅",
                "angry","furious","outraged","shut up","how dare","hate",
                "怒って","怒り","許せない","ふざけるな","腹が立つ","화가 나","화났","분노","짜증","그만해"]),
            (.reassuring,["别怕","別怕","不用怕","放心","没关系","沒關係","别担心","別擔心","不用担心","我陪着你","我在这里","慢慢来","会没事","不要害怕","不要难过",
                "don't worry","do not worry","it's okay","it is okay","take your time","you are safe","i'm here","i am here",
                "大丈夫","心配しないで","安心して","怖がらないで","ゆっくり","괜찮","걱정하지","두려워하지","안심","천천히"]),
            (.urgent,["救命","快点","快點","赶快","趕快","来不及","來不及","快跑","危险","危險","着火","立刻离开","马上离开",
                "help!","help me!","hurry","danger","run away","emergency","urgent","save me",
                "助けて","早く","急いで","危ない","逃げて","도와줘!","살려줘","빨리","위험","서둘러","당장"])
        ]
        let found = moods.compactMap { mood,cues in
            cues.contains { hasCue($0,in:source) } ? mood : nil
        }
        // Conflicting cues never force an exaggerated, single emotion on every sentence.
        let emotion:Emotion = found.count > 1 ? .mixed : found.first ?? .neutral
        let isQuestion = questionCue(in:source)
        let urgent = found.contains(.urgent)
        let hasHesitation = source.contains("…") || source.contains("...")
        let longText = source.unicodeScalars.count > 120 || source.contains("\n")
        let pace:String, tone:String, breath:String, diction:String
        switch emotion {
        case .neutral:
            pace = "正常从容"
            tone = isQuestion ? "自然询问，问句尾音轻扬，避免逐句机械上扬" : "日常交谈，语调自然，避免朗诵腔"
            breath = "轻微自然气声，正常换气，不耳语"
            diction = "清楚自然，保留口头词与重复，不增删原文"
        case .happy:
            pace = "稍快但不抢字"
            tone = isQuestion ? "轻快亲切，问句带好奇感，不过度上扬" : "轻快亲切，尾音明亮，避免尖嗓与夸张撒娇"
            breath = "气声少，声音通透，换气自然"
            diction = "轻巧清楚，重音自然，不吞字，不增删原文"
        case .sad:
            pace = "稍慢，句尾自然收住"
            tone = isQuestion ? "克制低落，问句柔和询问，避免欢快上扬" : "柔和低落，情绪内收，避免哭喊与朗诵腔"
            breath = "少量柔和气声，换气稍缓，不用哭腔"
            diction = "柔和清楚，尾音收住，不含混，不增删原文"
        case .angry:
            pace = "稳健稍紧凑"
            tone = isQuestion ? "克制质问，重点稍加力度，不嘶吼" : "克制不满，重点稍加力度，不压嗓与嘶吼"
            breath = "气声少，呼吸稳定，不挤嗓"
            diction = "清楚有力，重音适度，不咬牙，不增删原文"
        case .reassuring:
            pace = "稍慢从容"
            tone = isQuestion ? "温柔关切，问句轻柔，不刻意撒娇" : "温柔笃定，亲切安抚，不刻意撒娇"
            breath = "少量温柔气声，自然换气，不耳语"
            diction = "柔和清楚，连读自然，不含混，不增删原文"
        case .urgent:
            pace = "稍快紧凑但不抢字"
            tone = "紧迫专注，提醒重点稍加强，不尖叫"
            breath = "气声少，换气短而自然，不挤嗓"
            diction = "清楚利落，提醒重点有重音，不吞字，不增删原文"
        case .mixed:
            pace = urgent ? "整体正常，紧迫句稍快，转折处放缓" : "整体正常，随句意轻微调整"
            tone = isQuestion ? "随句意克制变化，问句自然询问，不突然换腔" : "随句意克制变化，转折有层次，不突然换腔"
            breath = "随句意轻微调整，换气自然，不夸张"
            diction = "转折重音适度，字词清楚，不夸张，不增删原文"
        }
        let pauses:String
        if hasHesitation { pauses = "省略处稍长停顿，其他按标点自然停顿，不拖延" }
        else if longText { pauses = "长句按意群短停，段落间稍长，不拆词" }
        else if emotion == .sad { pauses = "句末稍长，转折处短停，避免过长空白" }
        else if emotion == .urgent { pauses = "短促自然，句间保留换气，不连成一口气" }
        else { pauses = "按标点与句意自然短停，不逐字停顿" }
        return Profile(emotion:emotion,pace:pace,tone:tone,breath:breath,pauses:pauses,diction:diction)
    }

    private static func scalarPrefix(_ value:String,_ limit:Int) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf:value.unicodeScalars.prefix(max(0,limit)))
        return String(scalars)
    }

    private static func hasCue(_ cue:String,in text:String) -> Bool {
        var start = text.startIndex
        while start < text.endIndex,let range = text.range(of:cue,range:start..<text.endIndex) {
            let asciiCue = cue.unicodeScalars.allSatisfy { $0.value < 128 }
            let boundary = !asciiCue || (!asciiWord(text[..<range.lowerBound].unicodeScalars.last)
                && !asciiWord(text[range.upperBound...].unicodeScalars.first))
            if boundary && !negated(range,in:text) { return true }
            start = range.upperBound
        }
        return false
    }

    private static func asciiWord(_ scalar:Unicode.Scalar?) -> Bool {
        guard let value = scalar?.value else { return false }
        return (97...122).contains(value) || (65...90).contains(value) || (48...57).contains(value) || value == 95
    }

    private static func questionCue(in text:String) -> Bool {
        if text.contains("?") || text.contains("？") { return true }
        // Device transcripts may omit question marks. These cues keep that input useful.
        let trimmed = text.trimmingCharacters(in:.whitespacesAndNewlines)
        if ["吗","嗎","呢","ですか","ますか","까요","나요","습니까"].contains(where:trimmed.hasSuffix) { return true }
        if ["为什么","為什麼","怎么","怎麼","能不能","可不可以","要不要"].contains(where:trimmed.hasPrefix) { return true }
        return ["why ","what ","how ","when ","where ","can you ","could you ","would you "].contains(where:trimmed.hasPrefix)
    }

    private static func negated(_ range:Range<String.Index>,in text:String) -> Bool {
        // Negation is deliberately local. Contrast words and punctuation end its scope.
        let delimiters = CharacterSet(charactersIn:"，,。.!！?？;；:\n")
        var prefix = String(text[..<range.lowerBound].unicodeScalars.suffix(40))
        prefix = prefix.components(separatedBy:delimiters).last ?? ""
        for contrast in ["但是","可是","不过","不過","然而","却","但"," but "," however ","でも","けど","하지만"] {
            if let last = prefix.range(of:contrast,options:.backwards) { prefix = String(prefix[last.upperBound...]) }
        }
        let suffix = scalarPrefix(String(text[range.upperBound...]),10)
        let chinese = String(prefix.unicodeScalars.suffix(6))
        let positivePrefix = ["无比","無比","不禁","不由得"].contains(where:chinese.hasSuffix)
        if !positivePrefix,["不","没","沒","未","无","無","别","別"].contains(where:chinese.contains) { return true }
        let words = prefix.split(whereSeparator:{ $0.isWhitespace }).suffix(3).map(String.init)
        if !prefix.hasSuffix("not only ") && !prefix.hasSuffix("no doubt "),
           words.contains(where:{ ["not","never","without","don't","dont","isn't","wasn't","aren't","weren't","cannot","can't"].contains($0) }) { return true }
        if prefix.hasSuffix("안 ") || prefix.hasSuffix("못 ") { return true }
        return ["くない","しくない","くなかった","しくなかった","くありません","しくありません","ない","じゃない","ではない","지 않아","지 않","지 못"].contains(where:suffix.hasPrefix)
    }
}
