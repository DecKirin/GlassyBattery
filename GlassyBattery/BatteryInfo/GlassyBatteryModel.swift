//
//  GlassyBatteryModel.swift
//  GlassyBattery
//
//  Created by apple on 2024/2/9.
//

import Foundation

struct btdDevice: Codable, Equatable {
    let time: Date
    let vid: String
    let pid: String
    let type: String
    let mac: String
    let name: String
    let level: Int
}

struct Device: Hashable, Codable {
    var hasBattery: Bool = true
    var deviceID: String
    var deviceType: String
    var deviceName: String
    var deviceModel: String?
    /// An SF Symbol a BatteryBridge client chose to draw instead of the type's icon (see
    /// `deviceIconImage`). Optional, so JSON from widgets and Nearcast peers without it still decodes.
    var deviceIcon: String? = nil
    /// The name of an icon the device's BatteryBridge client uploaded (see `customDeviceIcon`).
    var deviceCustomIcon: String? = nil
    var batteryLevel: Int
    var isCharging: Int
    var isCharged: Bool = false
    var isPaused: Bool = false
    var acPowered: Bool = false
    var isHidden: Bool = false
    var lowPower: Bool = false
    var parentName: String = ""
    /// The parent's `deviceID`, where the producer knows it (a Watch's phone, a Pencil's iPad). Two
    /// parents can share a name, so this is what `GlassyBatteryModel.getAll` points `parentName` with.
    var parentID: String? = nil
    var lastUpdate: Double
    var realUpdate: Double = 0.0
    /// Set by `GlassyBatteryModel.getAll` when another device reports the same name with a different
    /// model: `deviceName` then carries the model too ("Xiding's iPhone (iPhone Duo)"), so it stays a
    /// unique key for pins, alerts and widgets, and this is the name without it, for the dropdown,
    /// whose second line shows the model already.
    var nameWithoutModel: String? = nil

    public func hash(into hasher: inout Hasher) {
        hasher.combine(hasBattery)
        hasher.combine(deviceID)
        hasher.combine(deviceType)
        hasher.combine(deviceName)
        hasher.combine(deviceModel)
        hasher.combine(deviceIcon)
        hasher.combine(deviceCustomIcon)
        hasher.combine(batteryLevel)
        hasher.combine(isCharging)
        hasher.combine(isCharged)
        hasher.combine(isPaused)
        hasher.combine(acPowered)
        hasher.combine(isHidden)
        hasher.combine(lowPower)
        hasher.combine(lastUpdate)
        hasher.combine(realUpdate)
        hasher.combine(parentName)
        hasher.combine(parentID)
        hasher.combine(nameWithoutModel)
    }
}

class GlassyBatteryModel {
    private static let lock = NSLock()
    static var Devices: [Device] = []
    static let machineType = ud.string(forKey: "machineType") ?? "Mac"
    static let key = "com.deckirin.GlassyBattery.widget"
    
    /// The marketing name for a model identifier ("iPhone19,4" → "iPhone Duo"), or nil for one it
    /// doesn't know. The table lives in the app only; the widget and the CLI never hold two devices
    /// of the same name, so they leave this as it is.
    static var modelName: (String) -> String? = { _ in nil }

    /// Whether a device is identified by a libimobiledevice UDID: an iPhone, iPad or Watch, or an
    /// iPad's Pencil ("Pencil_<UDID>"). Two of these can share a name — two phones both called
    /// "Xiding's iPhone" — and their IDs are stable, so they're kept apart by ID. Every other
    /// source is matched by name, as it always was: the Bluetooth scanners report one device under
    /// IDs in several formats ("AA:BB:…" from IOKit, "aa-bb-…" from IOBluetooth, a CoreBluetooth
    /// UUID) and rely on the name to merge them.
    static func hasUDID(_ device: Device) -> Bool {
        var id = device.deviceID
        if id.hasPrefix("Pencil_") { id.removeFirst("Pencil_".count) }
        return id.range(of: "^([0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9A-Fa-f]{40})$", options: .regularExpression) != nil
    }

