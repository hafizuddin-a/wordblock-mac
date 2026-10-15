// wordblock: deletes blocked words as you type them, system-wide, like Sentryboard does on Android.
//
// Word list: ~/.config/wordblock/words.txt, one entry per line (same syntax as Sentryboard):
//   word    blocks exactly that word, removed when you finish it (space, punctuation, Enter)
//   word*   also blocks longer words that start with `word`
//   word!   blocks exactly that word and removes it the instant it is typed
//   hello world   a phrase of up to 6 words: when its last word is finished the whole phrase goes,
//                 including the gaps (up to 64 spaces, punctuation or line breaks) between its words.
//                 `*` and `!` apply to the last word.
//
// Settings lock (same idea as Sentryboard's): `wordblock lock` makes the list append-only.
// Adding words is always instant. Removing words, disabling the filter or changing the delay
// needs `wordblock unlock`, a countdown, and then a short window to make the change.
//
// Opened by double-click it shows a first-run guide (or the current status once set up).
// `--daemon` is the background program launchd starts at login. With a command
// (`wordblock status`, `lock`, `unlock`, ...) it talks to the running daemon.
//
// Needs Accessibility permission (System Settings > Privacy & Security > Accessibility).

import AppKit
import CoreGraphics

// MARK: - Matching (same normalization as Sentryboard)

let leet: [Character: Character] = ["0": "o", "3": "e", "4": "a", "5": "s", "7": "t", "@": "a", "$": "s"]

/// Lowercased, accent-free, apostrophe-free, leet-mapped. "1" is ambiguous (i or l) so it yields two variants.
func normalize(_ word: String) -> Set<String> {
    let base = word.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
    var variants: [String] = [""]
    for ch in base {
        if ch == "'" || ch == "\u{2019}" { continue }
        if ch == "1" {
            variants = variants.flatMap { [$0 + "i", $0 + "l"] }
        } else {
            let mapped = leet[ch] ?? ch
            variants = variants.map { $0 + String(mapped) }
        }
    }
    return Set(variants)
}

struct Entry {
    let forms: Set<String>      // the last (or only) word
    let prefix: Bool
    let instant: Bool
    let lead: [Set<String>]     // the words before it, for a phrase such as "hello world"
}

func isWordChar(_ ch: Character) -> Bool {
    ch.isLetter || ch.isNumber || ch == "'" || ch == "\u{2019}" || ch == "_" || ch == "@" || ch == "$"
}

let maxPhraseWords = 6
let maxGap = 64  // longest run of non-word characters (spaces, punctuation, line breaks) between phrase words

