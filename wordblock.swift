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
// Pasted text is checked too: blocked words are cut out of the clipboard before the app pastes it.
//
// Opened by double-click it shows a first-run guide (or the current status once set up).
// `--daemon` is the background program launchd starts at login. With a command
// (`wordblock status`, `lock`, `unlock`, ...) it talks to the running daemon.
//
// Needs Accessibility permission (System Settings > Privacy & Security > Accessibility).

import AppKit
import CoreGraphics
import CryptoKit

// MARK: - Matching (same normalization as Sentryboard)

let leet: [Character: Character] = ["0": "o", "3": "e", "4": "a", "5": "s", "7": "t", "@": "a", "$": "s"]

/// Letters of other alphabets drawn like a Latin letter, read as that letter, so a Cyrillic "e" in "hello"
/// does not hide it. Applied to entries too, so an entry written in one of these alphabets still matches itself.
let lookalike: [Character: Character] = [
    "\u{0430}": "a", "\u{0435}": "e", "\u{043e}": "o", "\u{0440}": "p", "\u{0441}": "c", "\u{0445}": "x",
    "\u{0443}": "y", "\u{0456}": "i", "\u{0458}": "j", "\u{0455}": "s", "\u{043a}": "k", "\u{04bb}": "h",
    "\u{04cf}": "l", "\u{0501}": "d", "\u{051b}": "q", "\u{051d}": "w",                                   // Cyrillic
    "\u{03bf}": "o", "\u{03b1}": "a", "\u{03bd}": "v", "\u{03c1}": "p", "\u{03b9}": "i", "\u{03ba}": "k",
    "\u{03c5}": "u", "\u{03c7}": "x", "\u{03b5}": "e", "\u{03f2}": "c",                                   // Greek
    "\u{0131}": "i", "\u{0251}": "a", "\u{0261}": "g",                                                     // Latin letters folding leaves alone
]

extension Character {
    /// A zero-width space, joiner, soft hyphen and the like: invisible, so it can hide a word.
    var isFormatChar: Bool { unicodeScalars.allSatisfy { $0.properties.generalCategory == .format } }
    /// An accent written as a character of its own.
    var isMarkChar: Bool {
        unicodeScalars.allSatisfy { $0.properties.generalCategory == .nonspacingMark || $0.properties.generalCategory == .enclosingMark }
    }
}

extension Unicode.Scalar {
    /// Invisible, or attached to the letter before or after it (zero-width characters, joiners, accents). These are
    /// ignored when words are compared. They are looked at one scalar at a time because Swift glues a joiner onto
    /// the neighbouring letter, so a "Character" containing one is not itself a format character.
    var isInvisibleInWord: Bool {
        switch properties.generalCategory {
        case .format, .nonspacingMark, .enclosingMark: return true
        default: return false
        }
    }
}

/// A word in comparison form: lowercase, without accents, apostrophes or invisible characters, with look-alike
/// letters read as Latin and the leet symbols as the letters they stand for. A "1" stays "1" because it stands
/// for either "i" or "l" (see `sameLetter`); spelling out both versions of every "1" grows exponentially.
func normalize(_ word: String) -> [Character] {
    let base = word.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
    var out: [Character] = []
    out.reserveCapacity(base.utf8.count)
    for scalar in base.unicodeScalars {
        if scalar.isInvisibleInWord || scalar == "'" || scalar == "\u{2019}" { continue }
        let ch = Character(scalar)
        out.append(lookalike[ch] ?? leet[ch] ?? ch)
    }
    return out
}

func sameLetter(_ a: Character, _ b: Character) -> Bool {
    if a == b { return true }
    if a == "1" { return b == "i" || b == "l" }
    if b == "1" { return a == "i" || a == "l" }
    return false
}

/// `word` is the entry's word, or with `prefix` a longer word that starts with it.
func sameWord(_ word: [Character], _ entryWord: [Character], prefix: Bool) -> Bool {
    if word.count == entryWord.count || (prefix && word.count > entryWord.count) {
        return zip(word, entryWord).allSatisfy(sameLetter)
    }
    return false
}

struct Entry {
    let forms: [Character]      // the last (or only) word, in comparison form
    let prefix: Bool
    let instant: Bool
    let lead: [[Character]]     // the words before it, for a phrase such as "hello world"
}

/// Letters, digits, apostrophes, underscores and the leet symbols `@` and `$` make up words, and so do invisible
/// characters (see `isInvisibleInWord`). A "Character" can be several scalars glued together (a letter and the
/// joiner after it, or a number sign that attaches to the letter after it), so it counts as a word character
/// when the first scalar that is not invisible is a letter or digit. An emoji joined with joiners is not.
func isWordChar(_ ch: Character) -> Bool {
    if let a = ch.asciiValue {
        return (a >= 48 && a <= 57) || (a >= 65 && a <= 90) || (a >= 97 && a <= 122) || a == 39 || a == 95 || a == 64 || a == 36
    }
    for scalar in ch.unicodeScalars where !scalar.isInvisibleInWord {
        let c = Character(scalar)
        return c.isLetter || c.isNumber || c == "\u{2019}"
    }
    return true  // nothing but invisible characters
}

let maxPhraseWords = 6
let maxDelete = 400  // never erase more than this many typed characters for one match, whatever a read of the text says
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
    let words = parts.map(normalize)
    guard words.allSatisfy({ !$0.isEmpty }) else { return nil }
    return Entry(forms: words.last!, prefix: prefix, instant: instant, lead: Array(words.dropLast()))
}

