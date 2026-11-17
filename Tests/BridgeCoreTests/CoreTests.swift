//
//  CoreTests.swift
//  BridgeCoreTests
//
//  Client store, device mapping, Nearcast filter and the model hooks.
//

import Foundation

func runCoreTests() throws {
    // MARK: Client store

    do {
        let (store, url) = freshStore()
        let (client, token) = try store.register(name: "Logi Bridge", bundleID: "com.example.logi", mode: .blocklist)
        check(client.status == .active, "blocklist mode accepts new clients")
        check(token.hasPrefix("gbb_") && token.count > 40, "token has prefix and 256 bits")
        check((try? store.authenticate(token: token))?.id == client.id, "token authenticates")
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        check(!onDisk.contains(token) && onDisk.contains(BridgeClientStore.hash(token)), "only the hash is persisted")
        let perms = try fd.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        check(perms == 0o600, "client file is private")
        expectError(.unauthorized, "unknown token") { _ = try store.authenticate(token: "gbb_nope") }

        let reloaded = BridgeClientStore(fileURL: url)
        // lastSeen is persisted at most once a minute, so compare everything else.
        check(reloaded.all.map { [$0.id, $0.name, $0.bundleID ?? "", $0.status.rawValue, $0.tokenHash] }
              == store.all.map { [$0.id, $0.name, $0.bundleID ?? "", $0.status.rawValue, $0.tokenHash] },
              "clients survive a reload")
    }

    do {
        let (store, _) = freshStore()
        let (client, token) = try store.register(name: "Pi Sensor", bundleID: nil, mode: .allowlist)
        check(client.status == .pending, "allowlist mode holds new clients")
        expectError(.pending, "pending client can't push") { _ = try store.authenticate(token: token) }
        store.setStatus(.active, for: client.id)
        check((try? store.authenticate(token: token)) != nil, "approved client authenticates")

        // Same identity again: new token, old one dead, approval revoked in allowlist mode.
        let (again, newToken) = try store.register(name: "pi sensor", bundleID: "", mode: .allowlist)
        check(again.id == client.id && store.all.count == 1, "re-registration reuses the entry (name, case-insensitive)")
        check(again.status == .pending, "re-registration in allowlist mode needs approval again")
        expectError(.unauthorized, "old token stops working") { _ = try store.authenticate(token: token) }
        expectError(.pending, "new token is pending") { _ = try store.authenticate(token: newToken) }

        store.applyMode(.blocklist)
        check(store.client(id: client.id)?.status == .active, "switching to blocklist admits pending clients")

        store.setStatus(.blocked, for: client.id)
        expectError(.blocked, "blocked client can't push") { _ = try store.authenticate(token: newToken) }
        expectError(.blocked, "blocked client can't re-register") {
            _ = try store.register(name: "Pi Sensor", bundleID: nil, mode: .blocklist)
        }
        store.applyMode(.blocklist)
        check(store.client(id: client.id)?.status == .blocked, "blocklist mode doesn't unblock")

        let reset = store.resetToken(for: client.id)
        check(reset != nil && reset != newToken, "reset issues a new token")
        check(store.resetToken(for: "missing") == nil, "reset of unknown client")

        store.remove(id: client.id)
        check(store.all.isEmpty, "remove")
    }

    do {
        let (store, _) = freshStore()
        expectError(.invalid("name", "must be 1–64 characters"), "blank name") {
            _ = try store.register(name: "   ", bundleID: nil, mode: .blocklist)
        }
        let a = try store.register(name: "Same Name", bundleID: "com.a", mode: .blocklist).client
        let b = try store.register(name: "Same Name", bundleID: "com.b", mode: .blocklist).client
        check(a.id != b.id, "bundle ID beats name for identity")
    }

    do {
        let (store, _) = freshStore()
        for i in 0..<BridgeClientStore.maxClients {
            _ = try store.register(name: "Client \(i)", bundleID: nil, mode: .blocklist)
        }
        expectError(.tooManyClients, "client cap") { _ = try store.register(name: "One more", bundleID: nil, mode: .blocklist) }
        check((try? store.register(name: "Client 3", bundleID: nil, mode: .blocklist)) != nil, "the cap doesn't block re-registration")
    }

    // MARK: Device mapping

    let clientID = "abc123def456"
    func payload(_ id: String = "mouse", name: String = "Bridge Mouse", type: String = "Mouse",
                 level: Int? = 55, charging: Bool? = true, hasBattery: Bool? = nil, icon: String? = nil) -> BridgeDevicePayload {
        BridgeDevicePayload(id: id, name: name, type: type, model: " M720 ", level: level,
                            charging: charging, hasBattery: hasBattery, parent: nil, icon: icon)
    }

    do {
        let d = try BridgeDevices.make(from: payload(), clientID: clientID, existing: [], now: 1000)
        check(d.deviceID == "bridge:abc123def456:mouse", "device ID is namespaced")
        check(BridgeDevices.clientID(of: d.deviceID) == clientID, "owner is recoverable from the ID")
        check(BridgeDevices.clientID(of: "AA:BB:CC") == nil, "non-bridge devices have no owner")
        check(d.deviceType == "Mouse" && d.batteryLevel == 55 && d.isCharging == 1, "fields carried over")
        check(d.deviceModel == "M720" && d.parentName == "" && d.lastUpdate == 1000, "trimmed model, no parent")
        check(getDeviceIcon(d) == "computermouse.fill", "type maps to the right icon")

        let odd = try BridgeDevices.make(from: payload(type: "Toaster"), clientID: clientID, existing: [])
        check(odd.deviceType == "generic" && getDeviceIcon(odd) == "cube.fill", "unknown type falls back to the generic icon")
        check(d.deviceIcon == nil && customDeviceSymbol(d) == nil, "no icon unless the client sends one")

        // A chosen SF Symbol is drawn instead of the type's icon, when this Mac has it.
        let printer = try BridgeDevices.make(from: payload(icon: " printer.fill "), clientID: clientID, existing: [])
        check(printer.deviceIcon == "printer.fill" && customDeviceSymbol(printer) == "printer.fill", "icon is stored and drawn")
        let future = try BridgeDevices.make(from: payload(icon: "printer.fill.from.the.future"), clientID: clientID, existing: [])
        check(future.deviceIcon == "printer.fill.from.the.future" && customDeviceSymbol(future) == nil,
              "a symbol this Mac lacks is kept but not drawn, so the type's icon shows")
        check(customDeviceSymbol(future) == nil, "the miss is cached, not looked up again as a hit")
        let long = String(repeating: "a.", count: 49) + "fill"   // 102 characters, like the longest real names
        check((try? BridgeDevices.make(from: payload(icon: long), clientID: clientID, existing: []))?.deviceIcon == long,
              "icon names past 64 characters are allowed")
        for bad in ["Printer.Fill", "printer..fill", ".printer", "printer fill", "printer/fill"] {
            expectError(.invalid("icon", "must be an SF Symbol name, like \"printer.fill\""), "icon \(bad) is rejected") {
                _ = try BridgeDevices.make(from: payload(icon: bad), clientID: clientID, existing: [])
            }
        }
        expectError(.invalid("icon", "must be at most 128 characters"), "icon too long") {
            _ = try BridgeDevices.make(from: payload(icon: String(repeating: "a", count: 129)), clientID: clientID, existing: [])
        }

        // Older JSON (widgets, Nearcast peers on an earlier version) has no deviceIcon.
        let old = #"{"hasBattery":true,"deviceID":"x","deviceType":"Mouse","deviceName":"x","batteryLevel":1,"isCharging":0,"isCharged":false,"isPaused":false,"acPowered":false,"isHidden":false,"lowPower":false,"parentName":"","lastUpdate":0,"realUpdate":0}"#
        check((try? JSONDecoder().decode(Device.self, from: Data(old.utf8)))?.deviceIcon == nil, "a device without deviceIcon decodes")
        let roundTrip = try JSONDecoder().decode(Device.self, from: JSONEncoder().encode(printer))
        check(roundTrip == printer, "deviceIcon survives the JSON the widget and Nearcast read")

        let noBattery = try BridgeDevices.make(from: payload(level: nil, hasBattery: false), clientID: clientID, existing: [])
        check(!noBattery.hasBattery && noBattery.batteryLevel == 0, "devices without a battery")

        for type in BridgeDevices.knownTypes {
            let icon = getDeviceIcon(Device(deviceID: "x", deviceType: type, deviceName: "x", batteryLevel: 1, isCharging: 0, lastUpdate: 0))
            check(icon != "questionmark.circle.fill", "known type \(type) has an icon")
        }

        expectError(.invalid("level", "must be 0–100"), "level too high") {
            _ = try BridgeDevices.make(from: payload(level: 101), clientID: clientID, existing: [])
        }
        expectError(.invalid("level", "is required when hasBattery is true"), "missing level") {
            _ = try BridgeDevices.make(from: payload(level: nil), clientID: clientID, existing: [])
        }
        expectError(.invalid("id", "must be 1–64 characters of A–Z, a–z, 0–9, '.', '_' or '-'"), "id with a colon") {
            _ = try BridgeDevices.make(from: payload("a:b"), clientID: clientID, existing: [])
        }

        let realMouse = Device(deviceID: "AA:BB", deviceType: "MMouse", deviceName: "Magic Mouse", batteryLevel: 80, isCharging: 0, lastUpdate: 0)
        expectError(.nameTaken("Magic Mouse"), "can't take a real device's name") {
            _ = try BridgeDevices.make(from: payload(name: "Magic Mouse"), clientID: clientID, existing: [realMouse])
        }
        check((try? BridgeDevices.make(from: payload(level: 40), clientID: clientID, existing: [d])) != nil,
              "updating your own device keeps its name")

        let full = (0..<BridgeDevices.maxPerClient).map {
            Device(deviceID: BridgeDevices.deviceID(client: clientID, localID: "d\($0)"), deviceType: "Mouse",
                   deviceName: "Device \($0)", batteryLevel: 1, isCharging: 0, lastUpdate: 0)
        }
        expectError(.tooManyDevices, "per-client cap") {
            _ = try BridgeDevices.make(from: payload("one-more", name: "One More"), clientID: clientID, existing: full)
        }
        check((try? BridgeDevices.make(from: payload("d3", name: "Device 3"), clientID: clientID, existing: full)) != nil,
              "the cap doesn't block updates")
        check((try? BridgeDevices.make(from: payload("x", name: "X"), clientID: "otherclient1", existing: full)) != nil,
              "the cap is per client")
    }

    // MARK: Nearcast filter

    do {
        let (store, _) = freshStore()
        let sharing = try store.register(name: "Sharing", bundleID: nil, mode: .blocklist).client
        let quiet = try store.register(name: "Quiet", bundleID: nil, mode: .blocklist).client
        store.setNearcast(false, for: quiet.id)
        func device(_ owner: String?, _ name: String) -> Device {
            Device(deviceID: owner.map { BridgeDevices.deviceID(client: $0, localID: name) } ?? name,
                   deviceType: "Mouse", deviceName: name, batteryLevel: 1, isCharging: 0, lastUpdate: 0)
        }
        let list = [device(nil, "local"), device(sharing.id, "shared"), device(quiet.id, "quiet"), device("gone00000000", "orphan")]
        let names = BridgeDevices.forNearcast(list, store: store).map(\.deviceName)
        check(names == ["local", "shared"], "Nearcast keeps local and sharing clients only (got \(names))")
    }

    // MARK: Model hooks

    do {
        GlassyBatteryModel.updateDevice(Device(deviceID: "bridge:c1:a", deviceType: "Mouse", deviceName: "Bridged A", batteryLevel: 1, isCharging: 0, lastUpdate: 0))
        GlassyBatteryModel.updateDevice(Device(deviceID: "AA", deviceType: "Mouse", deviceName: "Local", batteryLevel: 1, isCharging: 0, lastUpdate: 0))
        check(GlassyBatteryModel.snapshot().count == 2, "snapshot includes expired devices")
        GlassyBatteryModel.removeDevices { BridgeDevices.clientID(of: $0.deviceID) == "c1" }
        check(GlassyBatteryModel.snapshot().map(\.deviceName) == ["Local"], "removeDevices drops one client's devices")
        GlassyBatteryModel.removeDevices { _ in true }
    }

    // MARK: Devices sharing a name

    do {
        GlassyBatteryModel.modelName = { ["iPhone19,4": "iPhone Duo", "iPhone16,2": "iPhone 15 Pro Max"][$0] }
        defer {
            GlassyBatteryModel.modelName = { _ in nil }
            GlassyBatteryModel.removeDevices { _ in true }
        }
        let now = Date().timeIntervalSince1970
        func phone(_ id: String, _ model: String, level: Int = 50, name: String = "Xiding's iPhone") -> Device {
            Device(deviceID: id, deviceType: "iPhone", deviceName: name, deviceModel: model, batteryLevel: level, isCharging: 0, lastUpdate: now)
        }
        let duo = "00008150-0011223344556677", max = "00008130-00140CA93C38001C", watch = "00008301-AAAABBBBCCCCDDDD"
        GlassyBatteryModel.updateDevice(phone(duo, "iPhone19,4"))
        GlassyBatteryModel.updateDevice(phone(max, "iPhone16,2"))
        GlassyBatteryModel.updateDevice(Device(deviceID: watch, deviceType: "Watch", deviceName: "Watch", deviceModel: "Watch7,5",
                                               batteryLevel: 70, isCharging: 0, parentName: "Xiding's iPhone", parentID: max, lastUpdate: now))
        check(GlassyBatteryModel.snapshot().count == 3, "two phones with one name are two devices")
        GlassyBatteryModel.updateDevice(phone(max, "iPhone16,2", level: 20))
        check(GlassyBatteryModel.snapshot().count == 3 && GlassyBatteryModel.getByID(max)?.batteryLevel == 20,
              "a reading updates its own phone")
        check(GlassyBatteryModel.getByID(duo)?.batteryLevel == 50, "and leaves the other alone")

        var names = GlassyBatteryModel.getAll(noFilter: true).map(\.deviceName)
        check(Set(names) == ["Xiding's iPhone (iPhone Duo)", "Xiding's iPhone (iPhone 15 Pro Max)", "Watch"],
              "different models are named by model (got \(names))")
        check(GlassyBatteryModel.getByID(max)?.nameWithoutModel == "Xiding's iPhone", "the dropdown titles it without the model")
        check(GlassyBatteryModel.getByID(watch)?.parentName == "Xiding's iPhone (iPhone 15 Pro Max)", "a Watch follows its phone's name")
        check(GlassyBatteryModel.isNameShared("Xiding's iPhone"), "a shared name is known as one")

        let second = "00008130-0000000000000002"
        GlassyBatteryModel.updateDevice(phone(second, "iPhone16,2"))
        names = GlassyBatteryModel.getAll(noFilter: true).map(\.deviceName)
        check(Set(names) == ["Xiding's iPhone (iPhone Duo)", "Xiding's iPhone 1 (iPhone 15 Pro Max)",
                             "Xiding's iPhone 2 (iPhone 15 Pro Max)", "Watch"], "and numbered within a model (got \(names))")
        check(GlassyBatteryModel.getByID(second)?.deviceName == "Xiding's iPhone 1 (iPhone 15 Pro Max)", "numbered in ID order")
        GlassyBatteryModel.removeDevices { $0.deviceID == duo }
        names = GlassyBatteryModel.getAll(noFilter: true).map(\.deviceName)
        check(Set(names) == ["Xiding's iPhone 1", "Xiding's iPhone 2", "Watch"], "the same model is numbered (got \(names))")
        check(GlassyBatteryModel.getByID(second)?.nameWithoutModel == nil, "with no model to drop")

        GlassyBatteryModel.updateDevice(phone(second, "iPhone16,2", name: "Spare iPhone"))
        check(GlassyBatteryModel.snapshot().count == 3 && GlassyBatteryModel.getByID(max)?.deviceName == "Xiding's iPhone",
              "a renamed phone is updated in place, and the other gets its name back")

        // Bluetooth sources are still merged by name, whatever their IDs.
        GlassyBatteryModel.updateDevice(Device(deviceID: "AA:BB:CC:DD:EE:FF", deviceType: "MMouse", deviceName: "Mouse",
                                               batteryLevel: 40, isCharging: 0, lastUpdate: now))
        GlassyBatteryModel.updateDevice(Device(deviceID: "aa-bb-cc-dd-ee-ff", deviceType: "MMouse", deviceName: "Mouse",
                                               batteryLevel: 41, isCharging: 0, lastUpdate: now))
        check(GlassyBatteryModel.snapshot().filter { $0.deviceName == "Mouse" }.count == 1, "Bluetooth devices merge by name")
        // A Bluetooth LE reading of a phone's name still lands on it while only one phone has that name.
        GlassyBatteryModel.updateDevice(phone("6F1C2B9E-0000-4000-8000-000000000001", "iPhone16,2", name: "Spare iPhone"))
        check(GlassyBatteryModel.snapshot().filter { $0.deviceName == "Spare iPhone" }.count == 1, "a BLE reading merges into the phone")
    }
}

