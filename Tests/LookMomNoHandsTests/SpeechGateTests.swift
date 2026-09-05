import XCTest
@testable import LookMomNoHands

final class SpeechGateTests: XCTestCase {

    private func wav(amplitude: Double, seconds: Double = 1.0, rate: Double = 16000) -> Data {
        let count = Int(seconds * rate)
        let samples = (0..<count).map { i in
            Int16(amplitude * 32767.0 * sin(2.0 * .pi * 220.0 * Double(i) / rate))
        }
        return VoiceListener.wav(from: samples, sampleRate: rate)
    }

    func testSilenceNeverUploads() {
        XCTAssertFalse(SpeechGate.hasVoice(wav: wav(amplitude: 0)))
        // Mic self-noise / room hiss territory — still below the gate.
        XCTAssertFalse(SpeechGate.hasVoice(wav: wav(amplitude: 0.002)))
    }

    func testQuietSpeechPasses() {
        // The gate stops dead air, not soft talkers: well below normal speech
        // level must still pass.
        XCTAssertTrue(SpeechGate.hasVoice(wav: wav(amplitude: 0.02)))
        XCTAssertTrue(SpeechGate.hasVoice(wav: wav(amplitude: 0.3)))
    }

    func testOneWordInLongSilencePassesTheWholeChunk() {
        // 11s of silence + 1s of speech: max-window, not average — the chunk ships.
        var samples = [Int16](repeating: 0, count: 11 * 16000)
        samples += (0..<16000).map { i in Int16(0.1 * 32767.0 * sin(2.0 * .pi * 220.0 * Double(i) / 16000.0)) }
        XCTAssertTrue(SpeechGate.hasVoice(wav: VoiceListener.wav(from: samples, sampleRate: 16000)))
    }

    func testGarbageDataReadsAsSilent() {
        XCTAssertFalse(SpeechGate.hasVoice(wav: Data()))
        XCTAssertFalse(SpeechGate.hasVoice(wav: Data(repeating: 0, count: 10)))
    }

    func testShortDictationsSkipTheModel() {
        XCTAssertTrue(SpeechGate.tooShortForCleanup("Thank you."))
        XCTAssertTrue(SpeechGate.tooShortForCleanup("yes"))
        XCTAssertTrue(SpeechGate.tooShortForCleanup("ship it now"))
        XCTAssertFalse(SpeechGate.tooShortForCleanup("please reply to that email and send it"))
    }

    func testInventedCleanupIsCaught() {
        // The observed failure: a hallucinated scrap in, the model's own
        // instructions out. Ballooning from a short input = invented.
        XCTAssertTrue(SpeechGate.cleanupLooksInvented(
            raw: "Thank you.",
            cleaned: "I'm ready to clean up dictated text. Please provide the text you'd like me to fix."))
        // Normal growth on real input (punctuation, casing) is not invention.
        XCTAssertFalse(SpeechGate.cleanupLooksInvented(
            raw: "please reply to that email and send it before noon today thanks",
            cleaned: "Please reply to that email and send it before noon today. Thanks!"))
        // Long inputs may grow freely (paragraph breaks).
        XCTAssertFalse(SpeechGate.cleanupLooksInvented(
            raw: String(repeating: "words and more words ", count: 20),
            cleaned: String(repeating: "Words and more words. ", count: 22)))
    }
}
