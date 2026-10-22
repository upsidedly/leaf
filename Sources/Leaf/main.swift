import AppKit

let application = NSApplication.shared
let leafDelegate = LeafAppDelegate()
application.delegate = leafDelegate
application.setActivationPolicy(.regular)
application.run()