    static func updateDevice(_ device: Device) {
        if DemoMode.isOn && !device.deviceID.hasPrefix(DemoMode.idPrefix) { return }
        lock.lock()
        defer { lock.unlock() }
        let isUDID = hasUDID(device)
        let sameDevice: (Device) -> Bool = { stored in
            stored.deviceName == device.deviceName && !(isUDID && hasUDID(stored) && stored.deviceID != device.deviceID)
        }
        if let index = (isUDID ? Devices.firstIndex(where: { $0.deviceID == device.deviceID }) : nil)
            ?? Devices.firstIndex(where: sameDevice) {
            Devices[index] = device
        } else {
            Devices.append(device)
        }
    }

    /// Every stored device, including hidden, expired and blocked ones.
    static func snapshot() -> [Device] {
        lock.lock()
        defer { lock.unlock() }
        return Devices
    }

    static func removeDevices(where shouldRemove: (Device) -> Bool) {
        lock.lock()
        defer { lock.unlock() }
        Devices.removeAll(where: shouldRemove)
    }

    static func hideDevice(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        for index in Devices.indices {
            if Devices[index].deviceName == name {
                Devices[index].isHidden = true
            }
        }
    }
    
    static func unhideDevice(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        for index in Devices.indices {
            if Devices[index].deviceName == name {
                Devices[index].isHidden = false
            }
        }
    }
    
    static func getBlackList() -> [Device] {
        let blackList = (ud.object(forKey: "blackList") ?? []) as! [String]
        let devices = getAll(noFilter: true)
        return devices.filter({ blackList.contains($0.deviceName) })
    }
    
    static func getAll(reverse: Bool = false, noFilter: Bool = false) -> [Device] {
        lock.lock()
        let devicesSnapshot = disambiguated(Devices)
        lock.unlock()

        let thisMac = ud.string(forKey: "deviceName")
        let disappearTime = (ud.object(forKey: "disappearTime") ?? 20) as! Int
        let blackList = (ud.object(forKey: "blackList") ?? []) as! [String]
        let now = Double(Date().timeIntervalSince1970)
        var list = (reverse ? Array(devicesSnapshot.reversed()) : devicesSnapshot).filter { (now - $0.lastUpdate < Double(disappearTime * 60)) }
        if !noFilter { list = list.filter { !blackList.contains($0.deviceName) && !$0.isHidden } }
        var newList: [Device] = list.filter({ $0.parentName == thisMac })
        for d in list {
            if d.parentName == "" && d.parentName != thisMac {
                newList.append(d)
                for sd in list.filter({ $0.parentName == d.deviceName }) {
                    newList.append(sd)
                }
            }
        }
        for dd in list.filter({ !newList.contains($0) }) { newList.append(dd) }
        return newList.filter({ !checkIfBlocked(name: $0.deviceName) })
    }
    
    /// Gives devices that report the same name names of their own, so everything keyed by name —
    /// the dropdown, pins, alerts, hidden devices, widgets, AppleScript — tells them apart:
    /// - different models: the model goes after the name, "Xiding's iPhone (iPhone Duo)";
    /// - the same model, or one this Mac can't name: a number, "Xiding's iPhone 1", "… 2",
    ///   in `deviceID` order, so it doesn't swap between refreshes.
    ///
    /// It runs over every stored device, expired and hidden ones included, so a phone's name doesn't
    /// change while the other phone is briefly out of range. A child that knows its parent's ID (a
    /// Watch, a Pencil) follows its parent's new name.
    static func disambiguated(_ devices: [Device]) -> [Device] {
        let groups = Dictionary(grouping: devices.indices, by: { devices[$0].deviceName }).filter { $0.value.count > 1 }
        guard !groups.isEmpty else { return devices }
        var result = devices
        var newNames = [String: String]()   // deviceID → its new name
        for (name, indices) in groups {
            let model = { (i: Int) in devices[i].deviceModel.flatMap(modelName) ?? "" }
            let byModel = Dictionary(grouping: indices, by: model)
            for (modelLabel, same) in byModel {
                let ordered = same.sorted { devices[$0].deviceID < devices[$1].deviceID }
                for (n, i) in ordered.enumerated() {
                    let title = ordered.count > 1 ? "\(name) \(n + 1)" : name
                    if byModel.count > 1 && !modelLabel.isEmpty {
                        result[i].deviceName = "\(title) (\(modelLabel))"
                        result[i].nameWithoutModel = title
                    } else {
                        result[i].deviceName = title
                    }
                    newNames[devices[i].deviceID] = result[i].deviceName
                }
            }
        }
        for i in result.indices {
            if let parent = result[i].parentID, let name = newNames[parent] { result[i].parentName = name }
        }
        return result
    }

