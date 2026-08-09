# KeepSpicetifyOn

*Spicetify keeps getting wiped? Just automate it :)*

Keeps [Spicetify](https://spicetify.app) applied to Spotify on Windows, automatically.

Spotify quietly reinstalls its own UI whenever it updates, which wipes Spicetify. This
sits in your system tray, notices the moment it happens, and re-applies Spicetify for
you — without interrupting whatever you're listening to.

No dependencies. It runs on Windows PowerShell 5.1 and WinForms, both of which are
already on your machine.

```
  ●  Spicetify is on
     Spotify 1.2.95.453
     ─────────────────────────
     Check now
     Repair now
     Pause for 1 hour
     ─────────────────────────
     Start automatically at logon   ✓
     Block Spotify auto-updates
     Show notifications             ✓
     ─────────────────────────
     Open log
     Quit
```

## It isn't the restart

The common description of this problem is "Spicetify disappears when I restart my
computer." The restart is a red herring — it's just when you notice.

What actually happens is that Spotify downloads an update in the background and
replaces its UI bundle. Spicetify's patch is gone from that moment; you simply don't
see it until the client next starts. So this tool watches for the *update*, not for
boot.

## How it detects a break

Spicetify v2 does not patch `Apps\xpui.spa` in place. It extracts that archive,
patches the contents into an `Apps\xpui\` **folder** (which Spotify loads in preference
to the archive), and **moves** the clean archive into `%APPDATA%\spicetify\Backup`.

Two consequences drive the detection, and both matter:

1. **A healthy install has no `xpui.spa` in `Apps` at all.** So the archive
   *reappearing* is the signature of Spotify having reinstalled its UI bundle. That's
   the file the watcher waits for.

2. **Checking for the Spicetify marker alone is not enough.** After an update you're
   left with a *stale patched folder* built against the old Spotify sitting next to a
   *fresh clean archive* from the new one. The marker is still there, but the client is
   broken. A marker-only check reports "healthy" and never repairs.

So an install is considered healthy only when **all** of these hold:

| Signal | Healthy value |
| --- | --- |
| Spicetify marker in the bundle Spotify actually loads | present |
| `config-xpui.ini` `[Backup] version` vs `Spotify.exe` version | equal |
| `Apps\xpui.spa` | absent |

The version comparison normalises Spicetify's git suffix, so `1.2.95.453.g0eeebbed`
matches `1.2.95.453`.

## Install

Requires Spicetify to already be installed and working — this keeps an existing setup
alive, it doesn't set Spicetify up for you.

```bash
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

That registers a logon task, repairs Spicetify if it's currently broken, and starts the
tray app. Look for a coloured dot in your tray: **green** = on, **red** = off,
**amber** = repairing, **grey** = paused.

To remove it:

```bash
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

Uninstalling touches nothing but itself. Spotify and Spicetify are left exactly as they
are; Spotify is simply free to break the patch again.

## Without the tray

```bash
powershell -ExecutionPolicy Bypass -File .\src\KeepSpicetifyOn.ps1 -Status
```

Reports health and changes nothing:

```
  State           : NeedsRepair
  Reason          : Spotify updated to 1.2.95.453 but the patch was built
                    against 1.2.94.583.g60394bd5 - the patch is stale.
  Spotify version : 1.2.95.453
  xpui.spa back   : True  (true means Spotify reinstalled its bundle)
```

Use `-Once` to check and repair a single time and exit — handy if you'd rather drive it
from your own Task Scheduler entry than run a tray app.

## Repair behaviour

A repair restarts the Spotify client, so by default it never runs while you're
listening. If Spotify is open when a break is detected, the repair is queued and runs
the moment you close it — meaning Spicetify is already back the next time you open
Spotify. If Spotify is closed, the repair happens immediately and silently, and the
client that Spicetify launches on completion is closed again so nothing pops up
unexpectedly.

A full re-apply takes roughly 10 seconds, though it can run to a few minutes when it
needs to fetch a fresh CSS map. It runs on a background runspace, so the tray stays
responsive throughout.

Two repair paths are used depending on the state found:

- **`backup apply`** when Spotify has left a clean `xpui.spa` behind (the usual
  post-update case).
- **`restore backup apply`** when it hasn't — Spicetify is holding the only clean copy,
  so it has to be put back first. This is the path a forced re-apply takes.

Neither can capture already-patched files as a "clean" backup, because backup only ever
reads the `.spa` *archive* while Spicetify writes its patched output to the `xpui`
*folder*.

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
| `checkIntervalSeconds` | Periodic health check. The file watcher catches updates within seconds regardless, so this is a safety net. |
| `repairPolicy` | `WaitForSpotifyExit` (default), `RepairImmediately`, or `AskFirst`. |
| `blockSpotifyUpdates` | Mirrors the tray toggle. See below. |
| `notifications` | Tray balloon notifications. |

Restart the tray app after editing by hand.

### Blocking Spotify updates

The tray has an opt-in **Block Spotify auto-updates** toggle, off by default. It runs
`spicetify spotify-updates block`, which patches `Spotify.exe` so the client stops
updating itself — preventing the problem rather than repairing it.

It's off by default deliberately: blocking updates means no more Spotify feature or
security fixes until you turn it back off. `uninstall.ps1 -UnblockSpotifyUpdates`
reverses it.

## Tests

```bash
powershell -ExecutionPolicy Bypass -File .\tests\Test-Core.ps1
```

Read-only — nothing is applied, repaired, or modified. Covers version normalisation,
INI parsing, config defaults, and asserts the real invariants of the live install
(including that the backup archive is genuinely unpatched).

## Layout

| Path | Purpose |
| --- | --- |
| `src/Core.ps1` | Detection and repair engine. No UI. |
| `src/KeepSpicetifyOn.ps1` | Tray app; also `-Status` / `-Once` headless modes. |
| `src/Startup.ps1` | Logon-task registration, shared by the installer and the tray. |
| `install.ps1` / `uninstall.ps1` | Setup and removal. |
| `tests/Test-Core.ps1` | Test suite, no Pester needed. |

Nothing here needs administrator rights: Spotify, Spicetify, and the logon task all
live in your user profile.

## Troubleshooting

**The tray icon never appears.** Windows may be hiding it — check the `^` overflow area
and pin it. Otherwise run the tray script with `-ShowConsole` to see errors.

**Repairs keep failing.** Open the log from the tray menu, or look at
`%LOCALAPPDATA%\KeepSpicetifyOn\log.txt`. Raw Spicetify output from the last run is in
`spicetify-out.log` and `spicetify-err.log` beside it. Spicetify writes progress bars to
stderr even when it succeeds, so content there isn't itself a failure.

**Spotify is the Microsoft Store build.** Spicetify doesn't support it. Install the
desktop build from [spotify.com](https://www.spotify.com/download/windows/).

**A Spotify update outpaces Spicetify.** Occasionally Spotify ships a build that the
current Spicetify can't patch yet. No tool can fix that; update Spicetify with
`spicetify upgrade` once support lands.

## Licence

MIT — see [LICENSE](LICENSE).

Not affiliated with Spotify or the Spicetify project.
