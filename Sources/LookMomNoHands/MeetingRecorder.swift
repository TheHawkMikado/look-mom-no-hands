import Foundation
import AVFoundation
import ScreenCaptureKit

/// Two-source mono mixer: system audio (everyone else in the call) + mic (the
/// user). Buffers arrive from independent clocks, so it mixes the overlapping
/// prefix and, when one source stalls past `maxLeadFrames`, flushes the leader
/// against silence — a dead source degrades the mix, never stalls the file.
/// Pure — unit-tested.
struct MeetingAudioMixer {
    private(set) var system: [Float] = []
    private(set) var mic: [Float] = []
    let maxLeadFrames: Int

    init(maxLeadFrames: Int) { self.maxLeadFrames = maxLeadFrames }

    mutating func appendSystem(_ samples: [Float]) { system += samples }
    mutating func appendMic(_ samples: [Float]) { mic += samples }

    mutating func drain(flushAll: Bool = false) -> [Float] {
        var out: [Float] = []
        let n = min(system.count, mic.count)
        if n > 0 {
            out.reserveCapacity(n)
            for i in 0..<n { out.append(Self.clamp(system[i] + mic[i])) }
            system.removeFirst(n)
            mic.removeFirst(n)
        }
        if flushAll || system.count > maxLeadFrames {
            out += system.map(Self.clamp)
            system.removeAll(keepingCapacity: true)
        }
        if flushAll || mic.count > maxLeadFrames {
            out += mic.map(Self.clamp)
            mic.removeAll(keepingCapacity: true)
        }
        return out
    }

    static func clamp(_ x: Float) -> Float { max(-1, min(1, x)) }
}

/// Records a meeting to a single mono 48 kHz AAC (.m4a) file: system audio via
/// ScreenCaptureKit (needs the Screen Recording grant the vision fallback
/// already uses), the user's own voice via a tee of the always-on mic tap.
/// `excludesCurrentProcessAudio` keeps our own TTS confirmations out of the file.
/// All audio state lives on one serial queue; callers touch only start/stop/ingest.
final class MeetingRecorder: NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {
    static let sampleRate = 48_000.0

    enum RecordError: Error { case noDisplay }