    /// Whether more than one stored device reports this name, so a source that only has the name
    /// (Bluetooth LE) can't tell which of them it's hearing from.
    static func isNameShared(_ name: String) -> Bool {
        snapshot().filter { $0.deviceName == name }.count > 1
    }

    static func getByName(_ name: String) -> Device? {
        for d in getAll(noFilter: true) { if d.deviceName == name { return d } }
        return nil
    }
    
    static func getByID(_ id: String) -> Device? {
        for d in getAll(noFilter: true) { if d.deviceID == id { return d } }
        return nil
    }
    
    static func singleDeviceName() -> String {
        var url: URL
        let bundleIdentifier = Bundle.main.bundleIdentifier
        if bundleIdentifier == key {
            url = fd.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("singleDeviceName")
            let devicename = try? String(contentsOf: url, encoding: .utf8)
            return devicename ?? ""
        } else {
            url = fd.urls(for: .libraryDirectory, in: .userDomainMask).first!.appendingPathComponent("Containers/\(key)/Data/Documents/singleDeviceName")
            try? ud.string(forKey: "deviceOnWidget")?.write(to: url, atomically: true, encoding: .utf8)
        }
        return ""
    }
    
    static func getJsonURL() -> URL {
        var url: URL
        let bundleIdentifier = Bundle.main.bundleIdentifier
        if bundleIdentifier == key {
            url = fd.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("data.json")
        } else {
            url = fd.urls(for: .libraryDirectory, in: .userDomainMask).first!.appendingPathComponent("Containers/\(key)/Data/Documents/data.json")
        }
        return url
    }
    
    /// Icons BatteryBridge clients upload, one folder per client: beside `data.json`, in the
    /// widget's container, so the widget can read them as well as the app.
    static func bridgeIconsURL() -> URL {
        getJsonURL().deletingLastPathComponent().appendingPathComponent("BridgeIcons", isDirectory: true)
    }

    static func writeData(){
        //let showMac = ud.object(forKey: "showMacOnWidget") as? Bool ?? true
        let revList = ud.object(forKey: "revListOnWidget") as? Bool ?? false
        
        var devices = getAll(reverse: revList)
        let ibStatus = InternalBattery.status
        if ibStatus.hasBattery { devices.insert(ib2ab(ibStatus), at: 0) }
        do {
            let jsonData = try JSONEncoder().encode(devices)
            try jsonData.write(to: getJsonURL())
        } catch {
            print("Write JSON error：\(error)")
        }
    }
    
    static func readData(url: URL = getJsonURL()) -> [Device]{
        do {
            let jsonData = try Data(contentsOf: url)
            let list = try JSONDecoder().decode([Device].self, from: jsonData)
            return list
        } catch {
            print("Read JSON error：\(error)")
        }
        return []
    }
    
    static func ncGetAll(url: URL, fromWidget: Bool = false) -> [Device] {
        let disappearTime = (ud.object(forKey: "disappearTime") ?? 20) as! Int
        let devices = readData(url: url)
        let now = Double(Date().timeIntervalSince1970)
        var localDevices = getAll().map({ $0.deviceName })
        if fromWidget { localDevices = readData().map({ $0.deviceName }) }
        var list = devices.filter{(now - $0.lastUpdate < Double(disappearTime * 60))}.filter({!localDevices.contains($0.deviceName)})
        if let first = devices.first { if !list.contains(first) && list.count != 0 { list.insert(first, at: 0) }}
        if let first = list.first { if list.count == 1 && !first.hasBattery { return [] }}
        return list
    }
    
    static func checkIfBlocked(name: String) -> Bool {
        let whitelistMode = ud.bool(forKey: "whitelistMode")
        let blockedItems = (ud.object(forKey: "blockedDevices") as? [String]) ?? [String]()
        if (blockedItems.contains(name) && !whitelistMode) || (!blockedItems.contains(name) && whitelistMode) {
            return true
        }
        return false
    }
}