/// The spellings of a word to compare: as written, and without `@` or `$` at its very start or end
/// ("@word", "word$" are caught).
func spellings(_ word: String) -> [[Character]] {
    var out = [normalize(word)]
    let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: "@$"))
    if trimmed != word && !trimmed.isEmpty { out.append(normalize(trimmed)) }
    return out.filter { !$0.isEmpty }
}

func formsMatch(_ spellings: [[Character]], _ entryWord: [Character], prefix: Bool) -> Bool {
    spellings.contains { sameWord($0, entryWord, prefix: prefix) }
}

/// If `text` (up to `limit`) ends with a blocked word or phrase, how many characters to delete: the phrase's words
/// and the gaps between them, not whatever came before. With `instantOnly` only `!` entries count (checked per
/// keystroke). An underscore normally belongs to a word ("snake_case"), but it also separates words, so
/// "snake_word" is judged both ways.
func blockedLength(_ text: [Character], entries: [Entry], instantOnly: Bool, upTo limit: Int? = nil) -> Int? {
    let total = min(limit ?? text.count, text.count)
    guard total > 0 else { return nil }
    let relevant = instantOnly ? entries.filter { $0.instant } : entries
    guard !relevant.isEmpty else { return nil }
    var best = blockedLengthPass(text, total, relevant, underscoreSplits: false)
    if text[max(0, total - maxDelete)..<total].contains("_"),
       let n = blockedLengthPass(text, total, relevant, underscoreSplits: true) {
        best = max(best ?? 0, n)
    }
    return best
}

private func blockedLengthPass(_ text: [Character], _ total: Int, _ entries: [Entry], underscoreSplits: Bool) -> Int? {
    func wordy(_ c: Character) -> Bool { isWordChar(c) && !(underscoreSplits && c == "_") }
    var start = total
    while start > 0 && wordy(text[start - 1]) { start -= 1 }
    guard start < total else { return nil }
    let last = spellings(String(text[start..<total]))
    guard !last.isEmpty else { return nil }
    var best: Int?
    for entry in entries where formsMatch(last, entry.forms, prefix: entry.prefix) {
        var from = start, ok = true
        for lead in entry.lead.reversed() {
            var end = from
            while from > 0 && !wordy(text[from - 1]) { from -= 1 }
            let gap = end - from
            guard gap >= 1 && gap <= maxGap else { ok = false; break }
            end = from
            while from > 0 && wordy(text[from - 1]) { from -= 1 }
            guard from < end, formsMatch(spellings(String(text[from..<end])), lead, prefix: false) else { ok = false; break }
        }
        if ok && total - from <= maxDelete { best = max(best ?? 0, total - from) }
    }
    return best
}

let maxScan = 20_000  // the most characters of a paste that are scanned
let maxRun = 256      // a run of letters longer than this is not a word and is not looked at in pasted text

/// Every blocked word and phrase in a block of text, such as a paste, as [start, end) character ranges that
/// do not overlap (the widest match wins). The text is also read with "_" and with invisible characters as
/// separators, so "my_word" and "hello<zero width space>world" are caught. Only the first `maxScan` characters
/// are scanned.
func blockedSpans(_ input: [Character], entries: [Entry]) -> [Range<Int>] {
    guard !entries.isEmpty, !input.isEmpty else { return [] }
    let limit = min(input.count, maxScan)
    let text = input.count > limit + maxRun ? Array(input[0..<(limit + maxRun)]) : input
    let cutShort = text.count < input.count  // the last word in `text` may continue past it
    var variants = [text]
    let hasUnderscore = text.contains("_"), hasFormat = text.contains { $0.isFormatChar }
    if hasUnderscore { variants.append(text.map { $0 == "_" ? " " : $0 }) }
    if hasFormat { variants.append(text.map { $0.isFormatChar ? " " : $0 }) }
    if hasUnderscore && hasFormat { variants.append(text.map { $0 == "_" || $0.isFormatChar ? " " : $0 }) }

    var found: [Range<Int>] = []
    for v in variants {
        var i = 0
        while i < v.count {
            guard isWordChar(v[i]) else { i += 1; continue }
            var j = i
            while j < v.count && isWordChar(v[j]) { j += 1 }
            let complete = !(cutShort && j == v.count)
            if i < limit, complete, j - i <= maxRun, let n = blockedLength(v, entries: entries, instantOnly: false, upTo: j) {
                found.append((j - n)..<j)
            }
            i = j
        }
    }
    found.sort { $0.count != $1.count ? $0.count > $1.count : $0.lowerBound < $1.lowerBound }
    var kept: [Range<Int>] = []
    for r in found where !kept.contains(where: { $0.overlaps(r) }) { kept.append(r) }
    return kept.sorted { $0.lowerBound < $1.lowerBound }
}

/// The text without the given ranges. A removal that would leave a doubled space (or a space at the edge of a
/// line) takes one neighbouring space with it.
func removeSpans(_ text: [Character], _ spans: [Range<Int>]) -> [Character] {
    func inlineSpace(_ c: Character) -> Bool { c == " " || c == "\t" }
    var cut = [Bool](repeating: false, count: text.count)
    for r in spans {
        for i in r { cut[i] = true }
        let before = r.lowerBound > 0 ? text[r.lowerBound - 1] : nil
        let after = r.upperBound < text.count ? text[r.upperBound] : nil
        if let b = before, inlineSpace(b), after == nil || inlineSpace(after!) || after!.isNewline || ",.;:!?)]}".contains(after!) {
            cut[r.lowerBound - 1] = true
        } else if before == nil || before!.isNewline, let a = after, inlineSpace(a) {
            cut[r.upperBound] = true
        }
    }
    return text.enumerated().filter { !cut[$0.offset] }.map { $0.element }
}

