
// WordBlock tests. Run with tests/run.sh, which builds this together with the matching and keystroke code from
// wordblock.swift. Key posting is replaced by a recorder, so nothing is ever typed into the real session, and the
// clipboard used is a private one. The fuzz sections use random input, so a failure there prints what caused it.
var failures = 0
func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    print(ok ? "ok  " : "FAIL", name, ok ? "" : detail()); if !ok { failures += 1 }
}
func E(_ list: String...) -> [Entry] { list.compactMap(parseEntry) }
func blocked(_ text: String, _ ents: [Entry]) -> Bool { blockedLength(Array(text), entries: ents, instantOnly: false) != nil }

// ---- child modes: run something risky in a separate process so a crash or hang cannot take the harness down ----
let argv = CommandLine.arguments
if argv.count > 2 && argv[1] == "--long-run" {
    entries = E("badword")
    let n = Int(argv[2])!
    _ = blockedSpans(Array(repeating: Character("a"), count: n), entries: entries)
    print("survived"); exit(0)
}
if argv.count > 2 && argv[1] == "--ones" {
    let n = Int(argv[2])!
    let ents = E("porn")
    let t0 = Date()
    _ = blockedLength(Array(String(repeating: "1", count: n)), entries: ents, instantOnly: false)
    print("done in \(Date().timeIntervalSince(t0))"); exit(0)
}
func child(_ args: [String], timeout: Double = 8) -> (status: Int32, crashed: Bool, timedOut: Bool, out: String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: argv[0]); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    try? p.run()
    let t0 = Date(); var timedOut = false
    while p.isRunning { if Date().timeIntervalSince(t0) > timeout { p.terminate(); timedOut = true; break }; usleep(20_000) }
    p.waitUntilExit()
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return (p.terminationStatus, p.terminationReason == .uncaughtSignal, timedOut, out)
}

// ---- 1. matching ----
let porn = E("porn")
check(blocked("porn", porn), "plain word")
check(blocked("po\u{200B}rn", porn), "zero width space inside")
check(blocked("po\u{200D}rn", porn), "zero width JOINER inside a word")
check(blocked("po\u{200C}rn", porn), "zero width NON-joiner inside a word")
check(blocked("p\u{20DD}orn", porn), "enclosing mark after a letter")
check(blocked("po\u{0338}rn", porn), "combining overlay after a letter")
check(blocked("p\u{FE0F}orn", porn), "variation selector after a letter")
check(blocked("pоrn", porn), "Cyrillic o lookalike")
check(blocked("p0rn", porn), "leet zero")
check(blocked("\u{00AD}porn\u{00AD}", porn), "soft hyphens around")

// ---- 2. the "1" explosion ----
for n in [24, 28] {
    let r = child(["--ones", String(n)], timeout: 6)
    check(!r.timedOut && !r.crashed, "a run of \(n) ones is matched quickly", "took too long or died: \(r.out)")
}

// ---- 3. crash on a huge unbroken run ----
for n in [19_000, 25_000, 60_000] {
    let r = child(["--long-run", String(n)])
    check(r.out.contains("survived"), "a \(n)-character run with no separators does not crash", "crashed=\(r.crashed) status=\(r.status)")
}

// ---- 4. unicode string longer than the buffer ----
do {
    let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
    let long = Array("abcdefghijklmnopqrst".utf16)
    e.keyboardSetUnicodeString(stringLength: long.count, unicodeString: long)
    var len = 0; var chars = [UniChar](repeating: 0, count: 8)
    e.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &len, unicodeString: &chars)
    check(len <= 8, "actualStringLength never exceeds the buffer (it is \(len); the handler reads that many)", "len=\(len)")
}

