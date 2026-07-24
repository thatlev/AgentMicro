// CodexMicroEmu — macOS BLE peripheral emulating the Work Louder Codex Micro
// vendor-HID control surface, to test ChatGPT Desktop detection & protocol.
// Protocol reference: docs/codex-micro-protocol.md
//
// Build:  swiftc -O tools/CodexMicroEmu/main.swift -o tools/CodexMicroEmu/codexmicroemu
// Run:    ./tools/CodexMicroEmu/codexmicroemu
// Then type commands on stdin, e.g.:  ag0 press / ag0 release / approve / send / up / down
//         enc cw / enc press / json {"method":"v.oai.hid","params":{"k":"ACT07","act":1}}

import CoreBluetooth
import Foundation

setvbuf(stdout, nil, _IONBF, 0) // unbuffered prints so nohup log is live

let VID: UInt16 = 0x303A, PID: UInt16 = 0x8360, RELEASE: UInt16 = 0x0101
let REPORT_ID: UInt8 = 6
let FW_VERSION = "0.1.0-macos-emu"

let reportMap: [UInt8] = [
    0x06, 0x00, 0xFF, 0x09, 0x01, 0xA1, 0x01, 0x85, 0x06,
    0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08, 0x95, 0x3F,
    0x09, 0x01, 0x81, 0x02, 0x95, 0x3F, 0x09, 0x02, 0x91,
    0x02, 0xC0,
]

class Emu: NSObject, CBPeripheralManagerDelegate {
    var pm: CBPeripheralManager!
    var inputChar: CBMutableCharacteristic!
    var outputChar: CBMutableCharacteristic!
    var subscribed = false
    var rpcBuffer = Data()

    func start() { pm = CBPeripheralManager(delegate: self, queue: nil) }

    func peripheralManagerDidUpdateState(_ p: CBPeripheralManager) {
        print("[ble] state=\(p.state.rawValue)")
        guard p.state == .poweredOn else { return }
        buildServices()
    }

    func buildServices() {
        // HID service 0x1812
        let hidInfo = CBMutableCharacteristic(type: CBUUID(string: "2A4A"), properties: .read,
            value: Data([0x11, 0x01, 0x00, 0x01]), permissions: .readable) // bcdHID 1.11, country 0, flags: remote-wake
        let mapChar = CBMutableCharacteristic(type: CBUUID(string: "2A4B"), properties: .read,
            value: Data(reportMap), permissions: .readable)
        let controlPoint = CBMutableCharacteristic(type: CBUUID(string: "2A4C"), properties: .writeWithoutResponse,
            value: nil, permissions: .writeable)
        let protoMode = CBMutableCharacteristic(type: CBUUID(string: "2A4E"), properties: [.read, .writeWithoutResponse],
            value: nil, permissions: [.readable, .writeable]) // report protocol mode, dynamic

        let inRef = CBMutableDescriptor(type: CBUUID(string: "2908"),
            value: Data([REPORT_ID, 0x01])) // input
        inputChar = CBMutableCharacteristic(type: CBUUID(string: "2A4D"),
            properties: [.read, .notify], value: nil, permissions: [.readable])
        inputChar.descriptors = [inRef]

        let outRef = CBMutableDescriptor(type: CBUUID(string: "2908"),
            value: Data([REPORT_ID, 0x02])) // output
        outputChar = CBMutableCharacteristic(type: CBUUID(string: "2A4D"),
            properties: [.read, .write, .writeWithoutResponse], value: nil,
            permissions: [.readable, .writeable])
        outputChar.descriptors = [outRef]

        let hid = CBMutableService(type: CBUUID(string: "1812"), primary: true)
        hid.characteristics = [hidInfo, mapChar, controlPoint, protoMode, inputChar, outputChar]

        // Battery service
        let batt = CBMutableCharacteristic(type: CBUUID(string: "2A19"), properties: [.read, .notify],
            value: nil, permissions: .readable) // dynamic value via didReceiveRead
        let battSvc = CBMutableService(type: CBUUID(string: "180F"), primary: true)
        battSvc.characteristics = [batt]

        // Device Information: manufacturer + PnP ID (little-endian, BLE standard order)
        let mfr = CBMutableCharacteristic(type: CBUUID(string: "2A29"), properties: .read,
            value: "Work Louder".data(using: .utf8), permissions: .readable)
        var pnp = Data([0x02])
        for v in [VID, PID, RELEASE] { pnp.append(UInt8(v & 0xFF)); pnp.append(UInt8(v >> 8)) }
        let pnpChar = CBMutableCharacteristic(type: CBUUID(string: "2A50"), properties: .read,
            value: pnp, permissions: .readable)
        let dis = CBMutableService(type: CBUUID(string: "180A"), primary: true)
        dis.characteristics = [mfr, pnpChar]

        pm.add(hid); pm.add(battSvc); pm.add(dis)
    }

