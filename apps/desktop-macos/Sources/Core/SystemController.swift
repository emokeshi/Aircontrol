import Foundation
import AppKit
import CoreAudio
import AudioToolbox
import Darwin

public final class SystemController {
    public static let shared = SystemController()

    private init() {}

    // MARK: - CoreAudio Volume Control

    public func getMasterVolume() -> Float {
        var deviceID = AudioDeviceID(0)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr else {
            return 0.5
        }

        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var volume: Float32 = 0.0
        var volumeSize = UInt32(MemoryLayout<Float32>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &volumeAddress,
            0,
            nil,
            &volumeSize,
            &volume
        )

        return status == noErr ? volume : 0.5
    }

    public func setMasterVolume(_ level: Float) {
        var deviceID = AudioDeviceID(0)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr else { return }

        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var clampedVolume = max(0.0, min(1.0, level))
        let volumeSize = UInt32(MemoryLayout<Float32>.size)

        AudioObjectSetPropertyData(
            deviceID,
            &volumeAddress,
            0,
            nil,
            volumeSize,
            &clampedVolume
        )
    }

    public func toggleMute() {
        var deviceID = AudioDeviceID(0)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr else { return }

        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var isMuted: UInt32 = 0
        var muteSize = UInt32(MemoryLayout<UInt32>.size)

        if AudioObjectGetPropertyData(deviceID, &muteAddress, 0, nil, &muteSize, &isMuted) == noErr {
            var newMute: UInt32 = (isMuted == 0) ? 1 : 0
            AudioObjectSetPropertyData(deviceID, &muteAddress, 0, nil, muteSize, &newMute)
        }
    }

    // MARK: - Media Keys (Play, Pause, Track Skip)

    public func postSystemMediaKey(keyType: Int32) {
        func postEvent(down: Bool) {
            let flags: NSEvent.ModifierFlags = down ? NSEvent.ModifierFlags(rawValue: 0xa00) : []
            let data1 = (Int(keyType) << 16) | ((down ? 0xa : 0xb) << 8)
            let ev = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            )
            if let cgEv = ev?.cgEvent {
                cgEv.post(tap: .cgSessionEventTap)
            }
        }

