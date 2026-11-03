import CoreAudio

/// The processes Core Audio knows about, read without any permission.
public enum AudioProcesses {
    /// Bundle ids of the processes recording from an input device right now.
    public static func micUsers() -> Set<String> {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = propertyAddress(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return [] }
        return Set(processes.filter(isRunningInput).compactMap(bundleID))
    }

    private static func isRunningInput(_ process: AudioObjectID) -> Bool {
        var address = propertyAddress(kAudioProcessPropertyIsRunningInput)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(process, &address, 0, nil, &size, &running) == noErr && running != 0
    }

    private static func bundleID(_ process: AudioObjectID) -> String? {
        var address = propertyAddress(kAudioProcessPropertyBundleID)
        var bundleID: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &bundleID) == noErr, let bundleID else { return nil }
        let id = bundleID.takeRetainedValue() as String
        return id.isEmpty ? nil : id
    }

    private static func propertyAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
}
