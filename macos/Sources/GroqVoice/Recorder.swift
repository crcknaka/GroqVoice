import AVFoundation
import CoreAudio
import Foundation

/// Captures the chosen input device (or the system default) with AVAudioEngine,
/// resamples to 16 kHz mono 16-bit PCM in memory. The finished take is also written to
/// last.wav for debugging and for the local Whisper path.
final class Recorder {
    struct Result {
        let duration: TimeInterval
        let peakPercent: Double
        let pcm: Data   // raw 16 kHz mono Int16 samples
        let wav: Data   // the same audio as a complete WAV file
        let deviceName: String
    }

    struct RecorderError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static var wavURL: URL { Config.supportDir.appendingPathComponent("last.wav") }
    static let sampleRate: Double = 16_000

    /// Fired on the main thread when the engine stops by itself (device
    /// unplugged, sample rate changed). Whatever was captured is still
    /// available through stop().
    var onInterrupted: (() -> Void)?

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var configObserver: NSObjectProtocol?
    private var startedAt: Date?
    private var deviceName = ""

    // Shared between the audio thread (tap) and the main thread.
    private let lock = NSLock()
    private var pcm = Data()
    private var peak = 0

    var isRecording: Bool { engine != nil }

    private struct Prepared {
        let engine: AVAudioEngine
        let converter: AVAudioConverter
        let deviceUID: String
        let deviceName: String
        let observer: NSObjectProtocol
    }
    private var prepared: Prepared?

    /// Builds and prepares an engine for `deviceUID` ahead of time so the next
    /// start() only has to flip the switch (tens of ms instead of a few
    /// hundred — the difference between catching and losing the first
    /// syllable). Cheap to call repeatedly; a no-op while recording or when the
    /// right engine is already waiting.
    func prepare(deviceUID: String) {
        guard engine == nil else { return }
        if let prepared, prepared.deviceUID == deviceUID { return }
        discardPrepared()
        do {
            prepared = try build(deviceUID: deviceUID)
            if let id = AudioDevices.defaultInputDeviceID() {
                Log.write("mic: engine prepared for \(prepared!.deviceName) (device running somewhere: \(AudioDevices.isRunningSomewhere(id)))")
            }
        } catch {
            Log.write("mic: prepare failed: \(error.localizedDescription)")
        }
    }

    /// `deviceUID` empty = system default input.
    func start(deviceUID: String) throws {
        guard engine == nil else { return }

        let ready: Prepared
        if let prepared, prepared.deviceUID == deviceUID {
            ready = prepared
            self.prepared = nil
        } else {
            discardPrepared()
            ready = try build(deviceUID: deviceUID)
        }

        lock.lock()
        pcm = Data()
        peak = 0
        lock.unlock()

        converter = ready.converter
        configObserver = ready.observer
        deviceName = ready.deviceName
        engine = ready.engine
        do {
            try ready.engine.start()
        } catch {
            teardown()
            throw error
        }
        startedAt = Date()
    }

    private func build(deviceUID: String) throws -> Prepared {
        var pinned: AudioInputDevice?
        if !deviceUID.isEmpty {
            pinned = AudioDevices.device(uid: deviceUID)
            if pinned == nil {
                Log.write("mic: configured device \(deviceUID) not present → system default")
            }
        }
        // inputNode raises an Objective-C exception (uncatchable) when the Mac
        // has no input device at all, so check first.
        guard pinned != nil || AudioDevices.defaultInputDeviceID() != nil else {
            throw RecorderError(message: "No microphone available")
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let name: String
        if let pinned {
            try Recorder.setDevice(pinned.id, on: input)
            name = pinned.name
        } else {
            name = AudioDevices.defaultInputDeviceID().map(AudioDevices.name(of:)) ?? "default"
        }

        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw RecorderError(message: "Microphone reports an empty audio format")
        }
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Recorder.sampleRate,
                                            channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw RecorderError(message: "Cannot convert \(Int(inFormat.sampleRate)) Hz input to 16 kHz")
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
            self?.consume(buffer)
        }

