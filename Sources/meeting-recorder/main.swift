@preconcurrency import AVFoundation
import ArgumentParser
import AudioToolbox
import CoreAudio
import Foundation

// MARK: - Phase 0: Capture Proof
//
// Captures system audio + microphone as stereo WAV using an aggregate device.
// USAGE: meeting-recorder capture --duration 30 [--output ~/test.wav]
//
// This is NOT the menu bar app — it's a single-purpose binary to prove
// the audio capture pipeline works on this machine.

struct CaptureCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capture",
        abstract: "Record system audio + mic to a stereo WAV file"
    )

    @Option(name: .long, help: "Recording duration in seconds")
    var duration: Int = 30

    @Option(name: .long, help: "Output WAV file path")
    var output: String = "\(FileManager.default.homeDirectoryForCurrentUser.path)/MeetingRecordings/\(DateFormatter.filename.string(from: Date())).wav"

    @Flag(name: .long, help: "Record mono (single channel) — better for Whisper + diarization")
    var mono: Bool = false

    @Flag(name: .long, help: "List available audio devices")
    var listDevices: Bool = false

    func run() throws {
        if listDevices {
            let devices = try enumerateAudioDevices()
            for device in devices {
                let inOut = (device.isInput ? "IN" : "  ") + " " + (device.isOutput ? "OUT" : "   ")
                print("  [\(inOut)] \(device.name)")
            }
            return
        }

        print("[capture] Phase 0 — capture proof")
        print("[capture] Duration: \(duration)s")
        print("[capture] Output: \(output)")

        // Ensure output directory exists
        let outputURL = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Find available audio devices
        let devices = try enumerateAudioDevices()
        print("[capture] Found \(devices.count) audio devices")

        // Find capture devices and build dual-source setup
        let setup = try findOrCreateCaptureSetup(from: devices)

        // Record: mono (better for Whisper + diarization) or stereo (mic L, system R)
        try record(
            setup: setup,
            duration: Double(duration),
            outputURL: outputURL,
            mono: mono
        )

        print("[capture] Done — \(outputURL.path)")
    }
}

// MARK: - Audio Device Enumeration

struct AudioDevice {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let isInput: Bool
    let isOutput: Bool
}

func enumerateAudioDevices() throws -> [AudioDevice] {
    var devices: [AudioDevice] = []

    // Get all audio devices
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var dataSize: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject),
        &propertyAddress, 0, nil, &dataSize
    )
    guard status == noErr else {
        throw CaptureError.audioDeviceError("Failed to get device count: \(status)")
    }

    let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

    status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &propertyAddress, 0, nil,
        &dataSize, &deviceIDs
    )
    guard status == noErr else {
        throw CaptureError.audioDeviceError("Failed to enumerate devices: \(status)")
    }

    for deviceID in deviceIDs {
        guard let name = getDeviceName(deviceID),
              let uid = getDeviceUID(deviceID) else { continue }

        // Check input channels
        let inputChannels = getChannelCount(deviceID, scope: kAudioDevicePropertyScopeInput)
        let outputChannels = getChannelCount(deviceID, scope: kAudioDevicePropertyScopeOutput)

        devices.append(AudioDevice(
            id: deviceID,
            name: name,
            uid: uid,
            isInput: inputChannels > 0,
            isOutput: outputChannels > 0
        ))
    }

    return devices
}

func getDeviceName(_ deviceID: AudioDeviceID) -> String? {
    var name: CFString?
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceNameCFString,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var dataSize = UInt32(MemoryLayout<CFString?>.size)
    let status = AudioObjectGetPropertyData(
        deviceID, &propertyAddress, 0, nil, &dataSize, &name
    )
    guard status == noErr, let deviceName = name else { return nil }
    return deviceName as String
}

func getDeviceUID(_ deviceID: AudioDeviceID) -> String? {
    var uid: CFString?
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var dataSize = UInt32(MemoryLayout<CFString?>.size)
    let status = AudioObjectGetPropertyData(
        deviceID, &propertyAddress, 0, nil, &dataSize, &uid
    )
    guard status == noErr, let deviceUID = uid else { return nil }
    return deviceUID as String
}

func getChannelCount(_ deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    let status = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &dataSize)
    guard status == noErr else { return 0 }

    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(dataSize))
    defer { buffer.deallocate() }

    let status2 = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, buffer)
    guard status2 == noErr else { return 0 }

    let bufferListPtr = buffer.withMemoryRebound(to: AudioBufferList.self, capacity: 1) { $0 }
    let mBuffers = UnsafeMutableAudioBufferListPointer(bufferListPtr)
    var channelCount: UInt32 = 0
    for buffer in mBuffers {
        channelCount += buffer.mNumberChannels
    }
    return Int(channelCount)
}

