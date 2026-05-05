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

        // Record stereo: mic → left channel, system audio → right channel
        try record(
            setup: setup,
            duration: Double(duration),
            outputURL: outputURL
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

/// Records from two audio devices simultaneously into a stereo WAV.
/// Left channel = microphone (local speaker). Right channel = system audio (remote speaker).
/// Falls back to single-source if BlackHole is unavailable.
func record(setup: CaptureSetup, duration: TimeInterval, outputURL: URL) throws {
    let targetSampleRate: Double = 16_000

    // Create output format: 16kHz, 16-bit PCM, interleaved stereo
    guard let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: targetSampleRate,
        channels: 2,
        interleaved: true
    ) else {
        throw CaptureError.audioDeviceError("Failed to create output format")
    }

    // Prepare WAV file
    let wavHeader = WAVHeader(sampleRate: Int(targetSampleRate), channels: 2, bitsPerSample: 16)
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
    var totalFramesWritten: UInt64 = 0
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
        bufferQueue.async { writeInterleaved(mono: mono, channel: .left, fileQueue: fileQueue) }
    }

    // ── SYSTEM AUDIO TAP ────────────────────────────────────
    if let sysEng = sysEngine {
        let sysFormat = sysEng.inputNode.outputFormat(forBus: 0)
        print("[capture] System audio format: \(Int(sysFormat.sampleRate))Hz \(sysFormat.channelCount)ch")
        sysEng.inputNode.installTap(onBus: 0, bufferSize: 1024, format: sysFormat) { buffer, _ in
            let elapsed = Date().timeIntervalSince(startTime)
            guard elapsed < duration else { return }
            guard let mono = convertToMonoInt16(buffer, inputFormat: sysFormat, targetSampleRate: targetSampleRate) else { return }
            bufferQueue.async { writeInterleaved(mono: mono, channel: .right, fileQueue: fileQueue) }
        }
    }

    func writeInterleaved(mono: Data, channel: Channel, fileQueue: DispatchQueue) {
        // Interleave into stereo: left=mic, right=system
        let frameCount = mono.count / MemoryLayout<Int16>.size
        var interleaved = Data(capacity: frameCount * 2 * MemoryLayout<Int16>.size)
        let samples = mono.withUnsafeBytes { $0.bindMemory(to: Int16.self) }
        for i in 0..<frameCount {
            var left: Int16 = 0
            var right: Int16 = 0
            if channel == .left {
                left = samples[i]
            } else {
                right = samples[i]
            }
            interleaved.append(contentsOf: withUnsafeBytes(of: left) { Data($0) })
            interleaved.append(contentsOf: withUnsafeBytes(of: right) { Data($0) })
        }
        fileQueue.async {
            try? appendHandle.write(contentsOf: interleaved)
            totalDataBytes += UInt32(interleaved.count)
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

// MARK: - CLI Entry Point

@main
struct MeetingRecorder: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "meeting-recorder",
        abstract: "macOS meeting recorder — capture, transcribe, extract",
        subcommands: [CaptureCommand.self]
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
