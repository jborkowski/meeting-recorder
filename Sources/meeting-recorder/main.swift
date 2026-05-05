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

        // Try to find or create an aggregate device that captures both
        // system output (BlackHole/Loopback) and microphone
        let captureDevice = try findOrCreateCaptureDevice(from: devices)
        print("[capture] Using capture device: \(captureDevice.name)")

        // Record
        try record(
            device: captureDevice,
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

func findOrCreateCaptureDevice(from devices: [AudioDevice]) throws -> AudioDevice {
    // Strategy 1: Look for BlackHole (virtual audio device)
    if let blackhole = devices.first(where: {
        $0.name.localizedCaseInsensitiveContains("blackhole")
    }) {
        print("[capture] Found BlackHole device: \(blackhole.name)")
        return blackhole
    }

    // Strategy 2: Look for a device with both input + output (aggregate capable)
    if let multiDevice = devices.first(where: { $0.isInput && $0.isOutput }) {
        print("[capture] Using multi-channel device: \(multiDevice.name)")
        return multiDevice
    }

    // Strategy 3: Fall back to default input device
    if let defaultInput = devices.first(where: { $0.isInput }) {
        print("[capture] ⚠️  Falling back to default input: \(defaultInput.name)")
        print("[capture] ⚠️  System audio capture requires BlackHole or similar virtual device.")
        print("[capture] ⚠️  Install: brew install blackhole-16ch")
        return defaultInput
    }

    throw CaptureError.audioDeviceError(
        "No suitable audio device found. Install BlackHole: brew install blackhole-16ch"
    )
}

// MARK: - Recording

func record(device: AudioDevice, duration: TimeInterval, outputURL: URL) throws {
    let engine = AVAudioEngine()
    let inputNode = engine.inputNode

    // Use the device's native sample rate or default to 16kHz for Whisper
    let targetSampleRate: Double = 16_000

    // Install a tap on the input node
    let format = inputNode.outputFormat(forBus: 0)
    print("[capture] Input format: \(format.sampleRate) Hz, \(format.channelCount) channels")

    // Create output format: 16kHz, 16-bit PCM, stereo
    guard let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: targetSampleRate,
        channels: 2,
        interleaved: true
    ) else {
        throw CaptureError.audioDeviceError("Failed to create output format")
    }

    // Use a converter if input format doesn't match target
    let needsConversion = format.sampleRate != targetSampleRate || format.channelCount != 2

    // Prepare WAV file with placeholder header
    let wavHeader = WAVHeader(sampleRate: Int(targetSampleRate), channels: 2, bitsPerSample: 16)

    // Ensure output directory exists
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )

    // Create file and write placeholder WAV header
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    guard let appendHandle = try? FileHandle(forWritingTo: outputURL) else {
        throw CaptureError.fileError("Cannot create output file: \(outputURL.path)")
    }
    var header = wavHeader
    let headerData = Data(bytes: &header, count: MemoryLayout<WAVHeader>.size)
    appendHandle.write(headerData)

    // Seek past header
    try appendHandle.seek(toOffset: UInt64(MemoryLayout<WAVHeader>.size))

    var totalDataBytes: UInt32 = 0
    let startTime = Date()

    print("[capture] Recording \(Int(duration))s...")

    // For Phase 0, we record from default input as a proof of concept.
    // Full system audio capture requires aggregate device setup (Phase 1).
    if needsConversion {
        // Install tap with converter
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            guard Date().timeIntervalSince(startTime) < duration else { return }

            // Convert to target format
            guard let converter = AVAudioConverter(from: format, to: outputFormat) else { return }

            let targetCapacity = AVAudioFrameCount(
                Double(buffer.frameLength) * (targetSampleRate / format.sampleRate)
            )
            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: targetCapacity
            ) else { return }

            var error: NSError?
            let inputBlock: AVAudioConverterInputBlock = { _, inStatus in
                inStatus.pointee = .haveData
                return buffer
            }

            converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)

            if let error = error {
                print("[capture] Conversion error: \(error)")
                return
            }

            // Write PCM data
            if let channelData = convertedBuffer.int16ChannelData {
                let frameLength = Int(convertedBuffer.frameLength)
                let data = Data(
                    bytes: channelData[0],
                    count: frameLength * MemoryLayout<Int16>.size * Int(outputFormat.channelCount)
                )
                try? appendHandle.write(contentsOf: data)
                totalDataBytes += UInt32(data.count)
            }
        }
    } else {
        // Direct tap without conversion
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            guard Date().timeIntervalSince(startTime) < duration else { return }

            if let channelData = buffer.int16ChannelData {
                let frameLength = Int(buffer.frameLength)
                let data = Data(
                    bytes: channelData[0],
                    count: frameLength * MemoryLayout<Int16>.size * Int(buffer.format.channelCount)
                )
                try? appendHandle.write(contentsOf: data)
                totalDataBytes += UInt32(data.count)
            }
        }
    }

    // Start engine
    try engine.start()

    // Wait for duration
    Thread.sleep(forTimeInterval: duration)

    // Stop
    engine.stop()
    engine.inputNode.removeTap(onBus: 0)

    // Update WAV header with actual data size
    try appendHandle.close()

    if let updateHandle = try? FileHandle(forWritingTo: outputURL) {
        var header = wavHeader
        header.dataSubchunkSize = totalDataBytes
        header.riffChunkSize = 36 + totalDataBytes
        let headerData = Data(bytes: &header, count: MemoryLayout<WAVHeader>.size)
        try updateHandle.seek(toOffset: 0)
        updateHandle.write(headerData)
        try updateHandle.close()
    }

    let actualDuration = Date().timeIntervalSince(startTime)
    print("[capture] Recorded \(totalDataBytes) bytes in \(String(format: "%.1f", actualDuration))s")
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