        postEvent(down: true)
        postEvent(down: false)
    }

    // NX_KEYTYPE_PLAY = 16, NX_KEYTYPE_NEXT = 17, NX_KEYTYPE_PREVIOUS = 18
    public func mediaPlayPause() {
        postSystemMediaKey(keyType: 16)
    }

    public func mediaNext() {
        postSystemMediaKey(keyType: 17)
    }

    public func mediaPrevious() {
        postSystemMediaKey(keyType: 18)
    }

    // MARK: - Dock & Applications

    public struct AppSummary: Codable {
        public let bundleId: String
        public let name: String
        public let isActive: Bool
        public let iconBase64: String?

        public init(bundleId: String, name: String, isActive: Bool, iconBase64: String?) {
            self.bundleId = bundleId
            self.name = name
            self.isActive = isActive
            self.iconBase64 = iconBase64
        }
    }

    public func getRunningApplications() -> [AppSummary] {
        let ws = NSWorkspace.shared
        let activeApp = ws.frontmostApplication

        return ws.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let bundleId = app.bundleIdentifier,
                      let name = app.localizedName else { return nil }

                var iconString: String? = nil
                if let icon = app.icon {
                    icon.size = NSSize(width: 64, height: 64)
                    if let tiffData = icon.tiffRepresentation,
                       let bitmap = NSBitmapImageRep(data: tiffData),
                       let pngData = bitmap.representation(using: .png, properties: [:]) {
                        iconString = pngData.base64EncodedString()
                    }
                }

                return AppSummary(
                    bundleId: bundleId,
                    name: name,
                    isActive: app.processIdentifier == activeApp?.processIdentifier,
                    iconBase64: iconString
                )
            }
    }

    public func activateApplication(bundleId: String) {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleId }) {
            app.activate()
        }
    }

    public func terminateApplication(bundleId: String) {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleId }) {
            app.terminate()
        }
    }

    // MARK: - Power & Display Management

    public func lockScreen() {
        // SACLockScreenImmediate dynamic resolution
        typealias SACLockScreenImmediateFunc = @convention(c) () -> Void
        if let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY) {
            defer { dlclose(handle) }
            if let sym = dlsym(handle, "SACLockScreenImmediate") {
                let lockFunc = unsafeBitCast(sym, to: SACLockScreenImmediateFunc.self)
                lockFunc()
                return
            }
        }

        // Fallback: put display to sleep
        displaySleep()
    }

    public func displaySleep() {
        let task = Process()
        task.launchPath = "/usr/bin/pmset"
        task.arguments = ["displaysleepnow"]
        try? task.run()
    }

    public func systemSleep() {
        // Put Mac into low-power sleep state (0.5W standby)
        let script = NSAppleScript(source: "tell application \"System Events\" to sleep")
        script?.executeAndReturnError(nil)
    }

    public func shutdown() {
        // Safe shutdown via System Events
        let script = NSAppleScript(source: "tell application \"System Events\" to shut down")
        script?.executeAndReturnError(nil)
    }

    public func restart() {
        // Safe restart via System Events
        let script = NSAppleScript(source: "tell application \"System Events\" to restart")
        script?.executeAndReturnError(nil)
    }

    // MARK: - Hardware MAC Address Discovery

    public func getPrimaryMacAddress() -> String? {
        // 1. Apple Canonical IOKit Hardware Discovery (kIOEthernetInterfaceClass)
        let matchingDict = IOServiceMatching("IOEthernetInterface") as NSMutableDictionary
        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iterator)
        if kr == KERN_SUCCESS {
            defer { IOObjectRelease(iterator) }
            var service = IOIteratorNext(iterator)
            var candidateMac: String? = nil

            while service != 0 {
                defer {
                    IOObjectRelease(service)
                    service = IOIteratorNext(iterator)
                }

                var parent: io_object_t = 0
                if IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS {
                    defer { IOObjectRelease(parent) }
                    if let macData = IORegistryEntryCreateCFProperty(parent, "IOMACAddress" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data,
                       macData.count == 6 {
                        let macStr = macData.map { String(format: "%02X", $0) }.joined(separator: ":")
                        let bsdName = IORegistryEntryCreateCFProperty(service, "BSD Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String ?? ""
                        let isBuiltin = IORegistryEntryCreateCFProperty(service, "IOBuiltin" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool ?? false

                        if macStr != "00:00:00:00:00:00" && !macStr.hasPrefix("02:00:00") {
                            if bsdName == "en0" {
                                return macStr
                            }
                            if isBuiltin && candidateMac == nil {
                                candidateMac = macStr
                            }
                            if candidateMac == nil {
                                candidateMac = macStr
                            }
                        }
                    }
                }
            }
            if let found = candidateMac {
                return found
            }
        }

        // 2. Fallback via /sbin/ifconfig en0
        for ifName in ["en0", "en1"] {
            let task = Process()
            task.launchPath = "/sbin/ifconfig"
            task.arguments = [ifName]
            let pipe = Pipe()
            task.standardOutput = pipe
            try? task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                for line in output.components(separatedBy: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("ether ") {
                        let parts = trimmed.components(separatedBy: " ")
                        if parts.count >= 2 {
                            let rawMac = parts[1].trimmingCharacters(in: .whitespaces).uppercased()
                            if rawMac.count == 17 && rawMac != "00:00:00:00:00:00" && !rawMac.hasPrefix("02:00:00") {
                                return rawMac
                            }
                        }
                    }
                }
            }
        }

        // 3. Fallback via /usr/sbin/networksetup -getmacaddress en0
        let netTask = Process()
        netTask.launchPath = "/usr/sbin/networksetup"
        netTask.arguments = ["-getmacaddress", "en0"]
        let netPipe = Pipe()
        netTask.standardOutput = netPipe
        try? netTask.run()
        netTask.waitUntilExit()

        let netData = netPipe.fileHandleForReading.readDataToEndOfFile()
        if let netOutput = String(data: netData, encoding: .utf8) {
            let components = netOutput.components(separatedBy: " ")
            if components.count >= 3 {
                let macCandidate = components[2].trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                if macCandidate.count == 17 && macCandidate != "00:00:00:00:00:00" && !macCandidate.hasPrefix("02:00:00") {
                    return macCandidate
                }
            }
        }

        return nil
    }
}
