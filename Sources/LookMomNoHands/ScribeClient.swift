import Foundation

// ElevenLabs Scribe speech-to-text (batch). We re-transcribe a captured utterance
// for higher accuracy than Apple's on-device model — used for dictation (and
// optionally commands) while Apple stays the always-on wake/gating engine.
// Batch, not the realtime WebSocket: for a note that's already finished, a single
// POST is simpler and cheaper, and the extra latency doesn't matter.

struct ScribeClient: Sendable {
    enum ScribeError: Error, CustomStringConvertible {
        case http(status: Int, body: String)
        case noText

        var description: String {
            switch self {
            case .http(let s, let b): return "Scribe HTTP \(s): \(b.prefix(160))"
            case .noText: return "Scribe returned no transcript"
            }
        }
    }

    let apiKey: String
    var session: URLSession = .shared
    private static let endpoint = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!
    private static let model = "scribe_v1"

    /// Transcribes a WAV clip. Throws on any failure so the caller can fall back
    /// to the Apple transcript.
    func transcribe(wav: Data) async throws -> String {
        let boundary = "lmnh-\(UInt64(wav.count))-boundary"
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "content-type")
        req.httpBody = Self.multipartBody(wav: wav, boundary: boundary)

        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ScribeError.http(status: status, body: String(decoding: data, as: UTF8.self))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String, !text.isEmpty else {
            throw ScribeError.noText
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Two form fields: model_id and the audio file. Built by hand — no multipart
    // helper in Foundation.
    static func multipartBody(wav: Data, boundary: String) -> Data {
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }
        field("model_id", model)
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".utf8))
        body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }
}