/// Collapses runs of whitespace, so "hello   world" and "hello world" are the same entry.
func tidy(_ raw: String) -> String {
    raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

func parseEntry(_ raw: String) -> Entry? {
    var s = tidy(raw)
    if s.isEmpty || s.hasPrefix("#") { return nil }
    var prefix = false, instant = false
    if s.hasSuffix("*") { prefix = true; s.removeLast() }
    else if s.hasSuffix("!") { instant = true; s.removeLast() }
    let parts = s.split(separator: " ").map(String.init)
    guard (1...maxPhraseWords).contains(parts.count),
          parts.allSatisfy({ $0.allSatisfy(isWordChar) && $0.contains(where: { $0.isLetter || $0.isNumber }) }) else { return nil }
    return Entry(forms: normalize(parts.last!), prefix: prefix, instant: instant,
                 lead: parts.dropLast().map(normalize))
}

func formsMatch(_ typed: String, _ forms: Set<String>, prefix: Bool) -> Bool {
    // `@` and `$` at the very start or end of a word are ignored, so "@word" and "word$" are caught.
    let trimmed = typed.trimmingCharacters(in: CharacterSet(charactersIn: "@$"))
    let candidates = normalize(typed).union(trimmed.isEmpty ? [] : normalize(trimmed))
    for form in forms {
        for c in candidates {
            if c == form { return true }
            if prefix && c.hasPrefix(form) && c.count > form.count { return true }
        }
    }
    return false
}

/// If `text` ends with a blocked word or phrase, how many characters to delete: the phrase's words and the
/// gaps between them, not whatever came before. With `instantOnly` only `!` entries count (checked per keystroke).
func blockedLength(_ text: [Character], entries: [Entry], instantOnly: Bool) -> Int? {
    var end = text.count
    var start = end
    while start > 0 && isWordChar(text[start - 1]) { start -= 1 }
    guard start < end else { return nil }
    let last = String(text[start..<end])
    var best: Int?
    for entry in entries where !instantOnly || entry.instant {
        guard formsMatch(last, entry.forms, prefix: entry.prefix) else { continue }
        var from = start, ok = true
        for forms in entry.lead.reversed() {
            end = from
            while from > 0 && !isWordChar(text[from - 1]) { from -= 1 }
            let gap = end - from
            guard gap >= 1 && gap <= maxGap else { ok = false; break }
            end = from
            while from > 0 && isWordChar(text[from - 1]) { from -= 1 }
            guard from < end, formsMatch(String(text[from..<end]), forms, prefix: false) else { ok = false; break }
        }
        if ok { best = max(best ?? 0, text.count - from) }
        end = text.count
    }
    return best
}

// MARK: - Paths and settings

let env = ProcessInfo.processInfo.environment
let home = FileManager.default.homeDirectoryForCurrentUser
let listURL = env["WORDBLOCK_LIST"].map { URL(fileURLWithPath: $0) }
    ?? home.appendingPathComponent(".config/wordblock/words.txt")
let stateDir = env["WORDBLOCK_STATE_DIR"].map { URL(fileURLWithPath: $0) }
    ?? home.appendingPathComponent("Library/Application Support/wordblock")
let stateURL = stateDir.appendingPathComponent("state.json")
let sockPath = stateDir.appendingPathComponent("control.sock").path
let testMode = env["WORDBLOCK_TEST"] == "1"  // allows delays shorter than a minute, for testing only
let windowSeconds = Double(env["WORDBLOCK_WINDOW"] ?? "") ?? 300  // how long settings stay editable after a countdown

/// Raw, trimmed, valid entries in file order (comments and junk lines dropped).
func fileEntries(_ text: String) -> [String] {
    var seen = Set<String>(), out: [String] = []
    for line in text.split(whereSeparator: \.isNewline) {
        let s = tidy(String(line))
        if parseEntry(s) != nil && seen.insert(s).inserted { out.append(s) }
    }
    return out
}

// MARK: - CLI: --check (reads the word file only)

let args = CommandLine.arguments
let noTap = args.contains("--no-tap")  // daemon without the keyboard tap, for testing the lock
if args.count >= 3 && args[1] == "--check" {
    let text = (try? String(contentsOf: listURL, encoding: .utf8)) ?? ""
    let list = fileEntries(text).compactMap(parseEntry)
    print(blockedLength(Array(args[2...].joined(separator: " ")), entries: list, instantOnly: false) != nil ? "blocked" : "allowed")
    exit(0)
}

// MARK: - Login item install and first-run guide

let agentLabel = "com.hafiz.wordblock"
let agentPlist = home.appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
let installedApp = home.appendingPathComponent("Applications/WordBlock.app")
let cliLink = home.appendingPathComponent(".local/bin/wordblock")
let accessibilityPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

@discardableResult
func launchctl(_ arguments: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = arguments
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
    return p.terminationStatus
}

/// Registers the login item for the app at `appPath`, (re)starts it, and links the `wordblock` command.
/// The lock state lives on disk, so restarting never clears it.
func installAgent(appPath: String) throws {
    let exe = appPath + "/Contents/MacOS/WordBlock"
    let logPath = home.appendingPathComponent("Library/Logs/wordblock.log").path
    let plist: [String: Any] = [
        "Label": agentLabel,
        "ProgramArguments": [exe, "--daemon"],
        "RunAtLoad": true,
        "KeepAlive": ["SuccessfulExit": false],
        "ThrottleInterval": 5,
        "StandardOutPath": logPath,
        "StandardErrorPath": logPath,
    ]
    let fm = FileManager.default
    try fm.createDirectory(at: agentPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    launchctl(["bootout", "gui/\(getuid())/\(agentLabel)"])
    usleep(700_000)  // let launchd finish tearing the old job down before registering again
    try data.write(to: agentPlist, options: .atomic)
    launchctl(["bootstrap", "gui/\(getuid())", agentPlist.path])
    try fm.createDirectory(at: cliLink.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? fm.removeItem(at: cliLink)
    try fm.createSymbolicLink(atPath: cliLink.path, withDestinationPath: exe)
}

func ask(_ title: String, _ text: String, _ buttons: [String]) -> Int {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = text
    for b in buttons { alert.addButton(withTitle: b) }
    NSApplication.shared.activate(ignoringOtherApps: true)
    return Int(alert.runModal().rawValue) - Int(NSApplication.ModalResponse.alertFirstButtonReturn.rawValue)
}

let listHeader = """
# WordBlock word list: one word per line. Lines starting with # are ignored.
#   word    blocked when you finish typing it (space, punctuation or Enter)
#   word*   also blocks longer words that start with it
#   word!   blocked the instant it is typed

"""

func runGuide() {
    NSApplication.shared.setActivationPolicy(.accessory)

    if ask("Welcome to WordBlock",
           "WordBlock deletes words you choose, in any app, the moment you finish typing them.\n\n"
         + "It only looks at the word you are typing right now. It never saves or sends what you type, and it has no network access.\n\n"
         + "Setup takes about a minute:\n  1. Allow Accessibility access\n  2. Pick your words\n  3. Start WordBlock",
           ["Continue", "Quit"]) == 1 { return }

    if !AXIsProcessTrusted() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        var retry = false
        while !AXIsProcessTrusted() {
            let r = ask("Allow Accessibility access",
                        (retry ? "macOS still says WordBlock is off.\n\n" : "")
                      + "WordBlock needs this to see keystrokes and delete blocked words.\n\n"
                      + "Open System Settings > Privacy & Security > Accessibility and switch WordBlock on. "
                      + "If macOS asks, allow Input Monitoring too. Then come back and click \"I've turned it on\".",
                        ["Open Settings", "I've turned it on", "Quit"])
            if r == 2 { return }
            if r == 0 { NSWorkspace.shared.open(accessibilityPane) }
            retry = (r == 1)
        }
    }

    let fm = FileManager.default
    if !fm.fileExists(atPath: listURL.path) {
        try? fm.createDirectory(at: listURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? listHeader.write(to: listURL, atomically: true, encoding: .utf8)
    }
    if ask("Choose your words",
           "Your list is a plain text file with one word per line. Add \"word*\" to also block longer words that start with it, "
         + "or \"word!\" to delete it the instant it is typed.\n\nYou can change the list any time and it applies immediately.",
           ["Open the word list", "Skip for now"]) == 0 {
        NSWorkspace.shared.open(listURL)
        _ = ask("Save your list", "Come back and click Continue once you have saved your words.", ["Continue"])
    }

    // Run from a fixed place, so the login item keeps working if the download is deleted or moved.
    var appPath = Bundle.main.bundlePath
    if !["/Applications/", home.path + "/Applications/"].contains(where: { appPath.hasPrefix($0) }) {
        launchctl(["bootout", "gui/\(getuid())/\(agentLabel)"])
        try? fm.createDirectory(at: installedApp.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: installedApp)
        do {
            try fm.copyItem(at: URL(fileURLWithPath: appPath), to: installedApp)
            appPath = installedApp.path
            let x = Process()  // the user already approved this app, so the copy needn't be quarantined again
            x.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            x.arguments = ["-dr", "com.apple.quarantine", appPath]
            try? x.run(); x.waitUntilExit()
        } catch {
            _ = ask("Could not copy WordBlock", "\(error.localizedDescription)\n\nMove WordBlock.app to your Applications folder and open it again.", ["Quit"])
            return
        }
    }
    do { try installAgent(appPath: appPath) } catch {
        _ = ask("Could not start WordBlock", error.localizedDescription, ["Quit"])
        return
    }

    let exe = appPath.replacingOccurrences(of: home.path, with: "~") + "/Contents/MacOS/WordBlock"
    _ = ask("WordBlock is running",
            "It starts automatically every time you log in. Try typing one of your words in any app.\n\n"
          + "Control it from Terminal with the wordblock command:\n"
          + "  wordblock status\n  wordblock add <word>\n  wordblock lock   (removing words then waits out a countdown)\n  wordblock help   (all commands)\n\n"
          + "If Terminal says \"command not found\", add ~/.local/bin to your PATH, or run:\n\(exe) status",
            ["Done"])
}

/// What happens when the app is opened by double-click.
func runNoArgs() {
    NSApplication.shared.setActivationPolicy(.accessory)
    if let status = sendCommand("status") {
        _ = ask("WordBlock is running", status + "\nUse the wordblock command in Terminal to change settings. Run \"wordblock help\" for the list.", ["OK"])
    } else if FileManager.default.fileExists(atPath: agentPlist.path) {
        if ask("WordBlock isn't running", "Start it now?", ["Start", "Cancel"]) == 0 {
            launchctl(["bootstrap", "gui/\(getuid())", agentPlist.path])
            launchctl(["kickstart", "gui/\(getuid())/\(agentLabel)"])
        }
    } else {
        runGuide()
    }
}

// MARK: - CLI: talk to the running daemon

let commands: Set<String> = ["status", "lock", "unlock", "cancel", "add", "remove", "disable", "enable", "delay", "stop"]

let usage = """
wordblock commands:
  status            show filter, lock and countdown state
  add <entry>       add a word (always instant, even when locked)
  remove <entry>    remove a word (needs the lock to be open)
  lock [minutes]    lock the list; removing words then needs a countdown (default 60 minutes)
  unlock            start the countdown; when it ends you get a 5 minute window to make changes
  cancel            cancel a running countdown
  disable | enable  switch the filter off / on (disable needs the lock to be open)
  delay <minutes>   change the countdown length (needs the lock to be open)
  stop              quit the daemon (needs the lock to be open)
"""

func sendCommand(_ cmd: String) -> String? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var addr = makeAddr(sockPath)
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard rc == 0 else { return nil }
    _ = cmd.withCString { write(fd, $0, strlen($0)) }
    var out = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        out.append(contentsOf: buf[0..<n])
    }
    return String(decoding: out, as: UTF8.self)
}

func makeAddr(_ path: String) -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        for (i, b) in bytes.prefix(raw.count - 1).enumerated() { raw[i] = UInt8(bitPattern: b) }
    }
    return addr
}

