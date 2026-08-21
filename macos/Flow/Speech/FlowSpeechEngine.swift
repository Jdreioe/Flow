import Foundation

protocol FlowSpeechEngine: AnyObject {
    func read(_ plan: LanguageFlow.Plan, settings: FlowSettings)
    func pause()
    func resume()
    func stop()
}
