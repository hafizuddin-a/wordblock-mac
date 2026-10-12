# WordBlock

WordBlock deletes words you choose, in any Mac app, the moment you finish typing them. It is the Mac
counterpart of Sentryboard, an Android keyboard that does the same thing: a small, self-imposed friction
tool for a computer you own.

- Whole-word matching that ignores case, accents and apostrophes, and catches letter swaps (`sh@t`, `h3ll`).
- A **settings lock**: once locked, adding words is instant but removing them, switching the filter off or
  changing the delay needs a countdown (1 hour by default).
- Command line only. No menu bar icon, no account, no network access.

It only looks at the word you are typing right now. Nothing you type is saved, logged or sent anywhere.
The whole program is one file: [wordblock.swift](wordblock.swift).

Requires macOS 12 or later (Apple Silicon and Intel).

## Install

1. Download `WordBlock-<version>.zip` from the [Releases](../../releases) page and unzip it.
2. Drag `WordBlock.app` to your Applications folder.
3. Open it. macOS will say it can't verify the developer, because this app is not notarized by Apple:
   - **macOS 15 and later:** click Done, open **System Settings > Privacy & Security**, scroll down and click
     **Open Anyway** next to WordBlock, then open the app again.
   - **Earlier macOS:** right-click the app, choose **Open**, then **Open** again.
   - Or, in Terminal: `xattr -dr com.apple.quarantine /Applications/WordBlock.app`
4. Follow the guide. It asks you to allow Accessibility access, helps you pick your words, then starts
   WordBlock and sets it to run at every login.

Prefer to read the code first? It is all in this repository, and you can build it yourself (below).

## Use

Type a blocked word followed by a space, punctuation or Enter, and it disappears. Control it from Terminal:

```
wordblock status            show the filter, lock and countdown
wordblock add <word>        add a word (always instant)
wordblock lock              lock the list (removing words then needs a countdown)
wordblock unlock            start the countdown
wordblock help              every command
```

The full list of commands, the word list syntax and how the lock works is in [commands.txt](commands.txt).
Your words live in `~/.config/wordblock/words.txt`, one per line:

| Entry   | Meaning |
|---------|---------|
| `word`  | Blocked when you finish typing it |
| `word*` | Also blocks longer words that start with it (`words`, `wording`, not `sword`) |
| `word!` | Blocked the instant it is typed |

## What it can't do

- Pasted text, dictation and password fields are not filtered.
- It is friction, not a security boundary. With an admin account you can still turn off WordBlock's
  Accessibility permission, unload its login item, edit its state file or set the clock forward. A standard
  (non-admin) account is the only thing that closes those.
- Keyboard shortcuts, arrow keys, mouse clicks and switching apps make it forget the word in progress, so it
  only ever deletes text it saw you type.

## Build from source

You need Xcode's command-line tools (`xcode-select --install`).

```bash
./build.sh      # builds WordBlock.app (universal)
./install.sh    # builds, installs to ~/Applications and starts it
```

`build.sh` signs with a local certificate named "WordBlock Local Signing" if you have one, and ad-hoc
otherwise. Ad-hoc signing works, but macOS asks for the Accessibility permission again after every rebuild.
To avoid that, create a self-signed code-signing certificate with that name in your login keychain.

## Uninstall

```bash
./uninstall.sh
```

This refuses while the lock is on. Unlock first, wait out the countdown, then run it again. Your word list
is left in place.
