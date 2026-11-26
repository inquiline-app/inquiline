import CoreAudio
import Foundation

/// Keeps Android's pictures and sound together as the Mac shows and plays them. Android's video
/// players time each picture by where its sound driver says the sound is (AudioTrack's
/// timestamps), as on a phone, but here a picture travels further than its sound before it's
/// seen: from Android to the Mac's window, then to the screen. So the driver is told how much
/// sooner the sound is heard than the picture is seen, and holds the sound back that much
/// (Vendor/audio, vendor.inquiline.audio.lead_ms), as a TV does for its picture; players, which
/// time pictures by the driver's clock, and games alike are then heard with what they show. The picture's last stretch comes from Metal (when each frame was actually shown),
/// the sound's from Core Audio (the output device's latency, as Chromium's Mac audio reads it),
/// so a new display or speakers are followed by themselves.
final class PictureSoundSync {
    static let shared = PictureSoundSync()


    private let lock = NSLock()
    private var shown = 0.0
    private var samples = 0
    private var lastSet: Int?
    private var lastCheck = 0.0

    /// A frame was on the Mac's screen this long after Android composed it.
    func framePresented(after seconds: Double) {
        guard seconds > 0, seconds < 0.5 else { return }
        lock.lock()
        // A moving average over about a second of frames.
        shown = samples == 0 ? seconds : shown * 0.95 + seconds * 0.05
        samples += 1
        let now = ProcessInfo.processInfo.systemUptime
        let due = samples >= 30 && now - lastCheck > 5
        if due { lastCheck = now }
        let picture = shown
        lock.unlock()
        if due { DispatchQueue.global(qos: .utility).async { self.update(picture: picture) } }
    }

    private func update(picture: Double) {
        // The sound's way from the engine to the speakers: the engine's own wait, measured by
        // the engine, and the device's; its way inside Android, the sound driver measures itself.
        let engine = EngineControl.soundDelay ?? 0
        let speakers = Self.soundLatency()
        let lead = Int(((picture - speakers - engine) * 1000).rounded())
        let ms = min(max(lead, 0), 200)
        lock.lock()
        let changed = lastSet.map { abs($0 - ms) >= 3 } ?? true
        if changed { lastSet = ms }
        lock.unlock()
        guard changed else { return }
        AndroidRuntime.shared.setSoundLead(ms: ms)
        AppLog.write(String(format: "Picture and sound: the sound waits %d ms (picture %.0f ms, engine %.0f ms, speakers %.0f ms)", ms, picture * 1000, engine * 1000, speakers * 1000))
    }

    /// The default output device's latency, in seconds: the device's, its stream's, its safety
    /// offset and its buffer, as Core Audio reports them.
    static func soundLatency() -> Double {
        func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope, _ empty: T) -> T {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var result = empty
            var size = UInt32(MemoryLayout<T>.size)
            return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr ? result : empty
        }
        let output = kAudioDevicePropertyScopeOutput, global = kAudioObjectPropertyScopeGlobal
        let device = value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, global, AudioObjectID(0))
        guard device != 0 else { return 0 }
        let rate = value(device, kAudioDevicePropertyNominalSampleRate, global, Float64(0))
        guard rate > 0 else { return 0 }
        var frames = value(device, kAudioDevicePropertyLatency, output, UInt32(0))
            + value(device, kAudioDevicePropertySafetyOffset, output, UInt32(0))
            + value(device, kAudioDevicePropertyBufferFrameSize, global, UInt32(0))
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: output, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        if AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size >= 4 {
            var streams = [AudioStreamID](repeating: 0, count: Int(size) / 4)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &streams) == noErr {
                frames += value(streams[0], kAudioStreamPropertyLatency, global, UInt32(0))
            }
        }
        return Double(frames) / rate
    }
}
