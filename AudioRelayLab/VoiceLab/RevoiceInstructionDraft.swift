import Foundation

struct AutomaticInstructionSource:Codable,Equatable,Sendable {
    let text:String
    let baseInstruction:String
    let kind:String
    let voiceID:String
}

struct AutomaticInstructionDraft:Codable,Equatable,Sendable {
    var text:String
    var userEdited:Bool
    let source:AutomaticInstructionSource
}
