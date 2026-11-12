import AVFoundation
import Observation

public struct ReaderVoice: Identifiable, Sendable { public let id: String; public let name: String; public let language: String }

@MainActor @Observable
public final class SpeechPlayer {
    public enum Status { case stopped, playing, paused }
    public private(set) var status = Status.stopped
    public private(set) var voices: [ReaderVoice] = []
    public var rate = 1.0
    public var voiceIdentifier = ""
    public private(set) var position: SourceAnchor?
    public private(set) var completed = false
    public var errorMessage: String?
    public private(set) var spokenText = ""
    @ObservationIgnored private var synthesizer: AVSpeechSynthesizer?
    @ObservationIgnored private var bridge: SpeechDelegate?
    @ObservationIgnored private weak var engine: (any ReaderEngine)?
    @ObservationIgnored private var passage: ReaderPassage?
    @ObservationIgnored private var utteranceID: ObjectIdentifier?
    @ObservationIgnored public var onPosition: ((SourceAnchor) -> Void)?
    @ObservationIgnored public var onPassage: ((ReaderPassage) -> Void)?
    @ObservationIgnored public var onWord: ((ReaderPassage) -> Void)?
    @ObservationIgnored public var onStop: (() -> Void)?
    @ObservationIgnored private let volume: Float
    public init(volume: Float = 1) { self.volume = volume.isFinite ? min(1, max(0, volume)) : 1 }
    public func loadVoices() async {
        let values = await Task.detached(priority: .utility) {
            AVSpeechSynthesisVoice.speechVoices().map { ReaderVoice(id: $0.identifier, name: $0.name, language: $0.language) }
        }.value
        voices = values.sorted { $0.language == $1.language ? $0.name < $1.name : $0.language < $1.language }
    }
    public func start(engine: any ReaderEngine, anchor: SourceAnchor) {
        stop(); self.engine = engine; position = anchor; errorMessage = nil; completed = false; spokenText = ""
        guard engine.capabilities.contains(.readAloud) else { errorMessage = String(localized: "This source has no readable text."); return }
        status = .playing; speak(anchor)
    }
    private func speak(_ anchor: SourceAnchor) {
        guard let engine else { stop(); return }
        do {
            let next = try engine.textPassage(at: anchor)
            guard !next.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { completed = true; stop(); return }
            let voice = voiceIdentifier.isEmpty ? AVSpeechSynthesisVoice(language: (engine as? EPUBReaderEngine)?.publication.language ?? Locale.current.language.languageCode?.identifier) : AVSpeechSynthesisVoice(identifier: voiceIdentifier)
            guard let voice else { throw SpeechError.unavailableVoice }
            passage = next; position = next.anchor
            let utterance = AVSpeechUtterance(string: next.text)
            utterance.voice = voice
            utterance.volume = volume
            utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(rate)))
            utteranceID = ObjectIdentifier(utterance)
            onPassage?(next); onPosition?(next.anchor)
            guard status == .playing, self.engine === engine else { return }
            if synthesizer == nil {
                let value = AVSpeechSynthesizer(), delegate = SpeechDelegate(owner: self)
                bridge = delegate; value.delegate = delegate; synthesizer = value
            }
            synthesizer?.speak(utterance)
        } catch { errorMessage = NSLocalizedString(error.localizedDescription, comment: "Speech error"); stop() }
    }
    public func pause() {
        guard status == .playing else { return }
        if synthesizer?.pauseSpeaking(at: .immediate) == true { status = .paused }
    }
    public func resume() {
        guard status == .paused else { return }
        if utteranceID == nil {
            if let next = passage?.next { status = .playing; speak(next) }
            else { completed = true; stop() }
            return
        }
        if synthesizer?.continueSpeaking() == true { status = .playing }
    }
    public func stop() {
        utteranceID = nil; passage = nil
        if status != .stopped { status = .stopped; _ = synthesizer?.stopSpeaking(at: .immediate); onStop?() }
        engine = nil; synthesizer = nil; bridge = nil
    }
    fileprivate func finished(_ id: ObjectIdentifier) {
        guard utteranceID == id, status != .stopped else { return }
        if status == .paused { utteranceID = nil; return }
        if let next = passage?.next { speak(next) }
        else { completed = true; stop() }
    }
    fileprivate func cancelled(_ id: ObjectIdentifier) { if utteranceID == id { stop() } }
    fileprivate func progress(_ id: ObjectIdentifier, range: NSRange) {
        guard utteranceID == id, let passage, let engine else { return }
        do {
            let anchor: SourceAnchor
            if case .epub(let resource, let encoded) = passage.anchor.position {
                let start = try EPUBTextLocator(encoded: encoded).offset
                anchor = SourceAnchor(bookID: engine.bookID, sourceRevision: engine.sourceRevision, position: .epub(resource: resource, locator: EPUBTextLocator(offset: start + range.location).encoded))
            } else { anchor = passage.anchor }
            position = anchor; onPosition?(anchor)
            let text = passage.text as NSString
            if range.location + range.length <= text.length {
                spokenText = text.substring(with: range)
                onWord?(ReaderPassage(anchor: anchor, text: text.substring(with: range), next: nil))
            }
        } catch { errorMessage = NSLocalizedString(error.localizedDescription, comment: "Speech error"); stop() }
    }
}

private enum SpeechError: LocalizedError {
    case unavailableVoice
    var errorDescription: String? { String(localized: "No installed speech voice is available for this language. Choose a voice in Listen & Read.") }
}

/// Retain the immutable identity until actor delivery, preventing an allocator
/// reusing an old utterance address while an earlier callback is still queued.
private final class SpeechUtteranceIdentity: @unchecked Sendable {
    private let value: AVSpeechUtterance
    init(_ value: AVSpeechUtterance) { self.value = value }
    var id: ObjectIdentifier { ObjectIdentifier(value) }
}

/// AVFoundation may deliver callbacks off the main actor. Only immutable identity
/// and range values cross that boundary; the synthesizer stays with its owner.
private final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    weak var owner: SpeechPlayer?
    init(owner: SpeechPlayer) { self.owner = owner }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let identity = SpeechUtteranceIdentity(utterance); Task { @MainActor [weak self] in self?.owner?.finished(identity.id) }
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let identity = SpeechUtteranceIdentity(utterance); Task { @MainActor [weak self] in self?.owner?.cancelled(identity.id) }
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString range: NSRange, utterance: AVSpeechUtterance) {
        let identity = SpeechUtteranceIdentity(utterance); Task { @MainActor [weak self] in self?.owner?.progress(identity.id, range: range) }
    }
}