        // Device unplugged / sample rate changed: a running take is finished
        // with what it has; an idle prepared engine is simply thrown away and
        // rebuilt on the next start.
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.engine === engine {
                Log.write("mic: audio configuration changed mid-recording — stopping")
                self.onInterrupted?()
            } else if self.prepared?.engine === engine {
                Log.write("mic: audio configuration changed — prepared engine discarded")
                self.discardPrepared()
            }
        }

        engine.prepare()
        return Prepared(engine: engine, converter: converter, deviceUID: deviceUID, deviceName: name, observer: observer)
    }

    private func discardPrepared() {
        guard let prepared else { return }
        NotificationCenter.default.removeObserver(prepared.observer)
        prepared.engine.inputNode.removeTap(onBus: 0)
        self.prepared = nil
    }

    func stop() -> Result? {
        guard let engine, let t0 = startedAt else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        teardown()

        lock.lock()
        let samples = pcm
        let pk = peak
        pcm = Data()
        peak = 0
        lock.unlock()

        // Audio actually captured, not wall-clock — engine start-up latency
        // shouldn't count towards the "too short" filter.
        let duration = Double(samples.count / 2) / Recorder.sampleRate
        Log.write(String(format: "mic: %@ — %.2fs captured over %.2fs wall", deviceName, duration, Date().timeIntervalSince(t0)))
        let wav = Recorder.wav(pcm16: samples)
        try? wav.write(to: Recorder.wavURL)
        return Result(duration: duration,
                      peakPercent: Double(pk) / 32768.0 * 100.0,
                      pcm: samples,
                      wav: wav,
                      deviceName: deviceName)
    }

    func discard() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        teardown()
        lock.lock()
        pcm = Data()
        peak = 0
        lock.unlock()
    }

    private func teardown() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine = nil
        converter = nil
        startedAt = nil
    }

    // MARK: - Audio thread

    private func consume(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let outFormat = converter.outputFormat
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }

        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0, let channel = out.int16ChannelData else { return }

        let n = Int(out.frameLength)
        let samples = channel[0]
        var localPeak = 0
        for i in 0..<n {
            let a = abs(Int(samples[i]))
            if a > localPeak { localPeak = a }
        }

        lock.lock()
        pcm.append(UnsafeBufferPointer(start: samples, count: n))
        if localPeak > peak { peak = localPeak }
        lock.unlock()
    }

    // MARK: - Helpers

    private static func setDevice(_ id: AudioDeviceID, on node: AVAudioInputNode) throws {
        guard let unit = node.audioUnit else {
            throw RecorderError(message: "Input node has no audio unit")
        }
        var device = id
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            throw RecorderError(message: "Cannot select microphone (CoreAudio error \(status))")
        }
    }

    /// Byte range of the "data" chunk payload in a RIFF/WAVE file (walks the
    /// chunk list, since encoders insert extra chunks before the samples).
    static func dataChunkRange(in data: Data) -> Range<Int>? {
        guard data.count > 12 else { return nil }
        var offset = 12  // past "RIFF" + size + "WAVE"
        while offset + 8 <= data.count {
            let id = data.subdata(in: offset..<offset + 4)
            let size = Int(UInt32(data[offset + 4])
                | (UInt32(data[offset + 5]) << 8)
                | (UInt32(data[offset + 6]) << 16)
                | (UInt32(data[offset + 7]) << 24))
            if id == Data("data".utf8) {
                let start = offset + 8
                return start..<min(start + size, data.count)
            }
            offset += 8 + size + (size & 1)  // chunks are word-aligned
        }
        return nil
    }

    /// Wraps raw 16 kHz mono 16-bit PCM into a canonical 44-byte-header WAV.
    static func wav(pcm16: Data) -> Data {
        var d = Data(capacity: 44 + pcm16.count)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let rate = UInt32(sampleRate)
        d.append(contentsOf: "RIFF".utf8)
        u32(UInt32(36 + pcm16.count))
        d.append(contentsOf: "WAVE".utf8)
        d.append(contentsOf: "fmt ".utf8)
        u32(16)             // PCM chunk size
        u16(1)              // PCM
        u16(1)              // mono
        u32(rate)
        u32(rate * 2)       // byte rate
        u16(2)              // block align
        u16(16)             // bits per sample
        d.append(contentsOf: "data".utf8)
        u32(UInt32(pcm16.count))
        d.append(pcm16)
        return d
    }
}
