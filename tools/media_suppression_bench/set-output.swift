import CoreAudio
import Foundation
// set-output <name substring>: makes the first matching output device the default (and system) output.
func prop<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ value: inout T) -> OSStatus {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value)
}
var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var size: UInt32 = 0
AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
let wanted = CommandLine.arguments.dropFirst().joined(separator: " ").lowercased()
for id in ids {
    var streamsAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    var streamsSize: UInt32 = 0
    AudioObjectGetPropertyDataSize(id, &streamsAddr, 0, nil, &streamsSize)
    guard streamsSize > 0 else { continue }
    var name: Unmanaged<CFString>?
    _ = prop(id, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, &name)
    let n = (name?.takeRetainedValue() as String?) ?? ""
    if wanted.isEmpty { print(n); continue }
    guard n.lowercased().contains(wanted) else { continue }
    var dev = id
    for sel in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice] {
        var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &dev)
    }
    print("default output -> \(n)")
    exit(0)
}
if !wanted.isEmpty { print("no output device matches \(wanted)"); exit(1) }