// MARK: - Versions

/// Whether version `a` is newer than `b` ("1.10.0" is newer than "1.9.2"). A `b` that is unknown, or not a dotted
/// number (a development build), counts as older than anything.
func versionIsNewer(_ a: String, than b: String?) -> Bool {
    func parts(_ v: String) -> [Int]? {
        let p = v.split(separator: ".").map { Int($0) }
        return p.isEmpty || p.contains(where: { $0 == nil }) ? nil : p.map { $0! }
    }
    guard let b = b, let pb = parts(b) else { return true }
    guard let pa = parts(a) else { return false }
    for i in 0..<max(pa.count, pb.count) {
        let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
        if x != y { return x > y }
    }
    return false
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
    if text.hasPrefix("# WordBlock word list. The lock is on") { print("the list is hidden while the lock is on"); exit(3) }
    let list = fileEntries(text).compactMap(parseEntry)
    print(blockedSpans(Array(args[2...].joined(separator: " ")), entries: list).isEmpty ? "allowed" : "blocked")
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

struct AgentError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// True once the daemon answers on its control socket (it opens it before anything else, even while it is
/// still waiting for Accessibility access).
func daemonAnswers(within seconds: Double) -> Bool {
    let start = Date()
    repeat {
        if sendCommand("status") != nil { return true }
        usleep(250_000)
    } while Date().timeIntervalSince(start) < seconds
    return false
}

/// Registers the login item for the app at `appPath`, (re)starts it, and links the `wordblock` command.
/// The lock state lives on disk, so restarting never clears it. Throws if the daemon does not come up.
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
    try fm.createDirectory(at: cliLink.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? fm.removeItem(at: cliLink)
    try fm.createSymbolicLink(atPath: cliLink.path, withDestinationPath: exe)

    for attempt in 1...2 {
        launchctl(["bootout", "gui/\(getuid())/\(agentLabel)"])
        usleep(attempt == 1 ? 700_000 : 1_500_000)  // let launchd finish tearing the old job down before registering again
        try data.write(to: agentPlist, options: .atomic)
        launchctl(["bootstrap", "gui/\(getuid())", agentPlist.path])
        if daemonAnswers(within: 6) { return }
    }
    throw AgentError("macOS did not start WordBlock. Check ~/Library/Logs/wordblock.log, or run: launchctl bootstrap gui/\(getuid()) \(agentPlist.path)")
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

/// The login item has to run from a fixed place, so it keeps working if the download is deleted or moved. An app
/// that is not in an Applications folder is copied to ~/Applications first (the old copy is only replaced once
/// the new one is in place). Returns the path to run from, or nil after telling the user what went wrong.
func stablePath(for appPath: String) -> String? {
    if ["/Applications/", home.path + "/Applications/"].contains(where: { appPath.hasPrefix($0) }) { return appPath }
    let fm = FileManager.default
    let staging = installedApp.deletingLastPathComponent().appendingPathComponent("WordBlock.app.new")
    do {
        try fm.createDirectory(at: installedApp.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: staging)
        try fm.copyItem(at: URL(fileURLWithPath: appPath), to: staging)
        let x = Process()  // the user already approved this app, so the copy needn't be quarantined again
        x.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        x.arguments = ["-dr", "com.apple.quarantine", staging.path]
        try? x.run(); x.waitUntilExit()
        launchctl(["bootout", "gui/\(getuid())/\(agentLabel)"])
        try? fm.removeItem(at: installedApp)
        try fm.moveItem(at: staging, to: installedApp)
        return installedApp.path
    } catch {
        try? fm.removeItem(at: staging)
        _ = ask("Could not copy WordBlock", "\(error.localizedDescription)\n\nMove WordBlock.app to your Applications folder and open it again.", ["Quit"])
        return nil
    }
}

func appVersion() -> String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }

func runGuide() {
    NSApplication.shared.setActivationPolicy(.accessory)

    if ask("Welcome to WordBlock",
           "WordBlock deletes words you choose, in any app, the moment you finish typing them. It checks pasted text too.\n\n"
         + "It keeps what you type in memory only, to recognise your words. It never saves or sends it, and it has no network access.\n\n"
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

    guard let appPath = stablePath(for: Bundle.main.bundlePath) else { return }
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
        // Replacing the app on disk does not restart the program that is already running: offer to.
        let running = status.split(separator: "\n").first { $0.hasPrefix("version:") }.map { $0.dropFirst(8).trimmingCharacters(in: .whitespaces) }
        if appVersion() != "dev" && running != appVersion() && versionIsNewer(appVersion(), than: running) {
            let was = running.map { "version \($0)" } ?? "an older version"
            if ask("WordBlock was updated", "WordBlock is running \(was), and this app is version \(appVersion()). Restart it so the new version runs? Your words and lock are kept.",
                   ["Restart", "Not now"]) == 0, let path = stablePath(for: Bundle.main.bundlePath) {
                do { try installAgent(appPath: path); _ = ask("WordBlock restarted", "Now running version \(appVersion()).", ["OK"]) }
                catch { _ = ask("Could not restart WordBlock", error.localizedDescription, ["OK"]) }
            }
            return
        }
        _ = ask("WordBlock is running", status + "\nUse the wordblock command in Terminal to change settings. Run \"wordblock help\" for the list.", ["OK"])
    } else if FileManager.default.fileExists(atPath: agentPlist.path) {
        if ask("WordBlock isn't running", "Start it now?", ["Start", "Cancel"]) == 0 {
            launchctl(["bootstrap", "gui/\(getuid())", agentPlist.path])
            launchctl(["kickstart", "gui/\(getuid())/\(agentLabel)"])
            if !daemonAnswers(within: 6) {
                _ = ask("Could not start WordBlock", "Check ~/Library/Logs/wordblock.log for the reason.", ["OK"])
            }
        }
    } else {
        runGuide()
    }
}

// MARK: - CLI: talk to the running daemon

let commands: Set<String> = ["status", "lock", "unlock", "cancel", "add", "remove", "disable", "enable", "paste", "delay", "stop"]

let usage = """
wordblock commands:
  status            show filter, lock and countdown state
  add <entry>       add a word (always instant, even when locked)
  remove <entry>    remove a word (needs the lock to be open)
  lock [minutes]    lock the list; removing words then needs a countdown (default 60 minutes)
  unlock            start the countdown; when it ends you get a 5 minute window to make changes
  cancel            cancel a running countdown
  disable | enable  switch the filter off / on (disable needs the lock to be open)
  paste on | off    check pasted text too (off needs the lock to be open)
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
    var tv = timeval(tv_sec: 10, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    _ = cmd.withCString { write(fd, $0, strlen($0)) }
    var out = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &buf, buf.count)
        if n < 0 && errno == EINTR { continue }
        if n < 0 && out.isEmpty { return "error: WordBlock did not answer in time. Try again.\n" }
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
    var pasteOff: Bool? = nil      // paste checking off (only settable while the lock is open); optional so older saves still load
    var protected: [String] = []   // the list as of the last lock, scrambled (see encode); while locked it can only grow
    var pendingAt: Double? = nil   // when the unlock countdown started
    var windowEnd: Double = 0      // end of the editing window after a finished countdown
    var lastSeen: Double = 0       // latest wall-clock time seen; the clock is never allowed to go backwards
}

var state = State()
var entries: [Entry] = []
var listStamp: Date?
var tickCount = 0

// MARK: - Tamper-resistant state
//
// The state is saved in three places at once (state.json, a preferences file and a backup in Caches), each
// copy signed with a random key kept in its own file. On start the newest copy with a valid signature wins
// and the others are rewritten from it. So editing one copy, deleting one, or putting back an old one all
// get undone. If copies exist but none is valid, the state counts as damaged: locked with 30 minutes, and
// the protected words from every readable copy are kept (they can only grow, never shrink).
// The key is a plain file, so this stops hand edits, not someone who works out how it is signed.
// (The keychain would be better but ties access to the exact build, so every update would lose the key.)

let prefs = UserDefaults(suiteName: env["WORDBLOCK_PREFS_SUITE"] ?? "com.hafiz.wordblock.state")!
let keyURL = stateDir.appendingPathComponent("key")
let backupURL = (env["WORDBLOCK_BACKUP_DIR"].map { URL(fileURLWithPath: $0) }
    ?? home.appendingPathComponent("Library/Caches/com.hafiz.wordblock")).appendingPathComponent("state.bak")
let fallbackKey = SymmetricKey(data: SHA256.hash(data: Data("wordblock-fallback-key".utf8)))
var signKey = fallbackKey
var stateRev = 0
var lastWritten: Data?

struct Envelope: Codable {
    var rev: Int
    var state: String  // the State as JSON text, signed byte for byte
    var sig: String
}

/// Loads the signing key, creating it on first use.
func initKeys() {
    if let d = try? Data(contentsOf: keyURL), d.count == 32 { signKey = SymmetricKey(data: d); return }
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, 32, &bytes) == errSecSuccess else { return }
    try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    if (try? Data(bytes).write(to: keyURL, options: .atomic)) != nil {
        chmod(keyURL.path, 0o600)
        signKey = SymmetricKey(data: bytes)
    }
}

func sign(_ rev: Int, _ stateJSON: String) -> String {
    Data(HMAC<SHA256>.authenticationCode(for: Data("\(rev).\(stateJSON)".utf8), using: signKey)).map { String(format: "%02x", $0) }.joined()
}

/// The state inside a copy, whether or not its signature checks out.
func parseCopy(_ data: Data) -> (env: Envelope, state: State)? {
    guard let env = try? JSONDecoder().decode(Envelope.self, from: data),
          let st = try? JSONDecoder().decode(State.self, from: Data(env.state.utf8)) else { return nil }
    return (env, st)
}

func openCopy(_ data: Data) -> (rev: Int, state: State)? {
    guard let (env, st) = parseCopy(data), env.sig == sign(env.rev, env.state) else { return nil }
    return (env.rev, st)
}

func readCopies() -> [Data] {
    [try? Data(contentsOf: stateURL), prefs.data(forKey: "state"), try? Data(contentsOf: backupURL)].compactMap { $0 }
}

func loadState() {
    initKeys()
    let copies = readCopies()
    let valid = copies.compactMap(openCopy)
    if let best = valid.max(by: { $0.rev < $1.rev }) {
        state = best.state; stateRev = best.rev
        if copies.count < 3 || valid.count < copies.count || valid.contains(where: { $0.rev != best.rev }) { saveState() }
        else { lastWritten = try? Data(contentsOf: stateURL) }
        return
    }
    guard !copies.isEmpty else { return }  // first run
    if let file = try? Data(contentsOf: stateURL), let old = try? JSONDecoder().decode(State.self, from: file) {
        state = old; saveState(); return  // an unsigned state.json from before signing existed
    }
    // Damaged or edited: locked with a 30 minute countdown, like Sentryboard. Keep every protected word any
    // readable copy still has, so a bad signature can never cost the list.
    var words: [String] = []
    for c in copies { for w in parseCopy(c)?.state.protected ?? [] where !words.contains(w) { words.append(w) } }
    state = State(locked: true, delay: 1800, protected: words); saveState()
}

func saveState() {
    stateRev += 1
    guard let json = try? JSONEncoder().encode(state), let text = String(data: json, encoding: .utf8),
          let data = try? JSONEncoder().encode(Envelope(rev: stateRev, state: text, sig: sign(stateRev, text))) else { return }
    try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: stateURL, options: .atomic)
    try? data.write(to: backupURL, options: .atomic)
    prefs.set(data, forKey: "state")
    lastWritten = data
}

/// Called every few seconds: if state.json no longer matches what was last written (edited, deleted,
/// replaced), write the real state back over it.
func guardStateFile() {
    if (try? Data(contentsOf: stateURL)) != lastWritten { saveState() }
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

/// The protected list is stored base64-encoded so it is not readable at a glance in state.json. This hides
/// the words from a casual look, nothing more; the program has to be able to read them back.
func encode(_ word: String) -> String { "b64:" + Data(word.utf8).base64EncodedString() }
func decode(_ stored: String) -> String {
    guard stored.hasPrefix("b64:"), let d = Data(base64Encoded: String(stored.dropFirst(4))) else { return stored }
    return String(decoding: d, as: UTF8.self)
}
func protectedWords() -> [String] { state.protected.map(decode) }
func setProtected(_ words: [String]) { state.protected = words.map(encode) }

let hiddenMarker = "# WordBlock word list. The lock is on"
func fileIsHidden() -> Bool { readList().hasPrefix(hiddenMarker) }

/// Makes whatever the file holds the protected list. A file still showing the placeholder (the daemon was
/// stopped while the window was open) adds nothing but must never wipe the list.
func snapshotProtected() {
    let inFile = fileEntries(readList())
    setProtected(fileIsHidden() ? protectedWords() + inFile.filter { !protectedWords().contains($0) } : inFile)
}

/// What words.txt holds while the lock is on: the count, not the words. A word typed below is picked up
/// within a second, added to the protected list and hidden again.
func hiddenListText(count: Int) -> String {
    """
    \(hiddenMarker), so the \(count) word\(count == 1 ? " is" : "s are") hidden.
    # To add a word, type it on a new line below and save. It is picked up within a second and hidden again.
    # The words show here again after 'wordblock unlock' and the countdown.

    """
}

var fileHidden = false  // words.txt currently holds the placeholder instead of the words

/// Rebuilds the active list from the word file. While locked, words can only be added and the file shows a
/// placeholder instead of the words: anything typed into it joins the protected set and is hidden again.
/// When the editing window opens the words are written back into the file.
func syncList(force: Bool = false) {
    let stamp = (try? FileManager.default.attributesOfItem(atPath: listURL.path)[.modificationDate]) as? Date
    guard force || stamp != listStamp else { return }
    let inFile = fileEntries(readList())
    if isLockedNow {
        var grown = protectedWords()
        for e in inFile where !grown.contains(e) { grown.append(e) }
        if grown != protectedWords() || state.protected.contains(where: { !$0.hasPrefix("b64:") }) {
            setProtected(grown); saveState()
        }
        let hidden = hiddenListText(count: grown.count)
        if readList() != hidden || !fileHidden {
            try? FileManager.default.createDirectory(at: listURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? hidden.write(to: listURL, atomically: true, encoding: .utf8)
        }
        fileHidden = true
        entries = grown.compactMap(parseEntry)
    } else {
        if fileHidden {
            // The window just opened: show the words again, plus anything added while they were hidden.
            let words = protectedWords()
            try? (listHeader + words.joined(separator: "\n") + "\n").write(to: listURL, atomically: true, encoding: .utf8)
            fileHidden = false
            entries = words.compactMap(parseEntry)
        } else {
            entries = inFile.compactMap(parseEntry)
        }
    }
    listStamp = (try? FileManager.default.attributesOfItem(atPath: listURL.path)[.modificationDate]) as? Date
    pasteboardSeen = -1  // the words changed: look at the clipboard again
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
    version:   \(appVersion())
    filter:    \(state.disabled ? "OFF" : "on")
    paste:     \(state.pasteOff == true ? "OFF" : "checked")
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
        state.delay = delay; state.locked = true; state.disabled = false; state.pasteOff = nil
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
        if locked {
            // The list is hidden, so the answer must not reveal whether the word was already on it.
            if !protectedWords().contains(entry) { appendLines([entry]); syncList(force: true) }
            return "that word is on the list. The list is hidden while the lock is on.\n"
        }
        if fileEntries(readList()).contains(entry) { return "already in the list.\n" }
        appendLines([entry]); syncList(force: true)
        return "added '\(entry)'.\n"

    case "remove":
        if locked { return needUnlock }
        if arg.isEmpty { return "error: give the entry to remove, for example: wordblock remove someword\n" }
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
        state.disabled = false; pasteboardSeen = -1; saveState()
        return "filter on.\n"

    case "paste":
        switch arg {
        case "on": state.pasteOff = nil; pasteboardSeen = -1; saveState(); return "paste checking on.\n"
        case "off":
            if locked { return needUnlock }
            state.pasteOff = true; saveState(); return "paste checking off.\n"
        default: return "error: use 'wordblock paste on' or 'wordblock paste off'.\n"
        }

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
    else if tickCount % 3 == 0 { guardStateFile() }
    syncList(force: changed)
    checkTap()
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
    let oldMask = umask(0o177)  // owner only from the moment the socket exists
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    umask(oldMask)
    guard fd >= 0, rc == 0, listen(fd, 8) == 0 else {
        FileHandle.standardError.write(Data("Could not open the control socket at \(sockPath).\n".utf8))
        exit(1)
    }
    chmod(sockPath, 0o600)
    Thread.detachNewThread {
        while true {
            let client = accept(fd, nil, nil)
            if client >= 0 { serve(client) } else { usleep(100_000) }  // do not spin if accept keeps failing
        }
    }
}

// MARK: - Pasted text
//
// The filter works on the clipboard before the app reads it: on the paste keystroke, and by polling the
// clipboard so a menu or right-click paste is covered too. Only the blocked words and phrases are cut out;
// the rest of the paste stays. The result is plain text, so rich formatting is lost when something is removed.

let pasteboard = env["WORDBLOCK_PASTEBOARD"].map { NSPasteboard(name: NSPasteboard.Name($0)) } ?? NSPasteboard.general
let skipTypes = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
                 "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword"].map { NSPasteboard.PasteboardType($0) }
var pasteboardSeen = -1  // changeCount of the clipboard as last checked or written by us

var pasteChecked: Bool { !state.disabled && state.pasteOff != true }

/// The clipboard's text, unless it is a password manager's, a file copy, or has no text.
func clipboardText() -> String? {
    let types = pasteboard.types ?? []
    if types.contains(where: { skipTypes.contains($0) }) || types.contains(.fileURL) { return nil }
    return pasteboard.string(forType: .string)
}

func writeClipboard(_ text: String) {
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    pasteboardSeen = pasteboard.changeCount
}

var axPausedUntil = Date.distantPast

/// Runs an Accessibility read. These happen on the thread that handles keystrokes, so if one is slow (the app is
/// busy or hung) Accessibility is left alone for a few seconds rather than holding up typing.
func timedAX<T>(_ read: () -> T?) -> T? {
    guard Date() >= axPausedUntil else { return nil }
    let start = Date()
    let result = read()
    if Date().timeIntervalSince(start) > 0.04 { axPausedUntil = Date().addingTimeInterval(5) }
    return result
}

/// The focused text field of the frontmost app and its selection, read through Accessibility. Nil when the app
/// does not expose its text (some browsers and Electron apps) or the field is a password field.
func focusedField() -> (element: AXUIElement, selection: CFRange)? {
    guard AXIsProcessTrusted() else { return nil }
    // The system-wide element often answers "cannot complete"; asking the frontmost app directly is reliable.
    guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.05)  // never hold up typing on a slow app
    var focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
          let focused = focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
    let element = focused as! AXUIElement
    var role: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
       (role as? String) == "AXSecureTextField" { return nil }
    var selection: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selection) == .success,
          let selection = selection, CFGetTypeID(selection) == AXValueGetTypeID() else { return nil }
    var range = CFRange()
    guard AXValueGetValue(selection as! AXValue, .cfRange, &range) else { return nil }
    return (element, range)
}

func fieldString(_ element: AXUIElement, _ start: Int, _ length: Int) -> String? {
    if length <= 0 { return "" }
    var range = CFRange(location: start, length: length)
    guard let value = AXValueCreate(.cfRange, &range) else { return nil }
    var text: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                     value, &text) == .success else { return nil }
    return text as? String
}

/// The text just before the cursor, so a phrase can be recognised after a click, an arrow key, a cut or a paste
/// made WordBlock forget what was typed. Whole words only (a word cut off at the start is dropped).
func textBeforeCursor(limit: Int = 200) -> [Character]? {
    timedAX {
        guard let (element, cursor) = focusedField() else { return nil }
        if cursor.location <= 0 { return [] }
        let start = max(0, cursor.location - limit)
        guard let string = fieldString(element, start, cursor.location - start) else { return nil }
        var chars = Array(string)
        if start > 0 { while let first = chars.first, isWordChar(first) { chars.removeFirst() } }
        return chars
    }
}

/// The text on both sides of the cursor (nothing selected), whole words only at the cut-off ends.
func textAroundCursor(limit: Int = 200, needTextAfter: Bool = false) -> (before: [Character], after: [Character])? {
    timedAX {
        guard let (element, cursor) = focusedField(), cursor.length == 0 else { return nil }
        var count: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &count) == .success,
              let total = (count as? NSNumber)?.intValue, cursor.location <= total else { return nil }
        if needTextAfter && cursor.location == total { return nil }  // nothing after the cursor: nothing new to find
        let start = max(0, cursor.location - limit)
        let afterLength = min(limit, total - cursor.location)
        guard let b = fieldString(element, start, cursor.location - start),
              let a = fieldString(element, cursor.location, afterLength) else { return nil }
        var before = Array(b), after = Array(a)
        if start > 0 { while let first = before.first, isWordChar(first) { before.removeFirst() } }
        if cursor.location + afterLength < total { while let last = after.last, isWordChar(last) { after.removeLast() } }
        return (before, after)
    }
}

/// After an edit: if the text now holds a blocked word or phrase that touches the cursor, how many characters
/// to erase before it and after it. Deleting (backspace, cut, undo) counts a match that ends at the cursor
/// or starts there; typing only counts a match the cursor is inside, since a word being typed is judged when
/// you finish it.
func editRemoval(before: [Character], after: [Character], deletion: Bool) -> (left: Int, right: Int)? {
    let text = before + after, cursor = before.count
    let hits = blockedSpans(text, entries: entries).filter {
        deletion ? ($0.lowerBound <= cursor && cursor <= $0.upperBound) : ($0.lowerBound < cursor && cursor < $0.upperBound)
    }
    guard let span = hits.max(by: { $0.count < $1.count }) else { return nil }
    return (max(0, cursor - span.lowerBound), max(0, span.upperBound - cursor))
}

var editWork: DispatchWorkItem?
var pendingDeletion = false
var lastOwnPost = Date.distantPast

/// Checks the text around the cursor shortly after the last edit (the app needs a moment to apply the key).
func scheduleEditCheck(deletion: Bool) {
    pendingDeletion = pendingDeletion || deletion
    editWork?.cancel()
    let work = DispatchWorkItem { editCheck() }
    editWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
}

func editCheck() {
    let deletion = pendingDeletion
    pendingDeletion = false
    // Skip while our own keystrokes are still landing, and when there is nothing to check.
    guard !state.disabled, !entries.isEmpty, Date().timeIntervalSince(lastOwnPost) > 0.3,
          let ctx = textAroundCursor(needTextAfter: !deletion), let (left, right) = editRemoval(before: ctx.before, after: ctx.after, deletion: deletion),
          left + right <= maxDelete else { return }
    for _ in 0..<right { post(keyCode: kForwardDelete) }
    backspaces(left)
    tail = Array(ctx.before.dropLast(left))
}

/// Fills the typed-text memory from the text field when it is empty (after a reset or a fresh start).
func seedTail() {
    if tail.isEmpty, let before = textBeforeCursor() { tail = before }
}

/// Copy-time check, run a few times a second: cuts blocked words out of new clipboard text.
func pollClipboard() {
    guard pasteboard.changeCount != pasteboardSeen else { return }
    pasteboardSeen = pasteboard.changeCount
    guard pasteChecked, !entries.isEmpty, let text = clipboardText() else { return }
    // Only the start of a very large clipboard is looked at, so copying a huge file cannot stall typing.
    let head = Array(text.prefix(maxScan + maxRun))
    let spans = blockedSpans(head, entries: entries)
    if !spans.isEmpty { writeClipboard(String(removeSpans(head, spans)) + String(text.dropFirst(head.count))) }
}

/// The paste keystroke (Cmd+V and its variants). Cuts blocked words out of the clipboard, and also catches a
/// word split across what was typed and what is pasted ("hello wor" typed, "ld" pasted): the typed letters
/// are erased too. Returns nil if the paste can go through untouched, otherwise the number of typed characters
/// to erase first (0 if only the clipboard needed cleaning).
func filterPaste() -> Int? {
    seedTail()
    guard pasteChecked, !entries.isEmpty, let text = clipboardText() else { tail.removeAll(); return nil }
    let pasted = Array(text.prefix(maxScan + maxRun))
    let rest = String(text.dropFirst(pasted.count))  // beyond the scanned part of a very large clipboard
    // Matches wholly inside the typed part were handled as typed; the others reach into the paste.
    let spans = blockedSpans(tail + pasted, entries: entries).filter { $0.upperBound > tail.count }
    var cleaned = pasted
    var erase: Int?
    if !spans.isEmpty {
        erase = spans.map { $0.lowerBound }.filter { $0 < tail.count }.min().map { tail.count - $0 }
        // Keep the rest of the paste: drop the matches from the pasted part only (the typed part is erased by key).
        let local = spans.map { max($0.lowerBound, tail.count) - tail.count ..< $0.upperBound - tail.count }
        cleaned = removeSpans(pasted, local)
        writeClipboard(String(cleaned) + rest)
        if let n = erase { tail.removeLast(n) }
    }
    if rest.isEmpty {
        tail += cleaned
        if tail.count > 2000 { tail.removeFirst(tail.count - 2000) }
    } else {
        tail.removeAll()  // the end of the paste was not read
    }
    return spans.isEmpty ? nil : (erase ?? 0)
}

// MARK: - Event tap

let marker: Int64 = 0x57_42_4C_4B  // "WBLK": tags events we post ourselves so the tap ignores them
let kBackspace: CGKeyCode = 51
let kV: CGKeyCode = 9
let kForwardDelete: CGKeyCode = 117
var tail: [Character] = []  // recent text typed since the last reset, separators included
var tapRef: CFMachPort?
var tapSource: CFRunLoopSource?

func post(keyCode: CGKeyCode, flags: CGEventFlags = [], text: String? = nil) {
    lastOwnPost = Date()
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

/// The Latin letter a Command shortcut stands for (Cmd+V is "v"), whatever the keyboard layout: on Dvorak the V
/// key is not where it is on a US keyboard. Layouts without Latin letters (Russian, Greek...) keep their shortcuts
/// on the US key positions, so there the physical key decides.
func shortcutLetter(_ event: CGEvent, keyCode: CGKeyCode) -> Character? {
    func usPosition() -> Character? {
        switch keyCode { case 6: return "z"; case 7: return "x"; case 9: return "v"; default: return nil }
    }
    guard let chars = NSEvent(cgEvent: event)?.charactersIgnoringModifiers?.lowercased(), let c = chars.first,
          chars.count == 1 else { return usPosition() }
    return c.isASCII ? (c.isLetter ? c : nil) : usPosition()
}

func callback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let pass = Unmanaged.passUnretained(event)
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = tapRef { CGEvent.tapEnable(tap: tap, enable: true) }
        return pass
    }
    if type == .leftMouseDown || type == .rightMouseDown { tail.removeAll(); return pass }
    guard type == .keyDown else { return pass }
    // Our own keystrokes (erasing a word, sending its separator again) are not the user typing: leave the memory alone.
    if event.getIntegerValueField(.eventSourceUserData) == marker { return pass }
    if state.disabled { tail.removeAll(); return pass }

    let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
    let flags = event.flags
    let cmd = flags.contains(.maskCommand), ctrl = flags.contains(.maskControl)
    let letter = cmd ? shortcutLetter(event, keyCode: keyCode) : nil

    // Any edit can leave a blocked word next to the cursor (a space deleted between "h" and "ello", a letter
    // typed into the middle of a word): look at the text around the cursor once typing pauses.
    if keyCode == kBackspace || keyCode == kForwardDelete || letter == "x" || letter == "z" {  // delete, cut, undo
        scheduleEditCheck(deletion: true)
    } else if letter == "v" {
        scheduleEditCheck(deletion: false)
    }

    // Paste: check the clipboard, and keep tracking the pasted text as if it were typed.
    if cmd && !ctrl && letter == "v" {
        guard let erase = filterPaste() else { return pass }
        if erase == 0 { return pass }  // only the clipboard needed cleaning, and that is done: let the paste go
        // Part of a split word was typed: erase it, then send the paste again.
        backspaces(erase)
        if pasteboard.string(forType: .string)?.isEmpty == false { post(keyCode: kV, flags: flags) }
        return nil
    }

    // Other shortcuts (select all, ...) change the text without us seeing it: forget the word.
    if cmd || ctrl { tail.removeAll(); return pass }

    if keyCode == kBackspace {
        if flags.contains(.maskAlternate) { tail.removeAll() } else { _ = tail.popLast() }  // Option+Delete eats a whole word
        return pass
    }

    var len = 0
    var chars = [UniChar](repeating: 0, count: 8)
    event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &len, unicodeString: &chars)
    // Nothing typed, or a longer string than the buffer (text expanders send these): not something we follow.
    guard len > 0, len <= chars.count else { tail.removeAll(); return pass }
    let typed = String(utf16CodeUnits: chars, count: len)
    guard let ch = typed.first, typed.count == 1 else { tail.removeAll(); return pass }

    // Arrows, Escape, function keys etc. arrive as control or private-use characters: the cursor moved.
    let scalar = ch.unicodeScalars.first!.value
    let isSeparatorKey = ch == " " || ch == "\r" || ch == "\n" || ch == "\t" || ch == "\u{3}"
    if !isSeparatorKey && (scalar < 0x20 || scalar == 0x7F || (0xF700...0xF8FF).contains(scalar)) {
        tail.removeAll()
        return pass
    }

    scheduleEditCheck(deletion: false)  // typed text: a letter put into the middle of a word can complete one
    seedTail()  // after a click, arrow key, cut or paste the memory is empty: read what is before the cursor
    if isWordChar(ch) && ch != "_" {
        tail.append(ch)
        if tail.count > 2000 { tail.removeFirst(500) }
        if let n = blockedLength(tail, entries: entries, instantOnly: true) {
            // Swallow the last key and erase what came before it, so the word never fully appears.
            backspaces(n - 1)
            tail.removeLast(n)
            return nil
        }
        return pass
    }

    // A separator ended the word. So does an underscore, although it can also be part of one: "word_" is caught
    // as soon as the underscore is typed, as in Sentryboard.
    if let n = blockedLength(tail, entries: entries, instantOnly: false) {
        // Erase the word or phrase, then re-send the separator so it lands after the deletion.
        backspaces(n)
        tail.removeLast(n)
        tail.append(ch)
        post(keyCode: keyCode, flags: flags, text: typed)
        return nil
    }
    tail.append(ch)
    return pass
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
    tapSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), tapSource, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    print("event tap active")
}

/// Run every second. Installs the tap once Accessibility access exists, and keeps it alive: macOS can switch a tap
/// off (permission toggled, a slow moment) or invalidate it, and a dead tap would leave the filter silently off.
func checkTap() {
    guard let tap = tapRef else { installTap(); return }
    if !CFMachPortIsValid(tap) {
        if let source = tapSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
        tapRef = nil; tapSource = nil
        print("event tap lost; creating a new one")
        installTap()
    } else if !CGEvent.tapIsEnabled(tap: tap) {
        CGEvent.tapEnable(tap: tap, enable: true)
    }
}

// MARK: - Daemon main

setvbuf(stdout, nil, _IOLBF, 0)  // line-buffer so messages reach a redirected log file

// Two daemons would fight over the state files and the control socket, and the stale one would undo the
// other's changes. The lock is released by the system when the process ends, however it ends.
try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
let instanceLock = open(stateDir.appendingPathComponent("daemon.lock").path, O_CREAT | O_RDWR, 0o600)
var lockTries = 0
while instanceLock >= 0 && flock(instanceLock, LOCK_EX | LOCK_NB) != 0 {  // an old one may still be shutting down
    lockTries += 1
    if lockTries > 12 { print("another WordBlock is already running; exiting"); exit(0) }
    usleep(250_000)
}

loadState()
fileHidden = fileIsHidden()
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
Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in pollClipboard() }

print("wordblock running (lock \(state.locked ? "on" : "off")). \(entries.count) words from \(listURL.path)")
installTap()
CFRunLoopRun()
