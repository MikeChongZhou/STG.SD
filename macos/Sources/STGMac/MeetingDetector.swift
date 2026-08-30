import AppKit
import CoreAudio

struct MeetingDetectionResult {
    var isInMeeting: Bool
    var reason: String
}

enum MeetingDetector {
    static func detect() -> MeetingDetectionResult {
        let runningNames = NSWorkspace.shared.runningApplications.compactMap {
            [$0.localizedName, $0.bundleIdentifier].compactMap { $0?.lowercased() }.joined(separator: " ")
        }
        let meetingKeywords = ["teams", "msteams", "zoom", "feishu", "lark", "wemeet", "tencent meeting", "dingtalk", "webex", "meet"]
        let matchingApp = runningNames.first { name in meetingKeywords.contains { name.contains($0) } }
        let microphoneActive = defaultInputDeviceIsRunning()

        if microphoneActive, let matchingApp {
            return .init(isInMeeting: true, reason: "microphone active; meeting app=\(matchingApp)")
        }
        if microphoneActive {
            return .init(isInMeeting: true, reason: "default microphone is active")
        }
        return .init(isInMeeting: false, reason: matchingApp == nil ? "no active microphone or meeting app" : "meeting app is running but microphone is inactive")
    }

    private static func defaultInputDeviceIsRunning() -> Bool {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else { return false }

        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &running) == noErr && running != 0
    }
}