// MARK: - Capture Device Selection

struct CaptureSetup {
    let systemAudioDevice: AudioDevice   // BlackHole (remote speaker)
    let micDevice: AudioDevice           // MacBook mic (local speaker)
    let isDualSource: Bool               // true if both devices found
}

func findOrCreateCaptureSetup(from devices: [AudioDevice]) throws -> CaptureSetup {
    // Find BlackHole for system audio capture
    let blackhole = devices.first { $0.name.localizedCaseInsensitiveContains("blackhole") }

    // Find the default microphone (built-in or external)
    let defaultMic = devices.first { device in
        device.isInput
            && !device.name.localizedCaseInsensitiveContains("blackhole")
            && (device.name.localizedCaseInsensitiveContains("microphone")
                || device.name.localizedCaseInsensitiveContains("mic")
                || device.uid.localizedCaseInsensitiveContains("built-in"))
    } ?? devices.first { $0.isInput && !$0.name.localizedCaseInsensitiveContains("blackhole") }

    if let bh = blackhole, let mic = defaultMic {
        print("[capture] ✓ Dual-source capture:")
        print("[capture]   System audio → \(bh.name)")
        print("[capture]   Microphone   → \(mic.name)")
        return CaptureSetup(systemAudioDevice: bh, micDevice: mic, isDualSource: true)
    }

    if let mic = defaultMic {
        print("[capture] ⚠️  BlackHole not found — recording mic only (no system audio)")
        print("[capture] ⚠️  Install: brew install blackhole-16ch")
        return CaptureSetup(systemAudioDevice: mic, micDevice: mic, isDualSource: false)
    }

    throw CaptureError.audioDeviceError(
        "No audio input device found. Check microphone permissions in System Settings."
    )
}

// MARK: - Recording

struct InterleavedBuffer {
    let data: Data
    let frameCount: Int
}