// ---- 5. typing simulation through the real event handler ----
var posted: [(code: CGKeyCode, flags: CGEventFlags, text: String?)] = []
func post(keyCode: CGKeyCode, flags: CGEventFlags = [], text: String? = nil) {
    lastOwnPost = Date(); posted.append((keyCode, flags, text))
}
var doc: [Character] = []
let board = pasteboard
func setClip(_ s: String) { board.clearContents(); board.setString(s, forType: .string); pasteboardSeen = board.changeCount }
func send(_ e: CGEvent, type: CGEventType = .keyDown) -> Bool {
    let r = callback(proxy: OpaquePointer(bitPattern: 0x1)!, type: type, event: e, refcon: nil)
    return r != nil
}
func keyEvent(_ code: CGKeyCode, _ s: String?, flags: CGEventFlags = [], marked: Bool = false) -> CGEvent {
    let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!
    if let s = s { let u = Array(s.utf16); e.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u) }
    e.flags = flags
    if marked { e.setIntegerValueField(.eventSourceUserData, value: marker) }
    return e
}
func applyToApp(code: CGKeyCode, text: String?, flags: CGEventFlags) {
    if code == kBackspace { _ = doc.popLast() }
    else if code == kV && flags.contains(.maskCommand) { doc += Array(board.string(forType: .string) ?? "") }
    else if let t = text { doc += Array(t) }
}
/// One physical key press: handler decides, then our own posted events reach the app and come back to the handler marked.
func press(_ code: CGKeyCode, _ s: String?, flags: CGEventFlags = []) {
    posted.removeAll()
    let passed = send(keyEvent(code, s, flags: flags))
    if passed { applyToApp(code: code, text: s, flags: flags) }
    let mine = posted; posted.removeAll()
    for p in mine {
        applyToApp(code: p.code, text: p.text, flags: p.flags)
        _ = send(keyEvent(p.code, p.text, flags: p.flags, marked: true))
    }
    posted.removeAll()
}
func typeText(_ s: String) { for ch in s { press(ch == " " ? 49 : 0, String(ch)) } }
func backspace() { press(kBackspace, "\u{7F}") }
func reset(_ list: [Entry]) { entries = list; tail = []; doc = []; state = S(); posted = [] }
func docString() -> String { String(doc) }

reset(E("hello world"))
typeText("hello world ")
check(docString() == " ", "phrase typed and finished with a space is erased, space kept", "doc=[\(docString())]")

reset(E("hello world"))
typeText("say hi to foo ")
typeText("hello world ")
check(docString() == "say hi to foo  ", "text before the phrase is untouched", "doc=[\(docString())]")
check(String(tail) == docString(), "memory of typed text still matches the field after our own deletion", "tail=[\(String(tail))] doc=[\(docString())]")

reset(E("zip!"))
typeText("a zip")
check(docString() == "a ", "instant word is erased as typed", "doc=[\(docString())]")
check(String(tail) == docString(), "memory matches the field after an instant erase", "tail=[\(String(tail))] doc=[\(docString())]")

// phrase whose first half was typed before an earlier removal
reset(E("foo", "ab cd"))
typeText("ab foo cd ")
check(docString() == " ", "a word removed from the middle of a phrase leaves the phrase, which is then caught too", "doc=[\(docString())]")

// ---- 6. fuzz: random typing must keep the memory consistent with the field and must not leak complete blocked words ----
var rng = SystemRandomNumberGenerator()
let alphabet = Array("abcdfoqxzipnrwuh1_@  .,\n")
let fuzzEntries = E("foo", "bar baz", "qux*", "zip!", "ab cd ef", "h1ll", "ni cd", "a_b", "p@r", "x_y z!")
var fuzzBad = 0, fuzzFirst = ""
for round in 0..<300 {
    reset(fuzzEntries)
    var script = ""
    for _ in 0..<Int.random(in: 5...60, using: &rng) {
        let r = Int.random(in: 0..<20, using: &rng)
        if r == 0 { backspace(); script += "<BS>"; continue }
        let ch = alphabet.randomElement(using: &rng)!
        script += String(ch == "\n" ? "↩" : ch)
        if ch == "\n" { press(36, "\r") } else { press(ch == " " ? 49 : 0, String(ch)) }
        // memory must always be the end of what is really in the field
        if String(tail) != String(doc) {
            fuzzBad += 1; if fuzzFirst.isEmpty { fuzzFirst = "round \(round) script \(script) tail=[\(String(tail))] doc=[\(String(doc))]" }
            break
        }
    }
}
check(fuzzBad == 0, "fuzz: memory equals the text field after every key, with no resets (\(fuzzBad) of 300 runs)", fuzzFirst)

var leaks = 0, leakFirst = ""
for round in 0..<300 {
    reset(fuzzEntries)
    var script = ""
    for _ in 0..<Int.random(in: 5...60, using: &rng) {
        let ch = alphabet.randomElement(using: &rng)!
        script += String(ch == "\n" ? "↩" : ch)
        if ch == "\n" { press(36, "\r") } else { press(ch == " " ? 49 : 0, String(ch)) }
    }
    // everything typed was followed by whatever came next; flush with a separator then look for complete blocked words
    press(49, " ")
    let spans = blockedSpans(doc, entries: fuzzEntries)
    if !spans.isEmpty { leaks += 1; if leakFirst.isEmpty { leakFirst = "round \(round) script \(script) doc=[\(String(doc))] spans=\(spans)" } }
}
check(leaks == 0, "fuzz: no complete blocked word or phrase survives typing (\(leaks) of 300 runs)", leakFirst)


