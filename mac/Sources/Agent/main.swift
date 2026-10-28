// Sayit - the macOS push-to-talk agent: trigger, recording indicator and menu
// bar item. It records and pastes nothing itself; it runs bin/sayit, which in
// turn runs sayit-rec and sayit-paste from this same bundle, so the
// Microphone and Accessibility permissions granted to Sayit cover all of it.
//
// Usage:
//   Sayit            run as the menu bar agent (started by its LaunchAgent)
//   Sayit --probe    print key and mouse-button transitions for 30 s, to find
//                    out what a button actually sends. Needs the Accessibility
//                    or Input Monitoring permission for the terminal it runs in;
//                    Sayit's own "Probe Trigger" menu item needs nothing extra.
//
// Exit codes:
//   0  Quit from the menu
//   1  The sayit repository could not be found, or --probe could not listen

import AppKit

setvbuf(stdout, nil, _IOLBF, 0)

if CommandLine.arguments.dropFirst().first == "--probe" {
    let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .otherMouseDown, .otherMouseUp]
    let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
    let config = AgentConfig(repository: AgentConfig.repositoryPath() ?? "")
    let probe = Trigger(config: config, runner: Runner(repository: ""))
    let callback: CGEventTapCallBack = { _, type, event, info in
        let me = Unmanaged<Trigger>.fromOpaque(info!).takeUnretainedValue()
        print(me.describe(type, event))
        return Unmanaged.passUnretained(event)
    }
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                      options: .listenOnly, eventsOfInterest: mask, callback: callback,
                                      userInfo: Unmanaged.passUnretained(probe).toOpaque()) else {
        FileHandle.standardError.write(Data(("Sayit: cannot listen - allow this terminal under System Settings > "
            + "Privacy & Security > Input Monitoring, or use Sayit's Probe Trigger menu item\n").utf8))
        exit(1)
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
    print("Press the button or key you want to use. Listening for 30 s; nothing is swallowed.")
    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { exit(0) }
    CFRunLoopRun()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
