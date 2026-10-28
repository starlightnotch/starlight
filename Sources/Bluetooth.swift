import AppKit
import CoreAudio
import CoreBluetooth
import Foundation
import IOBluetooth
import IOKit

/// Notices Bluetooth devices connecting (headphones, keyboards, mice, trackpads, controllers)
/// and reports their name, kind and battery.
///
/// Headphones are different: AirPods keep a Bluetooth link with every device on your Apple
/// account and switch on their own, so a link to the Mac turns up while you're on your phone.
/// They count as connected only when they become the Mac's sound output, which is what
/// "connected" means to you. Keyboards, mice and trackpads count when their link does.
/// AirPods and many headsets report battery through
/// IOBluetooth (read defensively: those properties aren't public API); Apple's keyboards, mice
/// and trackpads report it through the AppleDeviceManagementHIDEventService in the IORegistry.
final class BluetoothDevices: NSObject {
    struct Connected: Equatable {
        enum Kind { case headphones, keyboard, mouse, trackpad, other }
        let name: String
        let kind: Kind
        let battery: Int?
        /// Already connected when Starlight started or the Mac woke: no toast, just its battery.
        var quiet = false
    }

    var onConnect: ((Connected) -> Void)?
    var onDisconnect: ((String) -> Void)?
    private var disconnects: [String: IOBluetoothUserNotification] = [:]
    private var notification: IOBluetoothUserNotification?
    /// Connections in this window are macOS reconnecting what was already there (at launch, and
    /// after the Mac wakes), not you connecting something.
    private var quietUntil = Date().addingTimeInterval(3)
    /// When each device last showed, by address: AirPods drop and re-make their link (switching
    /// to your phone, one bud out, a profile change) and each fires a connect of its own.
    private var lastShown: [String: Date] = [:]
    private let showAgainAfter: TimeInterval = 90
    private var wake: NSObjectProtocol?

