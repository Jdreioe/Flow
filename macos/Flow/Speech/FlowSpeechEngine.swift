import Foundation

protocol FlowSpeechEngine: AnyObject {
    var onWordRange: ((Range<Int>?) -> Void)? { get set }
    func read(_ plan: LanguageFlow.Plan, settings: FlowSettings)
    func pause()
    func resume()
    func stop()
}
