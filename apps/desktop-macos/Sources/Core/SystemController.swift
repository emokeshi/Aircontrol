import Foundation
import AppKit
import CoreAudio
import AudioToolbox
import ServiceManagement
import IOKit
import IOKit.pwr_mgt
import Darwin

public final class SystemController: @unchecked Sendable {
    public static let shared = SystemController()

    private var iconCache: [String: String] = [:]
    private let cacheLock = NSLock()
    private var workspaceObserversSetup = false

    private init() {}

    // MARK: - Launch at Login (Zero-Maintenance Host)

    public var isLaunchAtLoginEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("[SystemController] LaunchAtLogin notice: \(error)")
            }
        }
    }

    // MARK: - Real-Time Workspace App Change Observer

    public func startWorkspaceMonitoring(
        onAppListChanged: @escaping () -> Void,
        onActiveAppChanged: @escaping (String) -> Void
    ) {
        guard !workspaceObserversSetup else { return }
        workspaceObserversSetup = true

        let nc = NSWorkspace.shared.notificationCenter
        let listNotifications: [NSNotification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification
        ]
        for name in listNotifications {
            nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                onAppListChanged()
            }
        }

        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               let bundleId = app.bundleIdentifier {
                onActiveAppChanged(bundleId)
            } else if let frontId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
                onActiveAppChanged(frontId)
            }
        }
    }

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

    public func getRunningApplications(includeIcons: Bool = false) -> [AppSummary] {
        let ws = NSWorkspace.shared
        let activeApp = ws.frontmostApplication

        return ws.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let bundleId = app.bundleIdentifier,
                      let name = app.localizedName else { return nil }

                var iconString: String? = nil
                if includeIcons {
                    iconString = encodeIconIfNeeded(for: app, bundleId: bundleId)
                }

                return AppSummary(
                    bundleId: bundleId,
                    name: name,
                    isActive: app.processIdentifier == activeApp?.processIdentifier,
                    iconBase64: iconString
                )
            }
    }

    public func getCompressedIcons(for bundleIds: [String]) -> [String: String] {
        let wanted = Set(bundleIds)
        var result: [String: String] = [:]
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        for app in apps {
            guard let bid = app.bundleIdentifier, wanted.contains(bid) else { continue }
            if let encoded = encodeIconIfNeeded(for: app, bundleId: bid) {
                result[bid] = encoded
            }
        }
        return result
    }

    private func encodeIconIfNeeded(for app: NSRunningApplication, bundleId: String) -> String? {
        cacheLock.lock()
        if let cached = iconCache[bundleId] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        guard let icon = app.icon else { return nil }
        let targetSize = NSSize(width: 40, height: 40)
        let smallImage = NSImage(size: targetSize)
        smallImage.lockFocus()
        NSColor.white.setFill()
        NSBezierPath.fill(NSRect(origin: .zero, size: targetSize))
        icon.draw(in: NSRect(origin: .zero, size: targetSize),
                  from: NSRect(origin: .zero, size: icon.size),
                  operation: .sourceOver,
                  fraction: 1.0)
        smallImage.unlockFocus()

        guard let tiffData = smallImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.72]) else {
            return nil
        }

        let encoded = jpegData.base64EncodedString()
        cacheLock.lock()
        iconCache[bundleId] = encoded
        cacheLock.unlock()
        return encoded
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

    /// Wakes a sleeping Mac display (e.g. after `pmset displaysleepnow` / 息屏)
    public func wakeDisplay() {
        var assertionID: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity(
            "AirControl Wake Display" as CFString,
            kIOPMUserActiveLocal,
            &assertionID
        )

        let task = Process()
        task.launchPath = "/usr/bin/caffeinate"
        task.arguments = ["-u", "-t", "2"]
        try? task.run()

        // Nudge cursor by 1px and back so macOS WindowServer immediately lights up the display
        InputSimulator.shared.move(dx: 1, dy: 0)
        InputSimulator.shared.move(dx: -1, dy: 0)
    }

    public func lockScreen() {
        // 1. Primary: SACLockScreenImmediate in login.framework
        typealias SACLockScreenImmediateFunc = @convention(c) () -> Void
        if let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY) {
            defer { dlclose(handle) }
            if let sym = dlsym(handle, "SACLockScreenImmediate") {
                let lockFunc = unsafeBitCast(sym, to: SACLockScreenImmediateFunc.self)
                lockFunc()
                return
            }
        }

        // 2. Secondary: Native macOS Lock Screen shortcut (⌃⌘Q, keyCode 12 = 'q')
        let mods = KeyboardSimulator.Modifiers(cmd: true, opt: false, ctrl: true, shift: false)
        KeyboardSimulator.shared.postKeyEvent(keyCode: 12, isDown: true, modifiers: mods)
        KeyboardSimulator.shared.postKeyEvent(keyCode: 12, isDown: false, modifiers: mods)
    }

    public func displaySleep() {
        let task = Process()
        task.launchPath = "/usr/bin/pmset"
        task.arguments = ["displaysleepnow"]
        try? task.run()
    }

    public func systemSleep() {
        // 1. Primary: /usr/bin/pmset sleepnow (works without AppleEvents TCC permission!)
        let task = Process()
        task.launchPath = "/usr/bin/pmset"
        task.arguments = ["sleepnow"]
        try? task.run()

        // 2. Secondary: Direct IOKit Power Management sleep call
        let port = IOPMFindPowerManagement(kIOMainPortDefault)
        if port != 0 {
            IOPMSleepSystem(port)
            IOServiceClose(port)
        }
    }

    private func sendLoginWindowEvent(_ eventID: AEEventID) -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.loginwindow")
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: kCoreEventClass,
            eventID: eventID,
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        var reply = AppleEvent()
        let status = AESendMessage(event.aeDesc, &reply, AESendMode(kAENoReply), kAEDefaultTimeout)
        return status == noErr
    }

    public func shutdown() {
        if !sendLoginWindowEvent(AEEventID(kAEShutDown)) {
            let task = Process()
            task.launchPath = "/usr/bin/osascript"
            task.arguments = ["-e", "tell application \"System Events\" to shut down"]
            try? task.run()
        }
    }

    public func restart() {
        if !sendLoginWindowEvent(AEEventID(kAERestart)) {
            let task = Process()
            task.launchPath = "/usr/bin/osascript"
            task.arguments = ["-e", "tell application \"System Events\" to restart"]
            try? task.run()
        }
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