// MARK: - Power details

func runPowerDetailsTests() {
    // A 140W USB-C Power Adapter on a 16-inch MacBook Pro, as its AppleSmartBattery entry reads.
    let pdos: [NSNumber] = [142709032, 184617, 307498, 410099, 0, 0, 0, 573939, -768567669, 0, 0, 0, 0]
    let properties: [String: Any] = [
        "ExternalConnected": true, "IsCharging": true, "FullyCharged": false, "AvgTimeToFull": 32,
        "Voltage": 12652, "Amperage": 1663,
        "AdapterDetails": ["Name": "140W USB-C Power Adapter", "Watts": 140, "UsbHvcHvcIndex": 7,
                           "UsbHvcMenu": [["Index": 0, "MaxCurrent": 2960, "MaxVoltage": 5000]]] as [String: Any],
        "PowerTelemetryData": ["SystemPowerIn": 40053, "SystemVoltageIn": 27911, "SystemCurrentIn": 1435,
                               "SystemLoad": 19310, "AdapterEfficiencyLoss": 822],
        "ChargerData": ["NotChargingReason": 0, "SlowChargingReason": 0],
        "PortControllerInfo": [["PortControllerNPDOs": 0, "PortControllerMaxPower": 0, "PortControllerPortPDO": [NSNumber](repeating: 0, count: 13)],
                               ["PortControllerNPDOs": 4, "PortControllerMaxPower": 139720, "PortControllerPortPDO": pdos]],
    ]
    let d = PowerDetails(properties: properties)
    let options = d.options.map { o -> String in
        let v = o.minVoltage.map { "\($0)-\(o.voltage)" } ?? "\(o.voltage)"
        return "\(v)V \(o.maxCurrent.map { String(format: "%.2f", $0) } ?? "-")A \(Int(o.maxPower.rounded()))W\(o.isActive ? " *" : "")"
    }
    check(options == ["5.0V 2.96A 15W", "9.0V 2.97A 27W", "15.0V 2.98A 45W", "20.0V 4.99A 100W", "28.0V 4.99A 140W *", "15.0-28.0V -A 139W"],
          "the adapter's six options, 28 V in use (got \(options))")
    check(d.options.filter(\.isExtendedRange).count == 2 && d.options.last?.kind == .adjustable, "28 V options are extended range; the last is AVS")
    check(d.inputPower == 40.053 && d.systemPower == 19.31 && d.conversionLoss == 0.822, "power in, the Mac's use, the loss")
    check(abs((d.batteryPower ?? 0) - 21.04) < 0.01 && d.minutesToFull == 32, "into the battery, minutes to full")

    var onBattery = properties
    onBattery["ExternalConnected"] = false
    onBattery["IsCharging"] = false
    onBattery["Amperage"] = -900
    let b = PowerDetails(properties: onBattery)
    check(b.options.isEmpty && b.inputPower == nil && (b.batteryPower ?? 0) < 0, "on battery: no adapter, power out of the battery")

    // Without the port controller's list, Apple's own menu, which stops at 20 V.
    var menuOnly = properties
    menuOnly["PortControllerInfo"] = nil
    menuOnly["AdapterDetails"] = ["Watts": 96, "UsbHvcHvcIndex": 3,
                                  "UsbHvcMenu": [["Index": 0, "MaxCurrent": 3000, "MaxVoltage": 5000],
                                                 ["Index": 3, "MaxCurrent": 4800, "MaxVoltage": 20000]]] as [String: Any]
    let m = PowerDetails(properties: menuOnly)
    check(m.options.map(\.voltage) == [5, 20] && m.options.last?.isActive == true, "Apple's menu as a fallback")
}