    func start() {
        notification = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(connected(_:device:)))
        watchOutput()
        wake = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.quietUntil = Date().addingTimeInterval(15)
        }
    }

    @objc private func connected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let address = device.addressString ?? device.name ?? "?"
        if disconnects[address] == nil, let note = device.register(forDisconnectNotification: self, selector: #selector(disconnected(_:device:))) {
            disconnects[address] = note
        }
        let quiet = Date() < quietUntil
        let kind = Self.kind(of: device)
        // Phones, watches, cars and speakers-you-didn't-pick connect on their own all day.
        guard kind != .other else { return }
        // Headphones wait until they're the Mac's output (outputChanged), however the link came.
        if kind == .headphones {
            DebugLog.write("bluetooth: \(Self.displayName(device.name)) linked; shown only if it becomes the sound output")
            return
        }
        if quiet {
            // Already there: remember it (for the battery in the open notch) without a toast.
            lastShown[address] = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard device.isConnected() else { return }
                let name = Self.displayName(device.name)
                self?.onConnect?(Connected(name: name, kind: kind, battery: Self.battery(of: device, named: device.name ?? name), quiet: true))
            }
            return
        }
        if let last = lastShown[address], Date().timeIntervalSince(last) < showAgainAfter { return }
        lastShown[address] = Date()
        // Battery levels arrive a moment after the link does: ask at 1.5 s, and once more at 3.5 s
        // if there's none yet. A link that's already gone again (a blip) shows nothing.
        func report(_ attempt: Int) {
            guard device.isConnected() else { return }
            let battery = Self.battery(of: device, named: device.name ?? "")
            if battery == nil, attempt == 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { report(1) }
                return
            }
            onConnect?(Connected(name: Self.displayName(device.name), kind: kind, battery: battery, quiet: false))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { report(0) }
    }

    /// For `Starlight --sound-output`: the output's name and whether it counts as headphones.
    static func describeOutput() -> String {
        let output = defaultOutput()
        var name: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(output, &address, 0, nil, &size, &name)
        let phones = bluetoothHeadphones(for: output)
        return "output \(name?.takeRetainedValue() as String? ?? "?") · Bluetooth headphones: \(phones.map { displayName($0.name) } ?? "no")"
    }

    // MARK: Headphones, by sound output

    /// The output last seen, so a property change that doesn't change the device does nothing.
    private var currentOutput: AudioDeviceID = 0

    private func watchOutput() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            self?.outputChanged()
        }
        // What's playing through at launch: its battery for the open notch, no toast.
        currentOutput = Self.defaultOutput()
        if let phones = Self.bluetoothHeadphones(for: currentOutput) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.onConnect?(Connected(name: Self.displayName(phones.name), kind: .headphones,
                                           battery: Self.battery(of: phones, named: phones.name ?? ""), quiet: true))
            }
        }
    }

    /// The Mac's sound moved to another device. Headphones over Bluetooth: they're connected.
    private func outputChanged() {
        let output = Self.defaultOutput()
        guard output != currentOutput else { return }
        currentOutput = output
        guard let phones = Self.bluetoothHeadphones(for: output) else { return }
        let address = phones.addressString ?? phones.name ?? "?"
        let name = Self.displayName(phones.name)
        if disconnects[address] == nil, let note = phones.register(forDisconnectNotification: self, selector: #selector(disconnected(_:device:))) {
            disconnects[address] = note
        }
        let quiet = Date() < quietUntil
        let recent = lastShown[address].map { Date().timeIntervalSince($0) < showAgainAfter } ?? false
        DebugLog.write("bluetooth: sound now plays through \(name)\(quiet ? " (just woke: no toast)" : recent ? " (shown recently: no toast)" : "")")
        if !quiet && !recent { lastShown[address] = Date() }
        // The battery arrives a moment after the switch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.currentOutput == output, phones.isConnected() else { return }
            self.onConnect?(Connected(name: name, kind: .headphones, battery: Self.battery(of: phones, named: phones.name ?? ""), quiet: quiet || recent))
        }
    }

    static func defaultOutput() -> AudioDeviceID {
        var device = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return device
    }

    /// The paired Bluetooth headphones a sound output is, if it's one.
    static func bluetoothHeadphones(for output: AudioDeviceID) -> IOBluetoothDevice? {
        // Without Bluetooth permission macOS ends the app rather than answer.
        guard output != 0, CBManager.authorization == .allowedAlways else { return nil }
        var transport = UInt32(0), size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(output, &address, 0, nil, &size, &transport) == noErr,
              transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE else { return nil }
        // Matched by address: Sound and Bluetooth name the same AirPods differently ("…Pro #3"
        // in one, "AirPods Pro" in the other). A Bluetooth output's UID starts with its address.
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        guard AudioObjectGetPropertyData(output, &address, 0, nil, &size, &uid) == noErr, let outputUID = uid?.takeRetainedValue() as String? else { return nil }
        let hex = { (s: String) in s.lowercased().filter { $0.isHexDigit } }
        let wanted = String(hex(outputUID).prefix(12))
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return paired.first { $0.isConnected() && hex($0.addressString ?? "") == wanted }
    }

    @objc private func disconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        note.unregister()
        disconnects = disconnects.filter { $0.value !== note }
        onDisconnect?(Self.displayName(device.name))
    }

    /// "Alex's AirPods Pro" → "AirPods Pro": the device, not whose it is (it's yours), and it fits.
    static func displayName(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return "Bluetooth device" }
        for mark in ["\u{2019}s ", "'s "] {
            if let range = name.range(of: mark), name.distance(from: name.startIndex, to: range.lowerBound) <= 24 {
                let rest = String(name[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { return rest }
            }
        }
        return name
    }

    private static func kind(of device: IOBluetoothDevice) -> Connected.Kind {
        let major = device.deviceClassMajor, minor = device.deviceClassMinor
        if major == UInt32(kBluetoothDeviceClassMajorAudio) { return .headphones }
        if major == UInt32(kBluetoothDeviceClassMajorPeripheral) {
            let name = (device.name ?? "").lowercased()
            if name.contains("trackpad") { return .trackpad }
            if minor & 0x10 != 0 { return .keyboard }   // keyboard bit of the peripheral minor class
            if minor & 0x20 != 0 { return .mouse }      // pointing device
        }
        let name = (device.name ?? "").lowercased()
        if name.contains("airpods") || name.contains("buds") || name.contains("headphone") || name.contains("beats") { return .headphones }
        if name.contains("keyboard") { return .keyboard }
        if name.contains("mouse") { return .mouse }
        if name.contains("trackpad") { return .trackpad }
        return .other
    }

    static func battery(of device: IOBluetoothDevice, named name: String) -> Int? {
        for key in ["batteryPercentCombined", "batteryPercentSingle", "batteryPercentLeft", "batteryPercentRight"] {
            guard device.responds(to: Selector(key)) else { continue }
            if let value = device.value(forKey: key) as? Int, value > 0, value <= 100 { return value }
        }
        return hidBattery(named: name)
    }

    /// Magic Keyboard / Mouse / Trackpad battery from the IORegistry.
    private static func hidBattery(named name: String) -> Int? {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            let product = IORegistryEntryCreateCFProperty(service, "Product" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            guard product == name || (product.map { name.contains($0) || $0.contains(name) } ?? false) else { continue }
            if let percent = IORegistryEntryCreateCFProperty(service, "BatteryPercent" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int { return percent }
        }
        return nil
    }
}