    private let queue = DispatchQueue(label: "com.lookmomnohands.meetingrecorder")
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: MeetingRecorder.sampleRate,
                                             channels: 1, interleaved: false)!
    // Everything below is guarded by `queue`.
    private var stream: SCStream?
    private var file: AVAudioFile?
    private var mixer = MeetingAudioMixer(maxLeadFrames: Int(MeetingRecorder.sampleRate * 2))
    private var systemConverter: AVAudioConverter?
    private var micConverter: AVAudioConverter?
    private var framesWritten: Int64 = 0
    private var active = false

    /// Main queue; the capture died underneath us (display change, TCC revoke).
    var onFailure: ((String) -> Void)?

    /// Starts capturing and returns the file being written.
    func start(into directory: URL, title: String) async throws -> URL {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw RecordError.noDisplay }
        // Display filter with no exclusions: audio capture is per-system, and we
        // only need SOME filter to open the stream.
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(Self.sampleRate)
        config.channelCount = 1
        // SCStream insists on a video pipeline; starve it (tiny frame, 1 fps,
        // no video output attached) so this stays an audio tap in practice.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let url = Self.recordingURL(in: directory, title: title)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                       AVSampleRateKey: Self.sampleRate,
                                       AVNumberOfChannelsKey: 1,
                                       AVEncoderBitRateKey: 96_000]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        queue.sync {
            self.stream = stream
            self.file = file
            self.mixer = MeetingAudioMixer(maxLeadFrames: Int(Self.sampleRate * 2))
            self.systemConverter = nil
            self.micConverter = nil
            self.framesWritten = 0
            self.active = true
        }
        return url
    }

    /// Stops capturing, flushes the tail, and returns the recorded duration.
    /// Nil only when no capture was ever started. Keyed on `stream`, not
    /// `active` — a mid-recording write failure clears `active` but the SCStream
    /// (and the macOS capture indicator) must still be torn down here.
    func stop() async -> TimeInterval? {
        let stream: SCStream? = queue.sync {
            active = false   // ingest/callbacks turn into no-ops immediately
            let s = self.stream
            self.stream = nil
            return s
        }
        guard let stream else { return nil }
        try? await stream.stopCapture()
        return queue.sync {
            writeOut(mixer.drain(flushAll: true))
            let seconds = Double(framesWritten) / Self.sampleRate
            // AVAudioFile finalizes the container on release — drop every ref here.
            self.file = nil
            self.systemConverter = nil
            self.micConverter = nil
            return seconds
        }
    }

    /// Tee from VoiceListener's mic tap — the coordinator wires it only while a
    /// meeting records, so the idle app never pays for the hop. REALTIME AUDIO
    /// THREAD: the engine reuses the tap buffer's storage the moment this
    /// returns, so the samples are copied out here, synchronously, before the
    /// queue hop (same invariant as VoiceListener's own tap consumers).
    func ingestMic(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: ch[0], count: n))
        let rate = buffer.format.sampleRate
        queue.async { [weak self] in
            guard let self, self.active else { return }
            self.mixer.appendMic(self.resampleMic(samples, from: rate))
            self.writeOut(self.mixer.drain())
        }
    }

    /// Rewraps copied mic samples for the streaming converter. On `queue`.
    private func resampleMic(_ samples: [Float], from rate: Double) -> [Float] {
        guard rate != Self.sampleRate else { return samples }
        guard let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                           channels: 1, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: inFormat,
                                         frameCapacity: AVAudioFrameCount(samples.count)) else { return [] }
        samples.withUnsafeBufferPointer { src in
            buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        buf.frameLength = AVAudioFrameCount(samples.count)
        return convert(buf, using: &micConverter)
    }

    // MARK: SCStream callbacks (already on `queue`)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, active, sampleBuffer.isValid,
              let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
        mixer.appendSystem(convert(pcm, using: &systemConverter))
        writeOut(mixer.drain())
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Only mark inactive: the file may still be fine (the failure was
        // capture-side), and stop() — driven by the coordinator's onFailure
        // handler — does the flush, finalize, and stream release.
        queue.async { [weak self] in self?.active = false }
        DispatchQueue.main.async { [weak self] in
            self?.onFailure?("screen capture stopped: \(error.localizedDescription)")
        }
    }

    // MARK: Internals (on `queue`)

    /// Resamples any incoming format to 48 kHz mono float. The converter is
    /// stateful across calls (streaming resample), rebuilt only on format change.
    private func convert(_ buffer: AVAudioPCMBuffer, using converter: inout AVAudioConverter?) -> [Float] {
        if buffer.format == targetFormat, let ch = buffer.floatChannelData {
            return Array(UnsafeBufferPointer(start: ch[0], count: Int(buffer.frameLength)))
        }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
        }
        guard let converter else { return [] }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return [] }
        var fed = false
        converter.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard let ch = out.floatChannelData, out.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    }

    private func writeOut(_ samples: [Float]) {
        guard !samples.isEmpty, let file,
              let buf = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                         frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        samples.withUnsafeBufferPointer { src in
            buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        buf.frameLength = AVAudioFrameCount(samples.count)
        do {
            try file.write(from: buf)
            framesWritten += Int64(samples.count)
        } catch {
            // Disk-full/IO death: stop accumulating rather than growing RAM
            // forever. The stream is left for stop() to tear down — the
            // coordinator's onFailure handler drives that.
            active = false
            self.file = nil
            DispatchQueue.main.async { [weak self] in
                self?.onFailure?("couldn't write the recording: \(error.localizedDescription)")
            }
        }
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
              let format = AVAudioFormat(streamDescription: asbd) else { return nil }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return nil }
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0,
                                                                  frameCount: Int32(frames),
                                                                  into: pcm.mutableAudioBufferList)
        guard status == noErr else { return nil }
        pcm.frameLength = AVAudioFrameCount(frames)
        return pcm
    }

    /// Recordings/Meeting <title> <stamp>.m4a under the app-support folder.
    /// Pure enough to unit-test the sanitizing.
    static func recordingURL(in directory: URL, title: String, now: Date = Date()) -> URL {
        let folder = directory.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH.mm"
        let safe = title.map { "/:\\".contains($0) ? "-" : $0 }.map(String.init).joined()
            .trimmingCharacters(in: .whitespaces)
        let name = "Meeting \(safe.isEmpty ? "call" : String(safe.prefix(40))) \(fmt.string(from: now)).m4a"
        return folder.appendingPathComponent(name)
    }
}
