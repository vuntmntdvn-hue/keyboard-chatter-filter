// Per-key keyboard chatter filter (debouncer) for macOS.
//
// macOS counterpart of chatter-filter-linux.py. It installs a Quartz event tap, so it
// sees every key event before any app does, and drops presses that are switch chatter.
// Needs the Accessibility permission (System Settings > Privacy & Security >
// Accessibility); it waits until that is granted.
//
// When a key is pressed again less than --threshold ms after it was released, that
// press is treated as chatter and dropped together with its release. Other keys are
// never affected. Like the Windows version, every keyboard is filtered: an event tap
// can't tell which keyboard a key came from. Modifier keys (Shift, Cmd, ...) are not
// filtered.
//
// Build:
//   swiftc -O -o chatter-filter-macos chatter-filter-macos.swift
//
// Usage:
//   ./chatter-filter-macos                          # all keys, 40 ms window
//   ./chatter-filter-macos --threshold 60 --keys E,L,SPACE
//   ./chatter-filter-macos --seconds 60             # stop by itself after 60 s
//
// Stop it with Ctrl+C. install-macos.sh runs it as a LaunchAgent at every login.

import ApplicationServices
import Foundation

// Key names follow the Linux version (evdev names without KEY_); values are macOS
// virtual key codes (kVK_* in Carbon's Events.h, ANSI layout positions).
let keyCodes: [String: Int64] = [
    "A": 0x00, "S": 0x01, "D": 0x02, "F": 0x03, "H": 0x04, "G": 0x05, "Z": 0x06, "X": 0x07,
    "C": 0x08, "V": 0x09, "B": 0x0B, "Q": 0x0C, "W": 0x0D, "E": 0x0E, "R": 0x0F, "Y": 0x10,
    "T": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "EQUAL": 0x18,
    "9": 0x19, "7": 0x1A, "MINUS": 0x1B, "8": 0x1C, "0": 0x1D, "RIGHTBRACE": 0x1E, "O": 0x1F,
    "U": 0x20, "LEFTBRACE": 0x21, "I": 0x22, "P": 0x23, "ENTER": 0x24, "L": 0x25, "J": 0x26,
    "APOSTROPHE": 0x27, "K": 0x28, "SEMICOLON": 0x29, "BACKSLASH": 0x2A, "COMMA": 0x2B,
    "SLASH": 0x2C, "N": 0x2D, "M": 0x2E, "DOT": 0x2F, "TAB": 0x30, "SPACE": 0x31, "GRAVE": 0x32,
    "BACKSPACE": 0x33, "ESC": 0x35,
    "F1": 0x7A, "F2": 0x78, "F3": 0x63, "F4": 0x76, "F5": 0x60, "F6": 0x61, "F7": 0x62,
    "F8": 0x64, "F9": 0x65, "F10": 0x6D, "F11": 0x67, "F12": 0x6F,
    "HOME": 0x73, "PAGEUP": 0x74, "DELETE": 0x75, "END": 0x77, "PAGEDOWN": 0x79,
    "LEFT": 0x7B, "RIGHT": 0x7C, "DOWN": 0x7D, "UP": 0x7E,
]
let keyAliases = ["RETURN": "ENTER", "PERIOD": "DOT", "ESCAPE": "ESC", "LEFTBRACKET": "LEFTBRACE",
                  "RIGHTBRACKET": "RIGHTBRACE", "QUOTE": "APOSTROPHE"]
let keyNames = Dictionary(keyCodes.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })

func keyName(_ code: Int64) -> String { keyNames[code] ?? String(code) }

var logFile: String?