/// Records from two audio devices. Stereo: mic=L, system=R. Mono: mix both to single channel.
/// Mono is better for Whisper.cpp accuracy and speaker diarization.
func record(setup: CaptureSetup, duration: TimeInterval, outputURL: URL, mono: Bool = false) throws {
    let outputChannels: UInt16 = mono ? 1 : 2
    let targetSampleRate: Double = 16_000

    // Create output format
    guard let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: targetSampleRate,
        channels: AVAudioChannelCount(outputChannels),
        interleaved: true
    ) else {
        throw CaptureError.audioDeviceError("Failed to create output format")
    }

    // Prepare WAV file
    let wavHeader = WAVHeader(sampleRate: Int(targetSampleRate), channels: Int(outputChannels), bitsPerSample: 16)
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    guard let appendHandle = try? FileHandle(forWritingTo: outputURL) else {
        throw CaptureError.fileError("Cannot create output file: \(outputURL.path)")
    }
    var header = wavHeader
    appendHandle.write(Data(bytes: &header, count: MemoryLayout<WAVHeader>.size))

    var totalDataBytes: UInt32 = 0
    let startTime = Date()
    let bufferQueue = DispatchQueue(label: "com.meetingrecorder.buffer-merge", qos: .userInitiated)
    let fileQueue = DispatchQueue(label: "com.meetingrecorder.file-write", qos: .userInitiated)

    // Mic engine (left channel)
    let micEngine = AVAudioEngine()
    // System audio engine (right channel) — only if dual-source
    let sysEngine = setup.isDualSource ? AVAudioEngine() : nil

    // ── MIC TAP ─────────────────────────────────────────────
    let micFormat = micEngine.inputNode.outputFormat(forBus: 0)
    print("[capture] Mic format: \(Int(micFormat.sampleRate))Hz \(micFormat.channelCount)ch")
    micEngine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: micFormat) { buffer, _ in
        let elapsed = Date().timeIntervalSince(startTime)
        guard elapsed < duration else { return }
        guard let mono = convertToMonoInt16(buffer, inputFormat: micFormat, targetSampleRate: targetSampleRate) else { return }
        bufferQueue.async { writeInterleaved( mono, channel: .left, fileQueue: fileQueue) }
    }

    // ── SYSTEM AUDIO TAP ────────────────────────────────────
    if let sysEng = sysEngine {
        let sysFormat = sysEng.inputNode.outputFormat(forBus: 0)
        print("[capture] System audio format: \(Int(sysFormat.sampleRate))Hz \(sysFormat.channelCount)ch")
        sysEng.inputNode.installTap(onBus: 0, bufferSize: 1024, format: sysFormat) { buffer, _ in
            let elapsed = Date().timeIntervalSince(startTime)
            guard elapsed < duration else { return }
            guard let mono = convertToMonoInt16(buffer, inputFormat: sysFormat, targetSampleRate: targetSampleRate) else { return }
            bufferQueue.async { writeInterleaved( mono, channel: .right, fileQueue: fileQueue) }
        }
    }

    func writeInterleaved(_ samples: Data, channel: Channel, fileQueue: DispatchQueue) {
        let frameCount = samples.count / MemoryLayout<Int16>.size

        if mono {
            // Mono: write samples directly, both sources mixed to one channel
            fileQueue.async {
                try? appendHandle.write(contentsOf: samples)
                totalDataBytes += UInt32(samples.count)
            }
        } else {
            // Stereo: mic=left, system=right. Interleave with zero-fill for unused channel.
            let capacity = frameCount * 2 * MemoryLayout<Int16>.size
            var interleaved = Data(capacity: capacity)
            let src = samples.withUnsafeBytes { $0.bindMemory(to: Int16.self) }
            interleaved.count = capacity
            interleaved.withUnsafeMutableBytes { dst in
                let out = dst.bindMemory(to: Int16.self)
                let offset = channel == .left ? 0 : 1
                for i in 0..<frameCount {
                    out[i * 2 + offset] = src[i]
                }
            }
            fileQueue.async {
                try? appendHandle.write(contentsOf: interleaved)
                totalDataBytes += UInt32(interleaved.count)
            }
        }
    }

    enum Channel { case left, right }

    // Start both engines
    try micEngine.start()
    try sysEngine?.start()
    print("[capture] Recording \(Int(duration))s — \(setup.isDualSource ? "dual-source stereo" : "mic only")...")

    // Wait
    Thread.sleep(forTimeInterval: duration)

    // Stop
    micEngine.stop()
    micEngine.inputNode.removeTap(onBus: 0)
    sysEngine?.stop()
    sysEngine?.inputNode.removeTap(onBus: 0)

    // Drain queue
    bufferQueue.sync {}
    fileQueue.sync {}

    // Update WAV header
    try appendHandle.close()
    if let updateHandle = try? FileHandle(forWritingTo: outputURL) {
        var finalHeader = wavHeader
        finalHeader.dataSubchunkSize = totalDataBytes
        finalHeader.riffChunkSize = 36 + totalDataBytes
        updateHandle.seek(toFileOffset: 0)
        updateHandle.write(Data(bytes: &finalHeader, count: MemoryLayout<WAVHeader>.size))
        updateHandle.closeFile()
    }

    let actualDuration = Date().timeIntervalSince(startTime)
    print("[capture] Recorded \(totalDataBytes) bytes in \(String(format: "%.1f", actualDuration))s")
}

/// Converts an AVAudioPCMBuffer to mono Int16 at the target sample rate.
func convertToMonoInt16(_ buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat, targetSampleRate: Double) -> Data? {
    guard let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: targetSampleRate,
        channels: 1,
        interleaved: false
    ) else { return nil }

    guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { return nil }
    let ratio = targetSampleRate / inputFormat.sampleRate
    let targetFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
    guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: targetFrames) else { return nil }

    var error: NSError?
    converter.convert(to: outBuffer, error: &error) { _, inStatus in
        inStatus.pointee = .haveData
        return buffer
    }
    if let error = error {
        print("[capture] Conversion error: \(error)")
        return nil
    }

    guard let channelData = outBuffer.int16ChannelData else { return nil }
    let frameLength = Int(outBuffer.frameLength)
    return Data(bytes: channelData[0], count: frameLength * MemoryLayout<Int16>.size)
}

// MARK: - WAV Header

struct WAVHeader {
    // RIFF header
    var riffID: UInt32 = 0x46464952  // "RIFF"
    var riffChunkSize: UInt32 = 0     // 36 + data size
    var waveID: UInt32 = 0x45564157   // "WAVE"

    // fmt subchunk
    var fmtID: UInt32 = 0x20746d66    // "fmt "
    var fmtChunkSize: UInt32 = 16      // PCM
    var audioFormat: UInt16 = 1        // PCM = 1
    var numChannels: UInt16 = 2        // Stereo
    var sampleRate: UInt32 = 16000
    var byteRate: UInt32 = 64000       // sampleRate * numChannels * bitsPerSample/8
    var blockAlign: UInt16 = 4         // numChannels * bitsPerSample/8
    var bitsPerSample: UInt16 = 16