if args.count >= 2 && args[1] == "--setup" { runGuide(); exit(0) }

if args.count >= 2 && args[1] == "--install-agent" {
    do { try installAgent(appPath: Bundle.main.bundlePath); print("login item installed"); exit(0) }
    catch { print("error: \(error.localizedDescription)"); exit(1) }
}

if args.count < 2 {
    if isatty(0) != 0 { print(usage); exit(0) }  // typed in Terminal with no command
    runNoArgs(); exit(0)                         // opened from Finder
}

if args[1] != "--no-tap" && args[1] != "--daemon" {
    guard commands.contains(args[1]) else {
        print(usage)
        exit(args[1] == "help" || args[1] == "--help" ? 0 : 2)
    }
    guard let reply = sendCommand(args.dropFirst().joined(separator: " ")) else {
        print("WordBlock isn't running. Start it with: launchctl kickstart gui/\(getuid())/com.hafiz.wordblock")
        exit(1)
    }
    print(reply, terminator: "")
    exit(reply.hasPrefix("error:") ? 2 : 0)
}

// MARK: - Daemon state

struct State: Codable {
    var locked = false
    var delay: Double = 3600       // countdown length in seconds
    var disabled = false           // master switch off (only settable while the lock is open)
    var protected: [String] = []   // the list as of the last lock; while locked it can only grow
    var pendingAt: Double? = nil   // when the unlock countdown started
    var windowEnd: Double = 0      // end of the editing window after a finished countdown
    var lastSeen: Double = 0       // latest wall-clock time seen; the clock is never allowed to go backwards
}