func log(_ msg: String) {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    let line = f.string(from: Date()) + "  " + msg
    print(line)
    if let path = logFile, let h = FileHandle(forWritingAtPath: path) ?? {
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }() {
        h.seekToEndOfFile()
        h.write((line + "\n").data(using: .utf8)!)
        h.closeFile()
    }
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

/// Seconds since boot. Taken when the tap sees the event: CGEvent timestamps use
/// different units on Intel and Apple silicon.
func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

final class Debouncer {
    let threshold: Double
    let keys: Set<Int64>                // empty = all keys
    var lastUp: [Int64: Double] = [:]   // code -> release time
    var suppressed: [Int64: Double] = [:]  // code -> time of the dropped press
    var drops: [Int64: Int] = [:]
    var total = 0

    init(thresholdMs: Int, keys: Set<Int64>) {
        threshold = Double(thresholdMs) / 1000
        self.keys = keys
    }

    /// Returns false to drop the event. May turn a held key's auto-repeat back into a press.
    func filter(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if !keys.isEmpty && !keys.contains(code) { return true }
        let t = now()

        if type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {  // press
            if suppressed[code] != nil { return false }
            if let last = lastUp[code], t - last < threshold {
                suppressed[code] = t
                drops[code, default: 0] += 1
                total += 1
                let name = keyName(code).padding(toLength: 12, withPad: " ", startingAt: 0)
                log(String(format: "dropped %@ gap %3.0f ms  (this key: %d, total: %d)",
                           name, (t - last) * 1000, drops[code]!, total))
                return false
            }
            return true
        }

        if type == .keyDown {                                   // auto-repeat
            guard let since = suppressed[code] else { return true }
            if t - since <= threshold { return false }
            // The key outlived the window, so it is really being held: send the press now.
            suppressed[code] = nil
            event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
            return true
        }

        // release
        if suppressed.removeValue(forKey: code) != nil { return false }
        lastUp[code] = t
        return true
    }
}

// MARK: - Options

var threshold = 40
var keyList: [String] = []
var seconds: Double?
var argv = CommandLine.arguments.dropFirst()
func value(_ opt: String) -> String {
    guard let v = argv.popFirst() else { fail("\(opt) needs a value") }
    return v
}
while let arg = argv.popFirst() {
    switch arg {
    case "--threshold": threshold = Int(value(arg)) ?? 0
    case "--keys": keyList.append(value(arg))
    case "--seconds": seconds = Double(value(arg))
    case "--log": logFile = value(arg)
    case "-h", "--help":
        print("""
            usage: chatter-filter-macos [--threshold MS] [--keys E,L,SPACE] [--seconds N] [--log FILE]
              --threshold MS   re-press window treated as chatter (default 40, range 5-500)
              --keys E,L,...   only filter these keys (default: all keys)
              --seconds N      stop after N seconds (for test runs)
              --log FILE       also append dropped presses to FILE
            """)
        exit(0)
    default: fail("Unknown option: \(arg) (see --help)")
    }
}
guard (5...500).contains(threshold) else { fail("--threshold must be between 5 and 500 ms") }

var keys = Set<Int64>()
for part in keyList.joined(separator: ",").split(separator: ",") {
    var name = part.trimmingCharacters(in: .whitespaces).uppercased()
    if name.hasPrefix("KEY_") { name.removeFirst(4) }
    name = keyAliases[name] ?? name
    guard let code = keyCodes[name] else {
        fail("Unknown key name: \(part)  (use names like E, L, SPACE, ENTER, BACKSPACE)")
    }
    keys.insert(code)
}

setlinebuf(stdout)
let deb = Debouncer(thresholdMs: threshold, keys: keys)

// MARK: - Event tap

var tap: CFMachPort?

let callback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        // macOS switches a tap off if it is ever too slow; switch it straight back on.
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    return deb.filter(type, event) ? Unmanaged.passUnretained(event) : nil
}

func start() -> Bool {
    let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
    guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                    options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                    callback: callback, userInfo: nil) else { return false }
    tap = t
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
    CGEvent.tapEnable(tap: t, enable: true)
    return true
}

func stop() -> Never {
    print("\nStopped. Dropped \(deb.total) chatter press(es) this session.")
    exit(0)
}

var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    s.setEventHandler { stop() }
    s.resume()
    signalSources.append(s)
}
if let seconds { DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { stop() } }

let scope = keys.isEmpty ? "all keys" : keys.sorted().map(keyName).joined(separator: ", ")
log("chatter filter running: all keyboards, \(scope), window \(threshold) ms. Ctrl+C to stop.")

// Asks for the permission once (adds this binary to the Accessibility list), then waits for it.
let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
if !AXIsProcessTrustedWithOptions(prompt) {
    log("waiting for Accessibility permission: System Settings > Privacy & Security > Accessibility")
}
Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
    guard AXIsProcessTrusted() else { return }
    timer.invalidate()
    if start() {
        log("filtering")
    } else {
        fail("could not create the event tap even though Accessibility is granted")
    }
}.fire()
RunLoop.main.run()
