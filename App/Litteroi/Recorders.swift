import AVFoundation
import CoreAudio
import LitteroiCore
import os
import ScreenCaptureKit

/// Records the default microphone. A configuration change, such as headphones being plugged in or
/// a call app opening the mic at another rate, stops AVAudioEngine, and the engine keeps the old
/// rate: on 18.11.2026 a tap installed again on it was refused with "Failed to create tap, config
/// change pending!" in the log alone, and the engine ran on without a tap until the meeting ended.
/// So each change gets a new engine, a mic that gives no sound for `stallLimit` seconds gets one
/// too, and the gap is filled with silence, so the track keeps the meeting's time.
final class MicRecorder: @unchecked Sendable {
    let writer: TrackWriter
    private static let stallLimit: TimeInterval = 2
    private static let retryInterval: TimeInterval = 3
    /// Used on the main thread only, as are the watchdog's fields below.
    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?
    private var watchdog: Timer?
    private var lastAttempt: TimeInterval = 0
    private var silentSince: TimeInterval?
    private var loggedFailure = false
    private var startHostTime: UInt64 = 0
    /// The tap and the watchdog both write to the track.
    private let writing = NSLock()
    /// The second of the track the latest buffer ends at.
    private let heard = OSAllocatedUnfairLock<TimeInterval>(initialState: 0)

    init(url: URL) throws {
        writer = try TrackWriter(url: url)
    }

    func start() throws {
        startHostTime = mach_absolute_time()
        try startEngine()
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let engine = self.engine, (notification.object as AnyObject) === engine else { return }
            do {
                try self.restartEngine()
                let format = self.engine?.inputNode.outputFormat(forBus: 0)
                NSLog("Litteroi: mic restarted after a configuration change, \(format?.sampleRate ?? 0) Hz, \(format?.channelCount ?? 0) channels")
            } catch {
                NSLog("Litteroi: mic did not restart after a configuration change: \(error.localizedDescription)")
            }
        }
        let watchdog = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.checkSound() }
        RunLoop.main.add(watchdog, forMode: .common)
        self.watchdog = watchdog
    }

    func stop() {
        watchdog?.invalidate()
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        stopEngine()
        let end = now
        writing.withLock {
            try? writer.padSilence(until: end)
            writer.close()
        }
    }

    /// Seconds since the recording started, on the clock the tap stamps its buffers with.
    private var now: TimeInterval { second(atHostTime: mach_absolute_time()) }

    private func second(atHostTime hostTime: UInt64) -> TimeInterval {
        AVAudioTime.seconds(forHostTime: hostTime) - AVAudioTime.seconds(forHostTime: startHostTime)
    }

    private func startEngine() throws {
        lastAttempt = now
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noMicrophone }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
            self?.received(buffer, at: time)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    private func stopEngine() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    private func restartEngine() throws {
        stopEngine()
        try startEngine()
    }

    private func received(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        let length = TimeInterval(buffer.frameLength) / buffer.format.sampleRate
        let start = time.isHostTimeValid ? second(atHostTime: time.hostTime) : now - length
        writing.withLock { try? writer.append(buffer, at: start) }
        heard.withLock { $0 = start + length }
    }

    /// Runs every second. While the mic gives no sound, the track keeps up with the meeting, so the
    /// live text and a crash find it in time, and a new engine is tried every `retryInterval`.
    private func checkSound() {
        let now = self.now
        let heard = self.heard.withLock { $0 }
        guard now - heard > Self.stallLimit else {
            if let silentSince {
                NSLog("Litteroi: mic back after \(Int(now - silentSince)) s without sound, filled with silence")
                self.silentSince = nil
            }
            return
        }
        if silentSince == nil {
            silentSince = heard
            loggedFailure = false
            NSLog("Litteroi: mic gave no sound for \(Int(now - heard)) s, restarting it")
        }
        writing.withLock { try? writer.padSilence(until: now - 1) }
        guard now - lastAttempt >= Self.retryInterval else { return }
        do {
            try restartEngine()
        } catch {
            if !loggedFailure {
                NSLog("Litteroi: mic did not restart: \(error.localizedDescription)")
            }
            loggedFailure = true
        }
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
    private let stream: SCStream
    private let writer: ScreenWriter
    private let queue = DispatchQueue(label: "fi.taitounited.litteroi.screen", qos: .utility)
    private let repeater: DispatchSourceTimer
    private var stopped = false

    init(display: SCDisplay, url: URL) throws {
        let configuration = SCStreamConfiguration()
        let width = min(display.width, 1920)
        configuration.width = width / 2 * 2
        configuration.height = display.height * width / display.width / 2 * 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 2)
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.showsCursor = true
        stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration, delegate: nil)
        writer = try ScreenWriter(url: url, width: configuration.width, height: configuration.height)
        repeater = DispatchSource.makeTimerSource(queue: queue)
        super.init()
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        repeater.schedule(deadline: .now() + 1, repeating: 1)
        repeater.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            self.writer.repeatLast(at: CMClockGetTime(CMClockGetHostTimeClock()))
        }
        repeater.resume()
    }

    func start() async throws {
        try await stream.startCapture()
    }

    func stop() async {
        try? await stream.stopCapture()
        queue.sync {
            stopped = true
            repeater.cancel()
        }
        await writer.finish(at: CMClockGetTime(CMClockGetHostTimeClock()))
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !stopped, sampleBuffer.isValid, Self.isFrame(sampleBuffer),
              let image = sampleBuffer.imageBuffer
        else { return }
        writer.append(image, at: sampleBuffer.presentationTimeStamp)
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
