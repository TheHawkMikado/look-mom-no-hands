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
    /// to the Apple transcript. The default timeout suits short command clips;
    /// recorder chunks (60–90s of audio) pass a longer one — the server can sit
    /// well past 30s before answering, and timing out used to lose the chunk.
    func transcribe(wav: Data, timeout: TimeInterval = 30) async throws -> String {
        let boundary = "lmnh-\(UInt64(wav.count))-boundary"
        var req = Self.request(boundary: boundary, apiKey: apiKey, timeout: timeout)
        req.httpBody = Self.multipartBody(audio: wav, filename: "audio.wav",
                                          contentType: "audio/wav", boundary: boundary)
        let (data, response) = try await session.data(for: req)
        let text = try Self.parse(data: data, response: response)
        // Billing lives at the entry points, not in shared plumbing — each
        // names its bucket, and active-time policy lives with the bucket.
        await CostMeter.shared.recordScribe(seconds: Self.audioSeconds(wav: wav), to: .dictation)
        return text
    }

    /// Transcribes an audio FILE by streaming it from disk. A meeting recording
    /// can be >100 MB; building the multipart body in memory would hold ~3 full
    /// copies at peak (source + body + URLSession's copy), so the envelope is
    /// assembled in a temp file and uploaded with `upload(fromFile:)` instead.
    /// `billedSeconds` feeds the cost meter directly because a compressed
    /// container's duration can't be read off a WAV header.
    func transcribeFile(at url: URL, contentType: String, billedSeconds: Double,
                        timeout: TimeInterval) async throws -> String {
        let boundary = "lmnh-file-\(UUID().uuidString)"
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lmnh-upload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let writer = try FileHandle(forWritingTo: tmp)
        try writer.write(contentsOf: Self.multipartHead(filename: url.lastPathComponent,
                                                        contentType: contentType, boundary: boundary))
        let reader = try FileHandle(forReadingFrom: url)
        while let chunk = try reader.read(upToCount: 4 << 20), !chunk.isEmpty {
            try Task.checkCancellation()   // a cancelled notes run must not copy 100 MB first
            try writer.write(contentsOf: chunk)
        }
        try reader.close()
        try writer.write(contentsOf: Self.multipartTail(boundary: boundary))
        try writer.close()

        let req = Self.request(boundary: boundary, apiKey: apiKey, timeout: timeout)
        let (data, response) = try await session.upload(for: req, fromFile: tmp)
        let text = try Self.parse(data: data, response: response)
        await CostMeter.shared.recordScribe(seconds: billedSeconds, to: .meetings)
        return text
    }

    private static func request(boundary: String, apiKey: String, timeout: TimeInterval) -> URLRequest {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "content-type")
        return req
    }

    private static func parse(data: Data, response: URLResponse) throws -> String {
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

    /// Duration in seconds of a canonical PCM WAV, read from its header. Used only
    /// for cost metering, so a best-effort parse (assuming the standard 44-byte
    /// header the app writes) is enough; anything odd returns 0 and is ignored.
    static func audioSeconds(wav: Data) -> Double {
        guard wav.count > 44 else { return 0 }
        func u16(_ o: Int) -> Int { Int(wav[wav.startIndex + o]) | (Int(wav[wav.startIndex + o + 1]) << 8) }
        func u32(_ o: Int) -> Int { u16(o) | (u16(o + 2) << 16) }
        let channels = max(1, u16(22))
        let sampleRate = u32(24)
        let bytesPerFrame = channels * max(1, u16(34) / 8)
        guard sampleRate > 0, bytesPerFrame > 0 else { return 0 }
        return Double(wav.count - 44) / Double(sampleRate * bytesPerFrame)
    }

    // Two form fields: model_id and the audio file. Built by hand — no multipart
    // helper in Foundation. The head is shared with the streaming file path.
    static func multipartHead(filename: String, contentType: String, boundary: String) -> Data {
        // A meeting title can carry quotes or newlines into the filename; either
        // would break the Content-Disposition header and fail the whole upload.
        let safe = filename.map { c -> Character in "\"\r\n".contains(c) ? "'" : c }
        var head = Data()
        head.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"model_id\"\r\n\r\n\(model)\r\n".utf8))
        head.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(String(safe))\"\r\n".utf8))
        head.append(Data("Content-Type: \(contentType)\r\n\r\n".utf8))
        return head
    }

    static func multipartTail(boundary: String) -> Data {
        Data("\r\n--\(boundary)--\r\n".utf8)
    }

    static func multipartBody(audio: Data, filename: String, contentType: String, boundary: String) -> Data {
        var body = multipartHead(filename: filename, contentType: contentType, boundary: boundary)
        body.reserveCapacity(body.count + audio.count + 128)
        body.append(audio)
        body.append(multipartTail(boundary: boundary))
        return body
    }
}
