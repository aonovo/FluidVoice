import Foundation
// Posts a distributed notification by name: post-note com.FluidApp.debug.toggleRecording
let name = CommandLine.arguments.dropFirst().first ?? "com.FluidApp.debug.toggleRecording"
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name(name), object: nil, userInfo: nil, deliverImmediately: true
)
