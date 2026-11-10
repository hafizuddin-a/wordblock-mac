#!/bin/bash
# Runs the tests. wordblock.swift is one program with top-level code, so the test program is assembled from it:
# the matching code, plus the clipboard and keystroke handling with key posting swapped for a recorder, plus
# tests/tests.swift. Nothing is typed into your session and your clipboard is not touched.
set -e
cd "$(dirname "$0")/.."
OUT=.build/tests
mkdir -p "$OUT"
python3 - "$OUT" <<'PY'
import re, sys
out = sys.argv[1]
src = open('wordblock.swift').read()
head = src[src.index('// MARK: - Matching'):src.index('// MARK: - Paths and settings')]
tap = src[src.index('// MARK: - Pasted text'):src.index('// MARK: - Daemon main')]
tap = re.sub(r'func post\(keyCode: CGKeyCode, flags: CGEventFlags = \[\], text: String\? = nil\) \{.*?\n\}\n', '', tap, flags=re.S)
stubs = '''
let env = ProcessInfo.processInfo.environment.merging(["WORDBLOCK_PASTEBOARD": "wb-test-board"]) { $1 }
struct S { var disabled = false; var pasteOff: Bool? = nil }
var state = S()
var entries: [Entry] = []
let noTap = true
'''
open(out + '/main.swift', 'w').write('import AppKit\nimport CoreGraphics\nimport CryptoKit\n' + head + stubs + tap + open('tests/tests.swift').read())
PY
swiftc -O "$OUT/main.swift" -o "$OUT/run"
"$OUT/run"
