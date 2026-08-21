import Foundation

protocol FlowSpeechEngine: AnyObject {
    var onWordRange: ((Range<Int>?) -> Void)? { get set }
    func read(_ plan: LanguageFlow.Plan, settings: FlowSettings)
    func setSpeed(_ multiplier: Float)
    func pause()
    func resume()
    func stop()
}

extension FlowSpeechEngine {
    func setSpeed(_ multiplier: Float) {}
}
