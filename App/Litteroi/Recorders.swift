import AVFoundation
import CoreAudio
import LitteroiCore

/// Records the default microphone. A device change, such as headphones being plugged in,
/// restarts the engine with the new format.
final class MicRecorder {
    let writer: TrackWriter
    private let engine = AVAudioEngine()
    private var configurationObserver: NSObjectProtocol?

    init(url: URL) throws {
        writer = try TrackWriter(url: url)
    }

    func start() throws {
        try installTapAndStart()
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            try? self?.installTapAndStart()
        }
    }

    func stop() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        writer.close()
    }

    private func installTapAndStart() throws {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noMicrophone }
        let writer = writer
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            try? writer.append(buffer)
        }
        engine.prepare()
        try engine.start()
    }
}

/// Records what the Mac plays, which on a call is the other participants, through a Core Audio
/// process tap on every process but Litteroi. Needs the system audio recording permission;
/// without it the track stays silent and the meeting is treated as one without a call.
final class SystemAudioRecorder {
    let writer: TrackWriter
    private let queue = DispatchQueue(label: "fi.taitounited.litteroi.system-audio", qos: .userInitiated)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    init(url: URL) throws {
        writer = try TrackWriter(url: url)
    }

    func start() throws {
        let ownProcess = try? CoreAudio.processObject(for: getpid())
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: ownProcess.map { [$0] } ?? [])
        description.uuid = UUID()
        description.name = "Litteroi"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try CoreAudio.check(AudioHardwareCreateProcessTap(description, &tapID), "AudioHardwareCreateProcessTap")

        var streamFormat = try CoreAudio.tapFormat(tapID)
        guard let format = AVAudioFormat(streamDescription: &streamFormat) else { throw RecorderError.unsupportedFormat }

        let outputUID = try CoreAudio.defaultOutputDeviceUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Litteroi",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try CoreAudio.check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "AudioHardwareCreateAggregateDevice")

        let writer = writer
        try CoreAudio.check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
            try? writer.append(buffer)
        }, "AudioDeviceCreateIOProcIDWithBlock")
        try CoreAudio.check(AudioDeviceStart(aggregateID, procID), "AudioDeviceStart")
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID {
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        queue.sync { writer.close() }
    }
}

enum RecorderError: LocalizedError {
    case noMicrophone
    case unsupportedFormat
    case coreAudio(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .noMicrophone: "Mikrofonia ei löytynyt."
        case .unsupportedFormat: "Järjestelmän äänen muotoa ei tueta."
        case .coreAudio(let call, let status): "\(call) epäonnistui (\(status))."
        }
    }
}

private enum CoreAudio {
    static func check(_ status: OSStatus, _ call: String) throws {
        guard status == noErr else { throw RecorderError.coreAudio(call, status) }
    }

    static func processObject(for pid: pid_t) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object),
            "TranslatePIDToProcessObject"
        )
        return object
    }

    static func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format), "kAudioTapPropertyFormat")
        return format
    }

    static func defaultOutputDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device),
            "DefaultSystemOutputDevice"
        )

        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid), "kAudioDevicePropertyDeviceUID")
        guard let uid else { throw RecorderError.coreAudio("kAudioDevicePropertyDeviceUID", -1) }
        return uid.takeRetainedValue() as String
    }
}