// ---- 7. which invisible or combining characters hide a word? ----
var evaders: [String] = []
let allScalars = (0x0...0x10FFFF).compactMap { Unicode.Scalar($0) }
for sc in allScalars {
    switch sc.properties.generalCategory {
    case .format, .nonspacingMark, .enclosingMark:
        if !blocked("po" + String(sc) + "rn", porn) { evaders.append(String(format: "%04X", sc.value)) }
    default: break
    }
}
check(evaders.isEmpty, "no format or combining character hides a word (\(evaders.count) do)", evaders.prefix(40).joined(separator: " "))

// ---- 8. pasting ----
func clipText() -> String { board.string(forType: .string) ?? "<none>" }
reset(E("hello world"))
typeText("hello wor"); setClip("ld")
press(kV, "v", flags: .maskCommand)
check(docString() == "", "typed 'hello wor' + pasted 'ld' erases the phrase", "doc=[\(docString())] clip=[\(clipText())]")

reset(E("hello world"))
setClip("keep hello world keep")
press(kV, "v", flags: .maskCommand)
check(docString() == "keep keep", "paste with a phrase inside keeps the rest", "doc=[\(docString())]")

reset(E("hello world"))
typeText("hello "); setClip("wor")
press(kV, "v", flags: .maskCommand)
typeText("ld ")
check(docString() == " ", "typing the end of a phrase after pasting its start", "doc=[\(docString())]")

reset(E("badword"))
setClip("clean text")
press(kV, "v", flags: .maskCommand)
check(docString() == "clean text" && clipText() == "clean text", "clean paste untouched", "doc=[\(docString())] clip=[\(clipText())]")

reset(E("badword"))
setClip("x badword y"); pasteboardSeen = -1
pollClipboard()
check(clipText() == "x y", "clipboard poll cuts the word out", "clip=[\(clipText())]")

// paste only a long blob: the clipboard must not be truncated
reset(E("badword"))
let blob = String(repeating: "lorem ipsum ", count: 5000) + "badword " + String(repeating: "dolor ", count: 5000)
setClip(blob); pasteboardSeen = -1
pollClipboard()
check(clipText().hasSuffix(String(repeating: "dolor ", count: 5000)) && clipText().count > 80_000 || clipText() == blob, "a long clipboard is not truncated", "count=\(clipText().count)")
check(!clipText().contains("badword") || blob.count > 20_000, "a word within the first 20000 characters is cut from a long clipboard")

// huge clipboard must not stall the handler
reset(E("badword"))
let huge = String(repeating: "word ", count: 600_000)  // 3 million characters
setClip(huge); pasteboardSeen = -1
let t0 = Date(); pollClipboard(); let dt = Date().timeIntervalSince(t0)
check(dt < 0.5, "polling a 3 million character clipboard stays fast (\(Int(dt * 1000)) ms)", "took \(dt)s")
setClip("done")
reset(E("badword"))
let hugeCJK = String(repeating: "语言 résumé ", count: 250_000)  // 3 million characters, not ASCII
setClip(hugeCJK); pasteboardSeen = -1
let t1 = Date(); pollClipboard(); let dt1 = Date().timeIntervalSince(t1)
check(dt1 < 0.5, "polling a 3 million character non-ASCII clipboard stays fast (\(Int(dt1 * 1000)) ms)", "took \(dt1)s")
setClip("done")

// ---- 9. underscores while typing ----
reset(E("porn"))
typeText("see my_porn_site ")
check(docString() == "see my__site ", "blocked word between underscores is erased when typed", "doc=[\(docString())]")
reset(E("porn"))
typeText("porn_")
check(docString() == "_", "blocked word is erased as soon as the underscore after it is typed", "doc=[\(docString())]")
reset(E("porn!"))
typeText("my_porn")
check(docString() == "my_", "instant word after an underscore is erased as typed", "doc=[\(docString())]")
reset(E("hello world"))
typeText("hello_world ")
check(docString() == " ", "phrase joined by an underscore", "doc=[\(docString())]")
reset(E("foo_bar"))
typeText("a foo_bar ")
check(docString() == "a  ", "an entry that contains an underscore still matches whole", "doc=[\(docString())]")
reset(E("porn"))
typeText("snake_case word ")
check(docString() == "snake_case word ", "ordinary underscore words are untouched", "doc=[\(docString())]")