    // data subchunk
    var dataID: UInt32 = 0x61746164   // "data"
    var dataSubchunkSize: UInt32 = 0   // actual data size

    init(sampleRate: Int = 16000, channels: Int = 2, bitsPerSample: Int = 16) {
        self.sampleRate = UInt32(sampleRate)
        self.numChannels = UInt16(channels)
        self.bitsPerSample = UInt16(bitsPerSample)
        self.byteRate = UInt32(sampleRate * channels * bitsPerSample / 8)
        self.blockAlign = UInt16(channels * bitsPerSample / 8)
    }
}

// MARK: - Error

enum CaptureError: Error {
    case audioDeviceError(String)
    case fileError(String)
}

// MARK: - Daemon (Phase 1: Auto-Capture)

struct DaemonCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Monitor audio levels and auto-record when a meeting is detected"
    )

    @Option(name: .long, help: "dBFS threshold to start recording (default: -35)")
    var startThreshold: Float = -35

    @Option(name: .long, help: "Seconds above threshold to trigger start (default: 1.5)")
    var startWindow: Double = 1.5

    @Option(name: .long, help: "dBFS threshold to stop recording (default: -55)")
    var stopThreshold: Float = -55

    @Option(name: .long, help: "Seconds below threshold to trigger stop (default: 45)")
    var stopWindow: Double = 45

    @Option(name: .long, help: "Output directory for recordings")
    var outputDir: String = "\(FileManager.default.homeDirectoryForCurrentUser.path)/MeetingRecordings"

    func run() throws {
        print("[daemon] VAD thresholds: start=\(startThreshold)dBFS/\(startWindow)s stop=\(stopThreshold)dBFS/\(stopWindow)s")
        print("[daemon] Output: \(outputDir)")
        print("[daemon] Monitoring system audio... (Ctrl+C to stop)")

        let devices = try enumerateAudioDevices()
        let setup = try findOrCreateCaptureSetup(from: devices)

        // Monitor the SYSTEM AUDIO device (BlackHole), not the mic.
        // Meeting audio comes through BlackHole. If BlackHole isn't available,
        // fall back to the default input with a warning.
        let monitorDevice = setup.isDualSource ? setup.systemAudioDevice : setup.micDevice

        // Use a lightweight probe engine to monitor system audio levels
        let probeEngine = AVAudioEngine()

        // Set the probe engine's input to the monitoring device
        let probeNode = probeEngine.inputNode
        let probeFormat = probeNode.outputFormat(forBus: 0)
        print("[daemon] Monitoring: \(monitorDevice.name) (\(Int(probeFormat.sampleRate))Hz)")

        if !setup.isDualSource {
            print("[daemon] ⚠️  Monitoring mic instead of system audio — false positives likely")
            print("[daemon] ⚠️  Install BlackHole: brew install blackhole-16ch")
            print("[daemon] ⚠️  Then set BlackHole as your audio output in meeting apps")
        }
        // State machine
        enum State { case idle, detecting, recording }
        var state = State.idle
        var aboveStartSince: Date?
        var belowStopSince: Date?
        var currentRecording: Process?

        // Metering queue
        let meterQueue = DispatchQueue(label: "com.meetingrecorder.vad")

        // Install a lightweight tap for level monitoring only
        probeNode.installTap(onBus: 0, bufferSize: 512, format: probeFormat) { buffer, _ in
            let rms = computeRMS(buffer)
            let now = Date()

            meterQueue.async {
                switch state {
                case .idle:
                    if rms > startThreshold {
                        aboveStartSince = aboveStartSince ?? now
                        if now.timeIntervalSince(aboveStartSince!) >= startWindow {
                            state = .detecting
                            print("[daemon] Audio detected — starting capture...")
                            // Fork a recording subprocess
                            // Re-spawn ourselves as the capture subcommand
                            let myPath = CommandLine.arguments[0]
                            let proc = Process()
                            proc.executableURL = URL(fileURLWithPath: myPath)
                            let ts = DateFormatter.filename.string(from: now)
                            proc.arguments = [
                                "capture",
                                "--output", "\(outputDir)/\(ts).wav"
                            ]
                            try? proc.run()
                            currentRecording = proc
                            state = .recording
                            aboveStartSince = nil
                        }
                    } else {
                        aboveStartSince = nil
                    }

                case .detecting:
                    break // handled in idle→recording transition

                case .recording:
                    if rms < stopThreshold {
                        belowStopSince = belowStopSince ?? now
                        if now.timeIntervalSince(belowStopSince!) >= stopWindow {
                            print("[daemon] Silence for \(Int(stopWindow))s — stopping recording.")
                            currentRecording?.terminate()
                            currentRecording = nil
                            state = .idle
                            belowStopSince = nil
                        }
                    } else {
                        belowStopSince = nil
                    }
                }
            }
        }

        try probeEngine.start()
        dispatchMain()
    }
}