    func peripheralManager(_ p: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let e = error { print("[ble] add svc error: \(e)"); return }
        if service.uuid == CBUUID(string: "180A") {
            p.startAdvertising([
                CBAdvertisementDataLocalNameKey: "Codex Micro",
                CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: "1812")],
            ])
            print("[ble] advertising as 'Codex Micro' (VID 303A PID 8360)")
        }
    }

    func peripheralManagerDidStartAdvertising(_ p: CBPeripheralManager, error: Error?) {
        print("[ble] advertising \(error == nil ? "started" : "error: \(error!)")")
    }

    func peripheralManager(_ p: CBPeripheralManager, central: CBCentral,
                           didSubscribeTo c: CBCharacteristic) {
        if c.uuid == inputChar.uuid { subscribed = true; print("[host] subscribed to input report — host connected") }
    }
    func peripheralManager(_ p: CBPeripheralManager, central: CBCentral,
                           didUnsubscribeFrom c: CBCharacteristic) {
        if c.uuid == inputChar.uuid { subscribed = false; print("[host] unsubscribed") }
    }

    // Host -> device (output report writes)
    func peripheralManager(_ p: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        if request.characteristic.uuid == CBUUID(string: "2A4E") {
            request.value = Data([0x01])
        }
        if request.characteristic.uuid == CBUUID(string: "2A19") {
            request.value = Data([100])
        }
        p.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ p: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for r in requests {
            if r.characteristic.uuid == outputChar.uuid, let data = r.value {
                handleOutput(data)
            }
            p.respond(to: r, withResult: .success)
        }
    }

    func handleOutput(_ data: Data) {
        var d = data
        if d.count >= 3 && d[0] == REPORT_ID { d = d.dropFirst() }
        guard d.count >= 2, d[0] == 2 else { return }
        let len = min(Int(d[1]), 61)
        guard d.count >= 2 + len else { return }
        let frag = d.subdata(in: 2..<(2+len))
        if String(data: frag, encoding: .utf8)?.hasPrefix("{\"method\"") == true { rpcBuffer.removeAll() }
        rpcBuffer.append(frag)
        guard let text = String(data: rpcBuffer, encoding: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: rpcBuffer) as? [String: Any],
              let method = obj["method"] as? String else {
            if String(data: rpcBuffer, encoding: .utf8) != nil { return } // wait for more fragments
            rpcBuffer.removeAll(); return
        }
        rpcBuffer.removeAll()
        print("[host->dev] \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        handleRpc(method: method, obj: obj)
    }

    func handleRpc(method: String, obj: [String: Any]) {
        let id = obj["id"]
        switch method {
        case "sys.version":
            sendJson(["id": id ?? NSNull(), "result": ["version": FW_VERSION]])
        case "device.status":
            sendJson(["id": id ?? NSNull(), "result": [
                "version": FW_VERSION, "profile_index": 0, "layer_index": 1,
                "battery": 100, "is_charging": true]])
        case "v.oai.thstatus":
            if let arr = obj["params"] as? [[String: Any]] {
                for t in arr { print("  [light] agent \(t["id"] ?? "?") color=\(t["c"] ?? 0) bright=\(t["b"] ?? 0) effect=\(t["e"] ?? "")") }
            }
            sendJson(["id": id ?? NSNull(), "result": ["ok": true]])
        case "v.oai.rgbcfg", "lights.preview", "host.focused_app":
            sendJson(["id": id ?? NSNull(), "result": ["ok": true]])
        default:
            sendJson(["id": id ?? NSNull(), "error": ["code": -32601, "message": "Method not found"]])
        }
    }

    // Device -> host
    func sendJson(_ obj: [String: Any]) {
        guard subscribed else { print("[tx-dropped, no subscriber] \(obj)"); return }
        guard var payload = try? JSONSerialization.data(withJSONObject: obj) else { return }
        payload.append(0x0A)
        var offset = 0
        while offset < payload.count {
            let chunk = min(61, payload.count - offset)
            var report = Data(count: 63)
            report[0] = 2; report[1] = UInt8(chunk)
            report.replaceSubrange(2..<(2+chunk), with: payload.subdata(in: offset..<(offset+chunk)))
            let ok = pm.updateValue(report, for: inputChar, onSubscribedCentrals: nil)
            if !ok { print("[ble] updateValue queue full"); }
            offset += chunk
            usleep(4000)
        }
        print("[dev->host] \(String(data: payload, encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
}

let emu = Emu()
emu.start()

let keyMap: [String: (String, Int8?)] = [
    "ag0": ("AG00", 0), "ag1": ("AG01", 1), "ag2": ("AG02", 2),
    "ag3": ("AG03", 3), "ag4": ("AG04", 4), "ag5": ("AG05", 5),
    "fast": ("ACT06", nil), "approve": ("ACT07", nil), "decline": ("ACT08", nil),
    "fork": ("ACT09", nil), "mic": ("ACT10", nil), "send": ("ACT12", nil),
]
let joyMap: [String: Float] = ["right": 0.0, "down": 0.25, "left": 0.5, "up": 0.75]

print("""
Commands:
  ag0..ag5 press|release      agent key (default: press+release)
  fast|approve|decline|fork|mic|send [press|release]
  up|down|left|right [press|release]
  enc cw|cc|press
  json <raw json>
""")

DispatchQueue.global().async {
    while let line = readLine()?.trimmingCharacters(in: .whitespaces), !line.isEmpty {
        let parts = line.split(separator: " ").map(String.init)
        if line.hasPrefix("json ") {
            let raw = String(line.dropFirst(5))
            if let d = raw.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                emu.sendJson(o)
            }
            continue
        }
        let actStr = parts.count > 1 ? parts[1] : "tap"
        if parts[0] == "enc", parts.count > 1 {
            switch parts[1] {
            case "cw": emu.sendJson(["method": "v.oai.hid", "params": ["k": "ENC_CW", "act": 2]])
            case "cc": emu.sendJson(["method": "v.oai.hid", "params": ["k": "ENC_CC", "act": 2]])
            default:
                emu.sendJson(["method": "v.oai.hid", "params": ["k": "ENC", "act": 1]])
                usleep(50000)
                emu.sendJson(["method": "v.oai.hid", "params": ["k": "ENC", "act": 0]])
            }
            continue
        }
        if let (key, ag) = keyMap[parts[0]] {
            let send: (Int) -> Void = { act in
                var params: [String: Any] = ["k": key, "act": act]
                if let a = ag { params["ag"] = a }
                emu.sendJson(["method": "v.oai.hid", "params": params])
            }
            if actStr == "press" { send(1) }
            else if actStr == "release" { send(0) }
            else { send(1); usleep(50000); send(0) }
            continue
        }
        if let angle = joyMap[parts[0]] {
            let send: (Float) -> Void = { d in emu.sendJson(["method": "v.oai.rad", "params": ["a": angle, "d": d]]) }
            if actStr == "press" { send(1.0) }
            else if actStr == "release" { send(0.0) }
            else { send(1.0); usleep(50000); send(0.0) }
            continue
        }
        print("unknown command")
    }
}

RunLoop.main.run()