// ---- 10. paste detail ----
reset(E("badword"))
setClip("only badword here"); posted.removeAll()
let passedPaste = send(keyEvent(kV, "v", flags: .maskCommand))
check(passedPaste && posted.isEmpty, "a paste that only needed the clipboard cleaned is let through, no extra keystrokes", "passed=\(passedPaste) posted=\(posted.count)")
check(clipText() == "only here", "clipboard was cleaned before the paste", "clip=[\(clipText())]")

// ---- 11. own keystrokes never touch the memory ----
reset(E("hello"))
tail = Array("keep me")
_ = send(keyEvent(kBackspace, "\u{7F}", marked: true))
_ = send(keyEvent(0, "x", marked: true))
check(String(tail) == "keep me", "events we posted ourselves leave the memory alone", "tail=[\(String(tail))]")

// ---- 12. unicode longer than the buffer ----
reset(E("hello"))
tail = Array("abc")
let longEvent = keyEvent(0, nil)
let longUnits = Array("abcdefghijklmnopqrst".utf16)
longEvent.keyboardSetUnicodeString(stringLength: longUnits.count, unicodeString: longUnits)
_ = send(longEvent)
check(tail.isEmpty, "a key event carrying a long string resets instead of overrunning", "tail=[\(String(tail))]")

// ---- 13. normalisation edge cases ----
check(blocked("h1ll", E("hill")) && blocked("h1ll", E("hlll")) && blocked("hill", E("h1ll")) && !blocked("hill", E("hall")), "a '1' stands for i or l, both ways")
check(blocked("1111", E("illl")) && blocked("illi", E("1111")) && !blocked("ilma", E("1111")), "runs of ones")
check(blocked("@porn", porn) && blocked("porn$", porn) && blocked("p@rn", E("parn")), "@ and $ at the edges and inside")
check(blocked("İlk", E("ilk")), "dotted capital I")
check(!blockedSpans(Array("porn\u{1F468}\u{200D}\u{1F469}"), entries: porn).isEmpty && blocked("\u{1F468}\u{200D}\u{1F469}porn", porn), "an emoji joined with joiners next to a word is a separator, not part of the word")
check(blocked("PORN", porn) && blocked("Pörn", porn) && blocked("p'o'r'n", porn), "case, accents, apostrophes")
check(!blocked("sporn", porn) && !blocked("pornx", porn) && blocked("pornx", E("porn*")), "whole word, and prefix entries")
check(parseEntry("\u{200B}") == nil && parseEntry("'") == nil && parseEntry("*") == nil && parseEntry("a b c d e f g") == nil, "junk entries are rejected")

// ---- 14. edit-time removal (text around the cursor after an edit) ----
reset(E("hello world", "badword"))
func R(_ b: String, _ a: String, _ del: Bool) -> String { editRemoval(before: Array(b), after: Array(a), deletion: del).map { "\($0.left),\($0.right)" } ?? "nil" }
check(R("h", "ello world", true) == "1,10", "h|ello world after deleting the space: whole phrase")
check(R("say h", "ello world and more", true) == "1,10", "phrase in the middle of more text")
check(R("hello wo", "rld", false) == "8,3", "typing the missing letter inside the phrase")
check(R("hello world", " tail", true) == "11,0", "a deletion that leaves a match ending at the cursor")
check(R("hello world", " tail", false) == "nil", "typing at the end of a phrase waits for the separator")
check(R("see ", "badword here", false) == "nil", "cursor at the start of a word: typing does not remove it")
check(R("see ", "badword here", true) == "0,7", "a deletion touching the start of a word removes it")
check(R("ba", "dword", false) == "2,5", "a letter typed into the middle completes a word")
check(R("", "", true) == "nil" && R("hello ", "there", true) == "nil", "nothing to remove")

// ---- 15. robustness fuzz: typing mixed with clicks, arrows, shortcuts and nasty pastes ----
let nasty = ["hello world", "badword", "bad", "word", "my_badword_x", "po\u{200D}rn", "\u{200B}", "\n", "\r\n", " ", "  ", "👨‍👩‍👧", "é", "x", "_", "111111", "snake_case",
             String(repeating: "a", count: 300), "hello\u{200B}world", "$", "@", "'", "؀r", "\t", "…"]
