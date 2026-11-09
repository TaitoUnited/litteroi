import CoreGraphics

extension MeetingFolder.RecordingMode {
    /// A recording takes the screens too while the Mac's own display is the only one on, and only
    /// the audio while an external display is connected.
    public static var forDisplays: Self {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return .audio }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return .audio }
        return displays.prefix(Int(count)).allSatisfy { CGDisplayIsBuiltin($0) != 0 } ? .audioAndVideo : .audio
    }
}
