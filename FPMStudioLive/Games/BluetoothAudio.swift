import Foundation
import AppKit
import CoreAudio
import IOBluetooth
import SwiftUI

/// Casse e cuffie Bluetooth per la tombola (e per tutta l'app): collega un dispositivo già abbinato
/// e sceglie su quale uscita suonano voce e musica.
final class BluetoothAudio: ObservableObject {
    struct Device: Identifiable, Hashable {
        let id: String          // indirizzo Bluetooth
        let name: String
        var connected: Bool
    }
    struct Output: Identifiable, Hashable {
        let id: AudioDeviceID
        let name: String
        let bluetooth: Bool
    }

    static let shared = BluetoothAudio()

    @Published private(set) var devices: [Device] = []
    @Published private(set) var outputs: [Output] = []
    @Published private(set) var currentOutput: AudioDeviceID = 0
    @Published private(set) var status = ""
    @Published private(set) var working: String?

    func refresh() {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        // Solo dispositivi audio (casse, cuffie, soundbar): classe principale "Audio/Video" = 0x04.
        devices = paired
            .filter { $0.deviceClassMajor == 0x04 || $0.deviceClassMajor == 0 }
            .map { Device(id: $0.addressString ?? UUID().uuidString, name: $0.name ?? "Dispositivo senza nome", connected: $0.isConnected()) }
            .sorted { ($0.connected ? 0 : 1, $0.name) < ($1.connected ? 0 : 1, $1.name) }
        outputs = BluetoothAudio.outputDevices()
        currentOutput = BluetoothAudio.defaultOutput()
    }

    func connect(_ d: Device) {
        guard let dev = IOBluetoothDevice(addressString: d.id) else { return }
        working = d.id
        status = "Collego \(d.name)…"
        DispatchQueue.global(qos: .userInitiated).async {
            let r = dev.openConnection()
            DispatchQueue.main.async {
                if r == kIOReturnSuccess {
                    self.status = "\(d.name) collegato"
                    // L'uscita audio compare dopo qualche secondo: la scelgo da sola.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        self.refresh()
                        if let o = self.outputs.first(where: { $0.bluetooth && ($0.name == d.name || $0.name.contains(d.name) || d.name.contains($0.name)) }) {
                            self.select(o)
                        }
                        self.working = nil
                    }
                } else {
                    self.working = nil
                    self.status = "Non riesco a collegare \(d.name): accendila, avvicinala al Mac e riprova (o usa Impostazioni Bluetooth)."
                    self.refresh()
                }
            }
        }
    }

    func disconnect(_ d: Device) {
        guard let dev = IOBluetoothDevice(addressString: d.id) else { return }
        _ = dev.closeConnection()
        status = "\(d.name) scollegato"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.refresh() }
    }

    func select(_ o: Output) {
        var id = o.id
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let r = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id)
        status = r == noErr ? "Il suono ora esce da: \(o.name)" : "Non riesco a cambiare l'uscita audio"
        currentOutput = BluetoothAudio.defaultOutput()
    }

    /// Apre le impostazioni Bluetooth di macOS (per abbinare una cassa nuova).
    func openSystemSettings() {
        let urls = ["x-apple.systempreferences:com.apple.BluetoothSettings",
                    "x-apple.systempreferences:com.apple.preferences.Bluetooth"]
        for s in urls { if let u = URL(string: s), NSWorkspace.shared.open(u) { return } }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/PreferencePanes/Bluetooth.prefPane"))
    }

    // MARK: Core Audio

    static func defaultOutput() -> AudioDeviceID {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    static func outputDevices() -> [Output] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var sAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                   mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var sSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &sAddr, 0, nil, &sSize) == noErr, sSize > 0 else { return nil }
            var nAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                   mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var name: Unmanaged<CFString>?
            var nSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            AudioObjectGetPropertyData(id, &nAddr, 0, nil, &nSize, &name)
            var tAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                   mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var transport: UInt32 = 0
            var tSize = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(id, &tAddr, 0, nil, &tSize, &transport)
            let bt = transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
            return Output(id: id, name: (name?.takeRetainedValue() as String?) ?? "Uscita \(id)", bluetooth: bt)
        }
    }
}

/// Riquadro "Bluetooth e altoparlanti".
struct BluetoothPanel: View {
    @ObservedObject var bt = BluetoothAudio.shared

    var body: some View {
        Panel(title: "Bluetooth e altoparlanti", icon: "dot.radiowaves.left.and.right") {
            HStack(spacing: 8) {
                Button(action: { bt.refresh() }) { Label("Cerca casse Bluetooth", systemImage: "arrow.clockwise") }
                    .buttonStyle(NeonButtonStyle())
                Button(action: { bt.openSystemSettings() }) { Label("Abbina nuova…", systemImage: "plus") }
                    .buttonStyle(NeonButtonStyle(prominent: false))
                    .help("Apre le impostazioni Bluetooth del Mac per abbinare una cassa nuova")
            }
            if bt.devices.isEmpty {
                Text("Nessuna cassa o cuffia Bluetooth abbinata. Accendi la cassa in modalità abbinamento e premi \"Abbina nuova…\"; poi torna qui e premi \"Cerca\".")
                    .font(.system(size: 11)).foregroundColor(Theme.soft)
            } else {
                ForEach(bt.devices) { d in
                    HStack {
                        Image(systemName: d.connected ? "hifispeaker.fill" : "hifispeaker").foregroundColor(d.connected ? Theme.cyan : Theme.soft)
                        Text(d.name).font(.system(size: 13, weight: d.connected ? .bold : .regular)).lineLimit(1)
                        Spacer()
                        if bt.working == d.id {
                            ProgressView().scaleEffect(0.6)
                        } else if d.connected {
                            Button("Scollega") { bt.disconnect(d) }.buttonStyle(.borderless).font(.system(size: 11))
                        } else {
                            Button("Connetti") { bt.connect(d) }.buttonStyle(NeonButtonStyle(prominent: false))
                        }
                    }
                }
            }
            if !bt.outputs.isEmpty {
                Picker("Il suono esce da", selection: Binding(get: { bt.currentOutput }, set: { id in
                    if let o = bt.outputs.first(where: { $0.id == id }) { bt.select(o) }
                })) {
                    ForEach(bt.outputs) { o in Text((o.bluetooth ? "🔵 " : "") + o.name).tag(o.id) }
                }
            }
            if !bt.status.isEmpty { Text(bt.status).font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.ink) }
            Text("Voce e musica della tombola escono dall'uscita scelta. La musica passa alla nuova cassa dal brano successivo.")
                .font(.system(size: 10)).foregroundColor(Theme.soft)
        }
        .onAppear { bt.refresh() }
    }
}