var state = State()
var entries: [Entry] = []
var listStamp: Date?
var tickCount = 0

func loadState() {
    guard let data = try? Data(contentsOf: stateURL) else { return }
    if let s = try? JSONDecoder().decode(State.self, from: data) {
        state = s
    } else {
        // A damaged state file counts as locked with a 30 minute countdown, like Sentryboard.
        state = State(locked: true, delay: 1800)
    }
}

func saveState() {
    try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(state) { try? data.write(to: stateURL, options: .atomic) }
}

func now() -> Double { max(Date().timeIntervalSince1970, state.lastSeen) }

/// Locked and not inside an editing window.
var isLockedNow: Bool { state.locked && now() >= state.windowEnd }

func readList() -> String { (try? String(contentsOf: listURL, encoding: .utf8)) ?? "" }

func appendLines(_ new: [String]) {
    try? FileManager.default.createDirectory(at: listURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    var text = readList()
    if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
    text += new.joined(separator: "\n") + "\n"
    try? text.write(to: listURL, atomically: true, encoding: .utf8)
}

func snapshotProtected() { state.protected = fileEntries(readList()) }

/// Rebuilds the active list from the word file. While locked, words can only be added: anything
/// missing from the file is written back, and new words join the protected set.
func syncList(force: Bool = false) {
    let stamp = (try? FileManager.default.attributesOfItem(atPath: listURL.path)[.modificationDate]) as? Date
    guard force || stamp != listStamp else { return }
    let inFile = fileEntries(readList())
    if isLockedNow {
        var grown = state.protected
        for e in inFile where !grown.contains(e) { grown.append(e) }
        if grown != state.protected { state.protected = grown; saveState() }
        let missing = state.protected.filter { !inFile.contains($0) }
        if !missing.isEmpty { appendLines(missing) }
        entries = state.protected.compactMap(parseEntry)
    } else {
        entries = inFile.compactMap(parseEntry)
    }
    listStamp = (try? FileManager.default.attributesOfItem(atPath: listURL.path)[.modificationDate]) as? Date
}

// MARK: - Commands

func fmt(_ seconds: Double) -> String {
    let t = Int(max(0, seconds.rounded(.up)))
    let h = t / 3600, m = t % 3600 / 60, s = t % 60
    var parts: [String] = []
    if h > 0 { parts.append("\(h)h") }
    if m > 0 { parts.append("\(m)m") }
    if s > 0 || parts.isEmpty { parts.append("\(s)s") }
    return parts.joined(separator: " ")
}

func validDelay(_ seconds: Double) -> Bool { seconds >= (testMode ? 1 : 60) && seconds <= 86400 }

func statusText() -> String {
    let n = now()
    var lock = "off"
    var countdown = "none"
    if state.locked {
        if n < state.windowEnd { lock = "OPEN: settings editable for \(fmt(state.windowEnd - n))" }
        else { lock = "on (countdown \(fmt(state.delay)))" }
        if let p = state.pendingAt { countdown = "running, \(fmt(p + state.delay - n)) left" }
    }
    return """
    filter:    \(state.disabled ? "OFF" : "on")
    lock:      \(lock)
    countdown: \(countdown)
    words:     \(entries.count) active

    """
}

func handle(_ line: String) -> String {
    let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
    guard let cmd = parts.first else { return "error: empty command\n" }
    let arg = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
    let locked = isLockedNow
    let needUnlock = "error: the lock is on. Run 'wordblock unlock' and wait out the countdown first.\n"

    switch cmd {
    case "status":
        return statusText()

    case "lock":
        if locked { return "error: already locked.\n" }
        var delay = state.delay
        if !arg.isEmpty {
            guard let minutes = Double(arg) else { return "error: '\(arg)' is not a number of minutes.\n" }
            delay = minutes * 60
        }
        guard validDelay(delay) else { return "error: the delay must be between 1 minute and 24 hours.\n" }
        state.delay = delay; state.locked = true; state.disabled = false
        state.pendingAt = nil; state.windowEnd = 0
        snapshotProtected(); saveState(); syncList(force: true)
        return "locked. Adding words stays instant. Removing words, turning the filter off or changing the delay now needs a \(fmt(delay)) countdown.\n"

    case "unlock":
        if !state.locked { return "the lock is off already.\n" }
        if !locked { return "already open: settings are editable for \(fmt(state.windowEnd - now())).\n" }
        if let p = state.pendingAt { return "countdown already running, \(fmt(p + state.delay - now())) left.\n" }
        state.pendingAt = now(); saveState()
        return "countdown started: \(fmt(state.delay)). Then you get \(fmt(windowSeconds)) to make changes.\n"

    case "cancel":
        if state.pendingAt == nil { return "no countdown is running.\n" }
        state.pendingAt = nil; saveState()
        return "countdown cancelled.\n"

    case "add":
        guard parseEntry(arg) != nil else {
            return "error: an entry is a word (or up to \(maxPhraseWords) words separated by spaces) of letters, digits and ' _ @ $, optionally ending in * or !\n"
        }
        let entry = tidy(arg)
        if fileEntries(readList()).contains(entry) { return "already in the list.\n" }
        appendLines([entry]); syncList(force: true)
        return "added '\(entry)'.\n"

    case "remove":
        if locked { return needUnlock }
        let lines = readList().split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let kept = lines.filter { tidy(String($0)) != tidy(arg) }
        if kept.count == lines.count { return "'\(arg)' is not in the list.\n" }
        try? (kept.joined(separator: "\n")).write(to: listURL, atomically: true, encoding: .utf8)
        syncList(force: true)
        return "removed '\(arg)'.\n"

    case "disable":
        if locked { return needUnlock }
        state.disabled = true; saveState()
        return "filter off.\n"

    case "enable":
        state.disabled = false; saveState()
        return "filter on.\n"

    case "delay":
        if locked { return needUnlock }
        guard let minutes = Double(arg), validDelay(minutes * 60) else {
            return "error: give a number of minutes between 1 and 1440.\n"
        }
        state.delay = minutes * 60; saveState()
        return "countdown length is now \(fmt(minutes * 60)).\n"

    case "stop":
        if locked { return needUnlock }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
        return "stopping.\n"

    default:
        return "error: unknown command.\n"
    }
}

func tick() {
    tickCount += 1
    let n = max(Date().timeIntervalSince1970, state.lastSeen)
    state.lastSeen = n
    var changed = false
    if let p = state.pendingAt, n >= p + state.delay {
        state.pendingAt = nil; state.windowEnd = n + windowSeconds; changed = true
    }
    if state.windowEnd > 0 && n >= state.windowEnd {
        state.windowEnd = 0; changed = true
        if state.locked { snapshotProtected() }  // whatever the list is now becomes the protected list
    }
    if changed || tickCount % 30 == 0 { saveState() }
    syncList(force: changed)
    if tapRef == nil { installTap() }
}

// MARK: - Control socket

func serve(_ client: Int32) {
    defer { close(client) }
    var tv = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var buf = [UInt8](repeating: 0, count: 1024)
    let n = read(client, &buf, buf.count - 1)
    guard n > 0 else { return }
    let line = String(decoding: buf[0..<n], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    let reply = DispatchQueue.main.sync { handle(line) }
    _ = reply.withCString { write(client, $0, strlen($0)) }
}

func startServer() {
    try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    unlink(sockPath)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = makeAddr(sockPath)
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard fd >= 0, rc == 0, listen(fd, 8) == 0 else {
        FileHandle.standardError.write(Data("Could not open the control socket at \(sockPath).\n".utf8))
        exit(1)
    }
    chmod(sockPath, 0o600)
    Thread.detachNewThread {
        while true {
            let client = accept(fd, nil, nil)
            if client >= 0 { serve(client) }
        }
    }
}

// MARK: - Event tap

let marker: Int64 = 0x57_42_4C_4B  // "WBLK": tags events we post ourselves so the tap ignores them
let kBackspace: CGKeyCode = 51
var tail: [Character] = []  // recent text typed since the last reset, separators included
var tapRef: CFMachPort?

func post(keyCode: CGKeyCode, flags: CGEventFlags = [], text: String? = nil) {
    for down in [true, false] {
        guard let e = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down) else { continue }
        e.flags = flags
        e.setIntegerValueField(.eventSourceUserData, value: marker)
        if let text = text {
            let u = Array(text.utf16)
            e.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u)
        }
        e.post(tap: .cghidEventTap)
    }
}

