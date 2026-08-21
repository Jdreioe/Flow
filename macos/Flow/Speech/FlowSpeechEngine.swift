import Foundation

protocol FlowSpeechEngine: AnyObject {
    var onWordRange: ((Range<Int>?) -> Void)? { get set }
    var onPlaybackProgress: ((Double?) -> Void)? { get set }
    var supportsSeek: Bool { get }
    func read(_ plan: LanguageFlow.Plan, settings: FlowSettings)
    func pause()
    func resume()
    func stop()
    /// Jumps playback to `fraction` of the whole reading, where 0 is the
    /// beginning and 1 is the end. Engines that cannot seek ignore this.
    func seek(to fraction: Double)
}

extension FlowSpeechEngine {
    var supportsSeek: Bool { false }
    func seek(to fraction: Double) {}
}
