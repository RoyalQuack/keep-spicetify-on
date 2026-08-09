# How it works

Technical notes for anyone reading or changing the code. Users don't need any of this —
see the [README](../README.md).

## It isn't the restart

The usual description of this problem is "Spicetify disappears when I restart my
computer." The restart is a red herring — it's just when you notice.

What actually happens is that Spotify downloads an update in the background and replaces
its UI bundle. Spicetify's patch is gone from that moment; you don't see it until the
client next starts. So the tool watches for the *update*, not for boot.

## Detecting a break

Spicetify v2 does not patch `Apps\xpui.spa` in place. It extracts that archive, patches
the contents into an `Apps\xpui\` **folder** (which Spotify loads in preference to the
archive), and **moves** the clean archive into `%APPDATA%\spicetify\Backup`.

Two consequences drive the detection, and both matter:

1. **A healthy install has no `xpui.spa` in `Apps` at all.** So the archive *reappearing*
   is the signature of Spotify having reinstalled its UI bundle. That's what the file
   watcher waits for.

2. **Checking for the Spicetify marker alone is not enough.** After an update you're left
   with a *stale patched folder* built against the old Spotify sitting next to a *fresh
   clean archive* from the new one. The marker is still present, but the client is
   broken. A marker-only check reports "healthy" and never repairs.

An install is considered healthy only when **all** of these hold:

| Signal | Healthy value |
| --- | --- |
| Spicetify marker in the bundle Spotify actually loads | present |
| `config-xpui.ini` `[Backup] version` vs `Spotify.exe` version | equal |
| `Apps\xpui.spa` | absent |

The version comparison normalises Spicetify's git suffix, so `1.2.95.453.g0eeebbed`
matches `1.2.95.453`.

## Repairing

Two paths, chosen by whether Spotify has left a clean archive behind:

- **`backup apply`** when `Apps\xpui.spa` exists — the usual post-update case. The
  archive on disk is the clean bundle Spotify just installed, so backing it up captures
  pristine files.
- **`restore backup apply`** when it doesn't — Spicetify is holding the only clean copy,
  so it has to be restored into `Apps` first. This is the path a forced re-apply of an
  already healthy install takes.

Whichever runs, the other is tried as a fallback. Neither can capture already-patched
files as a "clean" backup, because backup only ever reads the `.spa` *archive* while
Spicetify writes its patched output to the `xpui` *folder*.

## Two traps worth knowing about

**`spicetify apply` launches Spotify, and Spotify inherits redirected stdio handles.**
Any wait that drains those streams — including `Start-Process -Wait` — therefore blocks
until Spotify itself exits, which can be hours. The code waits on the spicetify process
handle alone via `WaitForExit`.

**`Start-Process -PassThru` without `-Wait` reports an empty `ExitCode`.** That reads as
failure and triggers a pointless second repair pass. Touching `$proc.Handle` before
waiting forces the handle to be cached so the exit code survives.

Also: `Core.ps1` and `Startup.ps1` deliberately don't call `Set-StrictMode`. It's
scope-based, so a dot-sourced file would impose it on the caller's shell. Each entry
point sets its own.

## Why the tray is launched from a .vbs

Task Scheduler can only launch an executable, and launching `powershell.exe` directly
leaves an empty black window on screen. On Windows 11 the default terminal is Windows
Terminal, which **ignores `-WindowStyle Hidden`** and the classic
`ShowWindow(GetConsoleWindow(), SW_HIDE)` trick — the window it creates is a
`CASCADIA_HOSTING_WINDOW_CLASS` owned by `WindowsTerminal.exe`, not a console window the
script can hide. Closing that stray window kills the tray app.

`FreeConsole()` is not the answer either: Terminal keeps the window after the client
detaches, and PowerShell's host then throws `The handle is invalid` the next time it
touches the console.

`wscript.exe` has no console of its own, and `WScript.Shell.Run(cmd, 0, False)` creates
the PowerShell process hidden, so no console is ever allocated. That's what
`launcher.vbs` does, and it's what both the logon task and the installer use. The code
falls back to launching `powershell.exe` directly if the .vbs is missing.

## Why installing goes through a .bat

`.ps1` files can't be launched by double-click on a stock Windows machine: the default
execution policy is `Restricted`, and files extracted from a downloaded ZIP additionally
carry Mark of the Web. `.bat` files are subject to neither. `Install.bat` unblocks the
extracted scripts, runs PowerShell with `-ExecutionPolicy Bypass`, and pauses at the end
so any error stays readable instead of vanishing with the window.

## Configuration

`%LOCALAPPDATA%\KeepSpicetifyOn\config.json`:

```json
{
  "checkIntervalSeconds": 300,
  "repairPolicy": "WaitForSpotifyExit",
  "blockSpotifyUpdates": false,
  "notifications": true
}
```

| Key | Meaning |
| --- | --- |
| `checkIntervalSeconds` | Periodic health check. The file watcher catches updates within seconds anyway, so this is a safety net. |
| `repairPolicy` | `WaitForSpotifyExit` (default), `RepairImmediately`, or `AskFirst`. |
| `blockSpotifyUpdates` | Mirrors the tray toggle. |
| `notifications` | Tray balloon notifications. |

Restart the tray app after editing by hand.

## Running without the tray

```bash
powershell -ExecutionPolicy Bypass -File .\src\KeepSpicetifyOn.ps1 -Status
```

Reports health and changes nothing. `-Once` checks and repairs a single time then exits,
which suits a hand-rolled Task Scheduler entry. `-ShowConsole` keeps the console visible
for debugging.

A full re-apply takes roughly 10 seconds, though it can reach a few minutes when it needs
to fetch a fresh CSS map. It runs on a background runspace so the tray stays responsive.

## Layout

| Path | Purpose |
| --- | --- |
| `src/Core.ps1` | Detection and repair engine. No UI. |
| `src/KeepSpicetifyOn.ps1` | Tray app; also `-Status` / `-Once` headless modes. |
| `src/Startup.ps1` | Logon-task registration, shared by the installer and the tray. |
| `src/launcher.vbs` | Starts the tray with no console window. See below. |
| `Install.bat` / `Uninstall.bat` | Double-clickable entry points that get around execution policy. |
| `install.ps1` / `uninstall.ps1` | Setup and removal. |
| `tests/Test-Core.ps1` | Test suite, no Pester needed. |

Nothing needs administrator rights: Spotify, Spicetify, and the logon task all live in
the user's profile.

## Tests

```bash
powershell -ExecutionPolicy Bypass -File .\tests\Test-Core.ps1
```

Read-only — nothing is applied, repaired, or modified. Covers version normalisation, INI
parsing, config defaults, and asserts the real invariants of the live install, including
that the backup archive is genuinely unpatched.
