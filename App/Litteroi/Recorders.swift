import AVFoundation
import CoreAudio
import LitteroiCore
import ScreenCaptureKit

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
/// without it the track stays silent and the meeting is treated as one without a call. The IO
/// proc delivers the tap at the rate of the aggregate device, which follows the output device's,
/// not at the rate the tap reports: AirPods in their call profile run at 24 kHz while the tap
/// still reports 48 kHz, and a Signal call read at the tap's rate played at double speed. The
/// rate changes again when the headset switches back to music as the call lets go of the mic.
final class SystemAudioRecorder {
    let writer: TrackWriter
    private let queue = DispatchQueue(label: "fi.taitounited.litteroi.system-audio", qos: .userInitiated)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    /// Read and written on `queue` only, by the IO proc and the format listeners.
    private var format: AVAudioFormat?
    private var formatListener: AudioObjectPropertyListenerBlock?

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

        format = try ioFormat()
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, let format = try? self.ioFormat() else { return }
            self.format = format
        }
        var tapFormat = CoreAudio.tapFormatAddress
        try CoreAudio.check(AudioObjectAddPropertyListenerBlock(tapID, &tapFormat, queue, listener), "AddPropertyListener")
        var sampleRate = CoreAudio.nominalSampleRateAddress
        try CoreAudio.check(AudioObjectAddPropertyListenerBlock(aggregateID, &sampleRate, queue, listener), "AddPropertyListener")
        formatListener = listener

        try CoreAudio.check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            guard let self, let format = self.format else { return }
            try? self.writer.append(input, format: format)
        }, "AudioDeviceCreateIOProcIDWithBlock")
        try CoreAudio.check(AudioDeviceStart(aggregateID, procID), "AudioDeviceStart")
    }

    private func ioFormat() throws -> AVAudioFormat {
        let tap = try CoreAudio.tapFormat(tapID)
        let sampleRate = try CoreAudio.nominalSampleRate(aggregateID)
        guard let format = TrackWriter.ioFormat(tap: tap, deviceSampleRate: sampleRate) else { throw RecorderError.unsupportedFormat }
        return format
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID {
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            if let formatListener {
                var sampleRate = CoreAudio.nominalSampleRateAddress
                AudioObjectRemovePropertyListenerBlock(aggregateID, &sampleRate, queue, formatListener)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            if let formatListener {
                var formatAddress = CoreAudio.tapFormatAddress
                AudioObjectRemovePropertyListenerBlock(tapID, &formatAddress, queue, formatListener)
            }
            AudioHardwareDestroyProcessTap(tapID)
        }
        queue.sync { writer.close() }
    }
}

/// Records every display into the meeting folder, one video each from `second` of the meeting on,
/// so what was shown in a meeting can be looked up later. Needs the screen recording permission.
@MainActor
final class ScreenRecorder {
    private var displays: [DisplayRecorder] = []
    private var stopped = false

    func start(in folder: MeetingFolder, at second: Int) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        for (index, display) in content.displays.enumerated() where !stopped {
            var start = second
            while FileManager.default.fileExists(atPath: folder.screen(index + 1, from: start).path) {
                start += 1
            }
            let recorder = try DisplayRecorder(display: display, url: folder.screen(index + 1, from: start))
            try await recorder.start()
            displays.append(recorder)
        }
    }

    func stop() async {
        stopped = true
        for display in displays {
            await display.stop()
        }
        displays = []
    }
}

/// H.265 at up to 2 frames a second and at most 1920 points wide, enough for slides and shared
/// documents. ScreenCaptureKit sends a frame only when the screen changes.
private final class DisplayRecorder: NSObject, SCStreamOutput {
    private let url: URL
    private let stream: SCStream
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let queue = DispatchQueue(label: "fi.taitounited.litteroi.screen", qos: .utility)
    private var lastFrame: CMTime?
    private var stopped = false

    init(display: SCDisplay, url: URL) throws {
        let configuration = SCStreamConfiguration()
        let width = min(display.width, 1920)
        configuration.width = width / 2 * 2
        configuration.height = display.height * width / display.width / 2 * 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 2)
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.showsCursor = true
        self.url = url
        stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration, delegate: nil)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: configuration.width,
            AVVideoHeightKey: configuration.height,
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        super.init()
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
    }

    func start() async throws {
        try await stream.startCapture()
    }

    /// The last frame lasts until the recording stops, however long the screen stayed still.
    func stop() async {
        try? await stream.stopCapture()
        let lastFrame = queue.sync { () -> CMTime? in
            stopped = true
            return self.lastFrame
        }
        guard let lastFrame else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            return
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTimeMaximum(lastFrame, CMClockGetTime(CMClockGetHostTimeClock())))
        await writer.finishWriting()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !stopped, sampleBuffer.isValid, Self.isFrame(sampleBuffer) else { return }
        if lastFrame == nil {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
        }
        if input.isReadyForMoreMediaData, input.append(sampleBuffer) {
            lastFrame = sampleBuffer.presentationTimeStamp
        }
    }

    /// ScreenCaptureKit also sends buffers without an image while the screen stays still.
    private static func isFrame(_ buffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int
        else { return false }
        return status == SCFrameStatus.complete.rawValue
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

    static let tapFormatAddress = AudioObjectPropertyAddress(
        mSelector: kAudioTapPropertyFormat,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    static func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = tapFormatAddress
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format), "kAudioTapPropertyFormat")
        return format
    }

    static let nominalSampleRateAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    static func nominalSampleRate(_ device: AudioObjectID) throws -> Double {
        var address = nominalSampleRateAddress
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate), "kAudioDevicePropertyNominalSampleRate")
        return rate
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