let fuzz2Entries = E("hello world", "badword", "bad word", "porn", "snake*", "x y", "1ll")
var f2Bad = 0, f2First = ""
for round in 0..<400 {
    reset(fuzz2Entries)
    var script: [String] = []
    for _ in 0..<Int.random(in: 5...50, using: &rng) {
        switch Int.random(in: 0..<14, using: &rng) {
        case 0: backspace(); script.append("BS")
        case 1: _ = send(keyEvent(123, "\u{F702}")); script.append("LEFT")                    // arrow: private-use char
        case 2: _ = send(keyEvent(0, nil), type: .leftMouseDown); script.append("CLICK")
        case 3: press(7, "x", flags: .maskCommand); script.append("CUT")
        case 4: press(6, "z", flags: .maskCommand); script.append("UNDO")
        case 5: press(kBackspace, "\u{7F}", flags: .maskAlternate); script.append("OPT-BS")
        case 6, 7:
            let clip = (0..<Int.random(in: 1...5, using: &rng)).map { _ in nasty.randomElement(using: &rng)! }.joined()
            setClip(clip); press(kV, "v", flags: .maskCommand); script.append("PASTE[\(clip.prefix(30))]")
        default:
            let w = nasty.randomElement(using: &rng)!
            for ch in w where ch.unicodeScalars.count == 1 || true { press(ch == " " ? 49 : 0, String(ch)) }
            script.append("T[\(w.prefix(20))]")
        }
        if !doc.suffix(tail.count).elementsEqual(tail) {
            f2Bad += 1; if f2First.isEmpty { f2First = "round \(round) \(script.suffix(6)) tail=[\(String(tail).suffix(40))] doc=[\(String(doc).suffix(40))]" }
            break
        }
    }
}
check(f2Bad == 0, "fuzz 2: no crash, and the memory is always the end of the text field (\(f2Bad) of 400 runs)", f2First)

// ---- 16. matching never crashes or hangs on odd input ----
var oddBad = 0
for _ in 0..<2000 {
    let len = Int.random(in: 0...400, using: &rng)
    let pool = ["a", "b", "1", "_", " ", "\n", "\u{200D}", "\u{200B}", "é", "$", "@", "'", "؀", "👨‍👩‍👧", "porn", "hello", "world", "snake", "x", "y"]
    let text = (0..<len).map { _ in pool.randomElement(using: &rng)! }.joined()
    let chars = Array(text)
    let spans = blockedSpans(chars, entries: fuzz2Entries)
    let cleaned = removeSpans(chars, spans)
    if cleaned.count > chars.count || spans.contains(where: { $0.upperBound > chars.count || $0.lowerBound < 0 }) { oddBad += 1 }
    _ = blockedLength(chars, entries: fuzz2Entries, instantOnly: Bool.random(using: &rng))
}
check(oddBad == 0, "random odd text: spans stay inside the text and nothing crashes (\(oddBad) bad of 2000)")

// ---- versions ----
check(versionIsNewer("1.10.0", than: "1.9.2") && versionIsNewer("1.3.2", than: "1.3.1") && versionIsNewer("2.0", than: "1.99.9"), "newer versions are newer")
check(!versionIsNewer("1.3.2", than: "1.3.2") && !versionIsNewer("1.3.1", than: "1.3.2") && !versionIsNewer("1.3", than: "1.3.0") && !versionIsNewer("1.9.2", than: "1.10.0"), "same or older versions are not")
check(versionIsNewer("1.3.2", than: nil) && versionIsNewer("1.3.2", than: "dev") && !versionIsNewer("dev", than: "1.3.2"), "an unknown or development version counts as older")

// ---- speed: a realistic list, typing prose ----
do {
    let words = (0..<60).map { "word\($0)" } + ["porn!", "bad phrase", "hello world", "snake*", "x1z"]
    reset(words.compactMap(parseEntry))
    let prose = Array(String(repeating: "the quick brown fox jumps over the lazy dog and keeps typing for a while, ", count: 40))
    let t0 = Date()
    for ch in prose { press(ch == " " ? 49 : 0, String(ch)) }
    let per = Date().timeIntervalSince(t0) / Double(prose.count)
    check(per < 0.002, "typing costs under 2 ms per key with 65 entries (\(String(format: "%.3f", per * 1000)) ms)", "\(per * 1000) ms")
}

print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
