# caffeinate & disablesleep

![downloads](https://img.shields.io/github/downloads/demiaochen/caffeinate-disablesleep/total) [![sponsor](https://img.shields.io/badge/sponsor-%E2%99%A5-1a1814)](https://github.com/sponsors/demiaochen)

<p align="center">
  <img src="shots/hero.png?v=9" width="346" alt="the popover, clicked open from the menu bar">
</p>

A tiny macOS menu bar app for the two commands you keep typing:

```
caffeinate -disu                 → click the square
sudo pmset -a disablesleep 1     → "Stay awake with lid closed"
```

**Install:** download the DMG from [Releases](../../releases), or:

```
brew install --cask demiaochen/tap/caffeinate-disablesleep
```

Requires macOS 14 or later.

## How it works

- Sessions hold the same IOKit power assertions `caffeinate -disu` takes. No child
  processes; the kernel releases them automatically if the app dies.
  Verify with `pmset -g assertions`.
- The lid-closed lock sets `pmset -a disablesleep` through the system admin prompt.
  It mirrors the real system flag and releases only via its toggle or on quit.
- The lid toggle asks for your password once. That first prompt installs a
  scoped, visudo-validated `NOPASSWD` rule for `pmset` (see `LidLock.swift`).
  Every later toggle is silent, and quitting releases the lock silently too.
- Undo the rule with `sudo rm /etc/sudoers.d/caffeinate-disablesleep`. Without
  it, quit leaves the lid setting as you set it. Quit never shows a password
  dialog.
- The readout at the bottom shows the live command equivalents. The caffeinate
  line is commented out with `#` while no session runs; the pmset line mirrors
  the real system flag as 0 or 1, including changes made in a terminal.
- Right click the menu bar icon to toggle without opening the panel.
- No animation, zero idle CPU, about 1 MB universal binary.

## Build

```
scripts/build.sh      # compile + sign           (set CODESIGN_IDENTITY)
scripts/lint.sh       # swift-format check       (--fix to rewrite)
scripts/release.sh    # notarize + staple + DMG  (set NOTARY_PROFILE)
```

macOS 14+. No Xcode project, no dependencies, just plain `swiftc`.

## License

[MIT](LICENSE)

## Sponsor

If this app saves you a terminal tab, you can keep me awake too:

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/demiaochen)