/// Compute RMS level in dBFS from an audio buffer.
func computeRMS(_ buffer: AVAudioPCMBuffer) -> Float {
    guard let channelData = buffer.floatChannelData else { return -160 }
    let frameLength = Int(buffer.frameLength)
    let channelCount = Int(buffer.format.channelCount)
    var sum: Float = 0
    for ch in 0..<channelCount {
        let samples = UnsafeBufferPointer(start: channelData[ch], count: frameLength)
        for sample in samples {
            sum += sample * sample
        }
    }
    let rms = sqrt(sum / Float(frameLength * channelCount))
    if rms < 1e-10 { return -160 }
    return 20 * log10(rms)
}

// MARK: - Merge (Speaker-Labeled Transcript)

struct MergeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "merge",
        abstract: "Combine transcript and diarization into speaker-labeled transcript"
    )

    @Option(name: .long, help: "Transcript markdown file (from transcribe)")
    var transcript: String

    @Option(name: .long, help: "Diarization JSON file (from diarize)")
    var speakers: String

    @Option(name: .long, help: "Output file (default: <transcript>.labeled.md)")
    var output: String?

    func run() throws {
        let transcriptPath = transcript
        let speakersPath = speakers
        let outputPath = output ?? transcriptPath.replacingOccurrences(of: ".md", with: ".labeled.md")

        guard let transcriptText = try? String(contentsOfFile: transcriptPath, encoding: .utf8) else {
            throw DiarizeError("Transcript not found: \(transcriptPath)")
        }
        guard let speakersData = try? Data(contentsOf: URL(fileURLWithPath: speakersPath)) else {
            throw DiarizeError("Speakers file not found: \(speakersPath)")
        }
        guard let segments = try? JSONDecoder().decode([SpeakerSegment].self, from: speakersData) else {
            throw DiarizeError("Invalid speakers JSON: \(speakersPath)")
        }

        // Merge: match each transcript line to a speaker by timestamp
        var result = "# Meeting Transcript\n\n"
        let lines = transcriptText.components(separatedBy: "\n")

        for line in lines {
            let timestamp = parseTimestampSeconds(from: line)
            if let ts = timestamp {
                let speaker = findSpeaker(at: ts, in: segments)
                let label = speaker.map { "**\($0)**" } ?? "**UNKNOWN**"
                let cleanLine = stripTimestamp(from: line)
                result += "\(label): \(cleanLine)\n"
            } else if line.hasPrefix("#") || line.isEmpty {
                result += line + "\n"
            }
        }

        // Append speaker summary
        let uniqueSpeakers = Set(segments.map(\.speaker)).sorted()
        result += "\n---\n## Speakers\n"
        for spk in uniqueSpeakers {
            let totalTime = segments.filter { $0.speaker == spk }.reduce(0.0) { $0 + ($1.end - $1.start) }
            let minutes = Int(totalTime / 60)
            let seconds = Int(totalTime) % 60
            result += "- **\(spk)** — \(minutes)m \(seconds)s\n"
        }

        try result.write(toFile: outputPath, atomically: true, encoding: .utf8)
        print("[merge] Speaker-labeled transcript → \(outputPath)")
        print("[merge] Speakers: \(uniqueSpeakers.joined(separator: ", "))")
    }
}

struct SpeakerSegment: Codable {
    let start: Double
    let end: Double
    let speaker: String
}

func findSpeaker(at timestamp: Double, in segments: [SpeakerSegment]) -> String? {
    segments.first { $0.start <= timestamp && timestamp < $0.end }?.speaker
}

