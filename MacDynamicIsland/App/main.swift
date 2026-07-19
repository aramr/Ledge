import AppKit

if ClaudeStatusLineBridgeRunner.isBridgeInvocation {
    exit(ClaudeStatusLineBridgeRunner.run())
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