func backspaces(_ n: Int) { for _ in 0..<n { post(keyCode: kBackspace) } }

func callback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = tapRef { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    if type == .leftMouseDown || type == .rightMouseDown { tail.removeAll(); return Unmanaged.passUnretained(event) }
    guard type == .keyDown, event.getIntegerValueField(.eventSourceUserData) != marker, !state.disabled else {
        tail.removeAll()
        return Unmanaged.passUnretained(event)
    }

    let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
    let flags = event.flags

    // Shortcuts (paste, select all, ...) change the text without us seeing it: forget the word.
    if flags.contains(.maskCommand) || flags.contains(.maskControl) { tail.removeAll(); return Unmanaged.passUnretained(event) }

    if keyCode == kBackspace {
        if flags.contains(.maskAlternate) { tail.removeAll() } else { _ = tail.popLast() }  // Option+Delete eats a whole word
        return Unmanaged.passUnretained(event)
    }

    var len = 0
    var chars = [UniChar](repeating: 0, count: 8)
    event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &len, unicodeString: &chars)
    let typed = String(utf16CodeUnits: chars, count: len)
    guard let ch = typed.first, typed.count == 1 else { tail.removeAll(); return Unmanaged.passUnretained(event) }

    // Arrows, Escape, function keys etc. arrive as control or private-use characters: the cursor moved.
    let scalar = ch.unicodeScalars.first!.value
    let isSeparatorKey = ch == " " || ch == "\r" || ch == "\n" || ch == "\t" || ch == "\u{3}"
    if !isSeparatorKey && (scalar < 0x20 || scalar == 0x7F || (0xF700...0xF8FF).contains(scalar)) {
        tail.removeAll()
        return Unmanaged.passUnretained(event)
    }

    if isWordChar(ch) {
        tail.append(ch)
        if tail.count > 2000 { tail.removeFirst(500) }
        if let n = blockedLength(tail, entries: entries, instantOnly: true) {
            // Swallow the last key and erase what came before it, so the word never fully appears.
            backspaces(n - 1)
            tail.removeLast(n)
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    // A separator ended the word. Underscore is a word char above, so "my_word" is handled at its own end.
    if let n = blockedLength(tail, entries: entries, instantOnly: false) {
        // Erase the word or phrase, then re-send the separator so it lands after the deletion.
        backspaces(n)
        tail.removeLast(n)
        tail.append(ch)
        post(keyCode: keyCode, flags: flags, text: typed)
        return nil
    }
    tail.append(ch)
    return Unmanaged.passUnretained(event)
}

let tapMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
    | (1 << CGEventType.leftMouseDown.rawValue)
    | (1 << CGEventType.rightMouseDown.rawValue)

/// Creates the tap once Accessibility access exists. Called every second until it succeeds, so granting
/// the permission while the daemon is running is enough; no restart is needed.
func installTap() {
    guard !noTap, AXIsProcessTrusted(),
          let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                      eventsOfInterest: tapMask, callback: callback, userInfo: nil) else { return }
    tapRef = tap
    CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    print("event tap active")
}

// MARK: - Daemon main

setvbuf(stdout, nil, _IOLBF, 0)  // line-buffer so messages reach a redirected log file
loadState()
syncList(force: true)
startServer()

if !noTap {
    if !AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) {
        print("waiting for Accessibility access (System Settings > Privacy & Security > Accessibility)")
    }
    // Switching apps moves the cursor somewhere else.
    NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { _ in
        tail.removeAll()
    }
}

Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in tick() }

print("wordblock running (lock \(state.locked ? "on" : "off")). \(entries.count) words from \(listURL.path)")
installTap()
CFRunLoopRun()