func parseTimestampSeconds(from line: String) -> Double? {
    // Match [HH:MM:SS] or [MM:SS] or bare HH:MM:SS / MM:SS
    let patterns = [
        #"\[(\d{1,2}):(\d{2}):(\d{2})\]"#,
        #"\[(\d{1,2}):(\d{2})\]"#,
        #"(\d{1,2}):(\d{2}):(\d{2})"#,
    ]
    for pattern in patterns {
        if let match = line.range(of: pattern, options: .regularExpression) {
            let str = String(line[match]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            let parts = str.split(separator: ":")
            if parts.count == 3 {
                return (Double(parts[0]) ?? 0) * 3600 + (Double(parts[1]) ?? 0) * 60 + (Double(parts[2]) ?? 0)
            } else if parts.count == 2 {
                return (Double(parts[0]) ?? 0) * 60 + (Double(parts[1]) ?? 0)
            }
        }
    }
    return nil
}

func stripTimestamp(from line: String) -> String {
    let pattern = #"^\s*\[?\d{1,2}:\d{2}(:\d{2})?\]?\s*"#
    return line.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
}

// MARK: - CLI Entry Point

@main
struct MeetingRecorder: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "meeting-recorder",
        abstract: "macOS meeting recorder — capture, transcribe, extract",
        subcommands: [
            CaptureCommand.self,
            DaemonCommand.self,
            TranscribeCommand.self,
            DiarizeCommand.self,
            MergeCommand.self,
            ProcessCommand.self,
        ]
    )
}

// MARK: - Helpers

extension DateFormatter {
    static let filename: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f
    }()
}


// MARK: - Transcribe (Phase 2: Whisper.cpp Integration)

struct TranscribeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Transcribe a WAV file using Whisper.cpp"
    )

    @Option(name: .long, help: "Input WAV file to transcribe")
    var input: String

    @Option(name: .long, help: "Path to Whisper.cpp model file")
    var model: String?

    @Option(name: .long, help: "Language code (default: pl)")
    var language: String = "pl"

    func run() throws {
        let inputURL = URL(fileURLWithPath: input)
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            print("[transcribe] File not found: \(inputURL.path)")
            throw ExitCode.failure
        }

        // Find whisper-cli binary
        guard let binaryPath = findWhisperBinary() else {
            print("[transcribe] whisper-cli not found")
            print("[transcribe] Install: brew install whisper-cpp")
            throw ExitCode.failure
        }

        // Find or download model file
        let modelPath = model ?? defaultModelPath()
        if !FileManager.default.fileExists(atPath: modelPath) {
            let modelURL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin"
            print("[transcribe] Model not found. Downloading ggml-large-v3 (~3GB)...")
            print("[transcribe] → \(modelPath)")

            // Ensure directory exists
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: modelPath).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            // Download with curl progress bar
            let curl = Process()
            curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            curl.arguments = [
                "-L", "-C", "-",           // follow redirects, resume partial
                "-o", modelPath,
                "--progress-bar",
                modelURL,
            ]
            try curl.run()
            curl.waitUntilExit()

            guard curl.terminationStatus == 0,
                  FileManager.default.fileExists(atPath: modelPath) else {
                print("[transcribe] Download failed. Try manually:")
                print("[transcribe]   curl -L -o \(modelPath) \(modelURL)")
                throw ExitCode.failure
            }
            print("[transcribe] Model downloaded.")
        }

        // Run whisper-cli as subprocess
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = [
            "-f", inputURL.path,
            "-m", modelPath,
            "-l", language,
        ]

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        print("[transcribe] Transcribing \(inputURL.lastPathComponent)...")
        print("[transcribe] Model: \(modelPath)")

        try proc.run()
        proc.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()

        // Build markdown from whisper output
        let now = DateFormatter.filename.string(from: Date())
        var markdown = "# Transcript\n\n"
        markdown += "- **Source:** \(inputURL.lastPathComponent)\n"
        markdown += "- **Language:** \(language)\n"
        markdown += "- **Transcribed:** \(now)\n\n"
        markdown += "---\n\n"

        // Whisper.cpp prints timestamped segments to stdout
        let outStr = String(data: outData, encoding: .utf8) ?? ""
        var lines = outStr.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        // Fallback: check stderr if stdout is empty
        if lines.isEmpty {
            let errStr = String(data: errData, encoding: .utf8) ?? ""
            lines = errStr.components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                markdown += "\(trimmed)\n\n"
            }
        }

        // Write markdown alongside the WAV file
        let mdURL = inputURL.deletingPathExtension().appendingPathExtension("md")
        try markdown.write(to: mdURL, atomically: true, encoding: .utf8)

        print("[transcribe] Done — \(mdURL.path)")
    }
}

// MARK: - Whisper Helpers

/// Locate the whisper-cli binary on the system.
func findWhisperBinary() -> String? {
    let knownPaths = [
        "/opt/homebrew/bin/whisper-cli",
        "/usr/local/bin/whisper-cli",
    ]
    for path in knownPaths {
        if FileManager.default.fileExists(atPath: path) {
            return path
        }
    }
    // Fallback to `which whisper-cli`
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    proc.arguments = ["whisper-cli"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = Pipe()
    do {
        try proc.run()
        proc.waitUntilExit()
    } catch {
        return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let path = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
        return nil
    }
    return path
}

/// Default model path: ~/Library/Application Support/com.meetingrecorder/Models/ggml-large-v3.bin
func defaultModelPath() -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return "\(home)/Library/Application Support/com.meetingrecorder/Models/ggml-large-v3.bin"
}

