# KeepSpicetifyOn

*Spicetify keeps getting wiped? Just automate it :)*

Spotify updates itself every few days, and every time it does, it quietly throws away
your [Spicetify](https://spicetify.app) theme. You usually find out when you open
Spotify and it looks plain again.

This little app sits in your system tray, notices the second that happens, and puts
Spicetify back for you. You don't have to do anything.

## What you get

- **Puts your theme back automatically** — no commands, no reinstalling
- **Never interrupts your music** — if Spotify is open, it waits until you close it
- **Works quietly in the background** — a small coloured dot in your tray is all you see
- **Starts with your PC** so it's always watching
- **One-click fix** any time, from the tray menu

The dot tells you what's going on:

🟢 theme is on &nbsp;&nbsp; 🔴 theme is gone &nbsp;&nbsp; 🟡 fixing it now &nbsp;&nbsp; ⚪ paused

## Before you start

You need **Windows**, and **Spicetify already installed and working**. This app keeps
your existing setup alive — it doesn't set Spicetify up from scratch. If you don't have
it yet, follow [Spicetify's guide](https://spicetify.app/docs/getting-started) first.

## Install

1. Click the green **Code** button at the top of this page, then **Download ZIP**.
2. Right-click the downloaded file and choose **Extract All**.
3. Open the folder you just extracted.
4. Right-click **`install.ps1`** and choose **Run with PowerShell**.

That's it. A window will pop up for a few seconds, fix your theme if it's currently
broken, and then disappear. Look for the new dot in your system tray (you may need to
click the little **^** arrow to see hidden icons).

**If Windows blocks it**, open PowerShell and paste this instead, replacing the path
with wherever you extracted the folder:

```bash
powershell -ExecutionPolicy Bypass -File "C:\Users\You\Downloads\keep-spicetify-on\install.ps1"
```

## Using it

Right-click the tray dot for the menu:

| | |
| --- | --- |
| **Check now** | Look right now instead of waiting |
| **Repair now** | Force your theme back on |
| **Pause for 1 hour** | Stop it touching anything for a bit |
| **Start automatically at logon** | Keep it running after restarts (on by default) |
| **Block Spotify auto-updates** | Stop Spotify updating at all — see the warning below |
| **Open log** | See what it's been doing |

### About "Block Spotify auto-updates"

This stops Spotify updating itself, so your theme can never get wiped in the first
place. It's **off by default on purpose**: if you turn it on, you stop getting Spotify's
updates and security fixes until you turn it back off. Most people should leave it off
and just let the app fix things automatically.

## Uninstall

Right-click **`uninstall.ps1`** and choose **Run with PowerShell**.

Your Spotify and Spicetify are left exactly as they are — it only removes this app.

## Something not working?

- **No dot in the tray?** Click the **^** arrow near your clock; Windows hides new icons
  there. You can drag it out to keep it visible.
- **Theme still not coming back?** Open the log from the tray menu and have a look. Most
  often it means Spotify updated to a version Spicetify can't patch yet — running
  `spicetify upgrade` usually sorts it.
- **Using Spotify from the Microsoft Store?** Spicetify doesn't support that version.
  Install Spotify from [spotify.com](https://www.spotify.com/download/windows/) instead.

## For the curious

Want to know how it actually detects and fixes things, or how to change its settings?
That's written up in [docs/how-it-works.md](docs/how-it-works.md).

## Licence

MIT — do whatever you like with it. Not affiliated with Spotify or Spicetify.