// MARK: - Phase 3: Diarize (Speaker Attribution)

struct DiarizeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diarize",
        abstract: "Identify who spoke when in a meeting recording"
    )

    @Option(name: .long, help: "Path to WAV file")
    var input: String

    @Option(name: .long, help: "HuggingFace token for pyannote models (or set HF_TOKEN env)")
    var token: String?

    @Option(name: .long, help: "Expected number of speakers (0=auto-detect)")
    var numSpeakers: Int = 0

    @Option(name: .long, help: "Output JSON file (default: <input>.speakers.json)")
    var output: String?

    func run() throws {
        let inputURL = URL(fileURLWithPath: input)
        guard FileManager.default.fileExists(atPath: input) else {
            throw DiarizeError("Input file not found: \(input)")
        }

        let outputPath = output ?? inputURL.deletingPathExtension().path + ".speakers.json"
        let scriptPath = findDiarizeScript()

        let tokenArg = token ?? ProcessInfo.processInfo.environment["HF_TOKEN"]
        guard let hfToken = tokenArg else {
            print("[diarize] HF_TOKEN not set. Get a token: https://huggingface.co/settings/tokens")
            print("[diarize] Then: export HF_TOKEN=hf_...")
            print("[diarize] Or pass --token directly")
            throw DiarizeError("Missing HuggingFace token")
        }

        print("[diarize] Running pyannote diarization on \(input)...")
        print("[diarize] Speakers: \(numSpeakers > 0 ? String(numSpeakers) : "auto-detect")")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: scriptPath)
        proc.arguments = [
            "--input", input,
            "--token", hfToken,
            "--output", outputPath,
        ]
        if numSpeakers > 0 {
            proc.arguments!.append(contentsOf: ["--num-speakers", String(numSpeakers)])
        }

        let pipe = Pipe()
        proc.standardError = pipe

        try proc.run()
        proc.waitUntilExit()

        let errData = pipe.fileHandleForReading.readDataToEndOfFile()
        if let errStr = String(data: errData, encoding: .utf8), !errStr.isEmpty {
            print(errStr.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if proc.terminationStatus != 0 {
            throw DiarizeError("Diarization failed with exit code \(proc.terminationStatus)")
        }

        print("[diarize] Done → \(outputPath)")
    }
}

func findDiarizeScript() -> String {
    // Look for the script relative to the project root, then cwd
    let repoRoot = findRepoRoot()
    let candidates = [
        "\(repoRoot)/Scripts/diarize.py",
        "Scripts/diarize.py",
    ]
    for path in candidates {
        if FileManager.default.fileExists(atPath: path) {
            return path
        }
    }
    return "Scripts/diarize.py"
}

func findRepoRoot() -> String {
    // Walk up from cwd looking for .git
    var url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    while url.path != "/" {
        if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
            return url.path
        }
        url = url.deletingLastPathComponent()
    }
    return FileManager.default.currentDirectoryPath
}

struct DiarizeError: Error, CustomStringConvertible {
    let description: String
    init(_ msg: String) { self.description = msg }
}

// MARK: - Phase 3: Process (Transcript Post-Processing)

struct ProcessCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "process",
        abstract: "Extract requirements, action items, and decisions from a transcript"
    )

    @Option(name: .long, help: "Input transcript markdown file")
    var input: String

    @Option(name: .long, help: "Output markdown file for extracted information")
    var output: String

    func run() throws {
        let inputURL = URL(fileURLWithPath: input)
        let outputURL = URL(fileURLWithPath: output)

        guard let transcriptData = try? String(contentsOf: inputURL, encoding: .utf8) else {
            throw ProcessError.fileError("Cannot read input file: \(input)")
        }

        let lines = transcriptData.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var requirements: [(timestamp: String?, text: String)] = []
        var actions: [(timestamp: String?, text: String)] = []
        var decisions: [(timestamp: String?, text: String)] = []

        for line in lines {
            let (timestamp, body) = extractTimestamp(from: line)
            let lower = body.lowercased()

            // Requirements: explicit customer needs
            if lower.contains("musi") || lower.contains("potrzebuje")
                || lower.contains("wymagane") || lower.contains("trzeba")
                || lower.contains("zależy nam")
            {
                requirements.append((timestamp, body))
                continue
            }

            // Actions: commitments and assignments
            if lower.contains("zrobię") || lower.contains("zrobimy")
                || lower.contains("zadanie") || lower.contains("akcja")
                || body.contains("@")
            {
                actions.append((timestamp, body))
                continue
            }

            // Decisions: resolutions and agreements
            if lower.contains("decyzja") || lower.contains("ustaliliśmy")
                || lower.contains("zdecydowaliśmy") || lower.contains("postanowiliśmy")
            {
                decisions.append((timestamp, body))
            }
        }

        // Build output
        var outputContent = "# Meeting Notes\n\n"
        outputContent += "**Data źródłowa:** \(input)\n\n"

        // ── Wymagania ──────────────────────────────────────
        outputContent += "## Wymagania\n\n"
        if requirements.isEmpty {
            outputContent += "Nie znaleziono.\n\n"
        } else {
            outputContent += "| Lp. | Wymaganie | Czas w nagraniu |\n"
            outputContent += "|-----|-----------|----------------|\n"
            for (i, req) in requirements.enumerated() {
                outputContent += "| \(i + 1) | \(req.text) | \(req.timestamp ?? "-") |\n"
            }
            outputContent += "\n"
        }

        // ── Akcje ──────────────────────────────────────────
        outputContent += "## Akcje\n\n"
        if actions.isEmpty {
            outputContent += "Nie znaleziono.\n\n"
        } else {
            outputContent += "| Lp. | Akcja | Osoba | Czas w nagraniu |\n"
            outputContent += "|-----|------|-------|----------------|\n"
            for (i, action) in actions.enumerated() {
                let responsible = extractResponsible(from: action.text)
                outputContent += "| \(i + 1) | \(action.text) | \(responsible) | \(action.timestamp ?? "-") |\n"
            }
            outputContent += "\n"
        }

        // ── Decyzje ────────────────────────────────────────
        outputContent += "## Decyzje\n\n"
        if decisions.isEmpty {
            outputContent += "Nie znaleziono.\n\n"
        } else {
            outputContent += "| Lp. | Decyzja | Czas w nagraniu |\n"
            outputContent += "|-----|---------|----------------|\n"
            for (i, dec) in decisions.enumerated() {
                outputContent += "| \(i + 1) | \(dec.text) | \(dec.timestamp ?? "-") |\n"
            }
            outputContent += "\n"
        }

        // Write output
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try outputContent.write(to: outputURL, atomically: true, encoding: .utf8)
        print("[process] Written to \(output)")
    }
}

// MARK: - Process Helpers

/// Extracts an optional timestamp marker from the start of a line.
/// Supports formats: `[HH:MM:SS]` or bare `HH:MM:SS` / `MM:SS`.
func extractTimestamp(from line: String) -> (String?, String) {
    let trimmed = line.trimmingCharacters(in: .whitespaces)

    // Check for [HH:MM:SS] or [MM:SS] at start
    if trimmed.hasPrefix("["), let closeBracket = trimmed.firstIndex(of: "]") {
        let ts = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closeBracket])
        let colonCount = ts.filter { $0 == ":" }.count
        if colonCount == 1 || colonCount == 2 {
            let rest = String(trimmed[trimmed.index(after: closeBracket)...]).trimmingCharacters(in: .whitespaces)
            return (ts, rest)
        }
    }

    // Check for bare HH:MM:SS or MM:SS at start
    let parts = trimmed.components(separatedBy: .whitespaces)
    if let first = parts.first {
        let colonCount = first.filter { $0 == ":" }.count
        if colonCount == 1 || colonCount == 2 {
            let rest = parts.dropFirst().joined(separator: " ")
            return (first, rest)
        }
    }

    return (nil, trimmed)
}

/// Extracts responsible person(s) from a transcript line.
/// Returns the speaker (text before first colon) with any @mentions appended.
func extractResponsible(from line: String) -> String {
    var parts: [String] = []

    // Extract speaker from before first colon
    if let colonRange = line.range(of: ":") {
        let speaker = line[line.startIndex..<colonRange.lowerBound].trimmingCharacters(in: .whitespaces)
        if !speaker.isEmpty {
            parts.append(speaker)
        }
    }

    // Find @mentions
    let words = line.components(separatedBy: .whitespaces)
    let mentions = words.filter { $0.hasPrefix("@") }
    for mention in mentions {
        let cleaned = mention.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
        if !cleaned.isEmpty && !parts.contains(cleaned) {
            parts.append(cleaned)
        }
    }

    return parts.isEmpty ? "-" : parts.joined(separator: ", ")
}

// MARK: - Process Error

enum ProcessError: Error {
    case fileError(String)
}
