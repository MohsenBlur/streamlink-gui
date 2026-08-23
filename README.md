# Twitch Streamlink GUI

A Windows desktop app for watching Twitch through your own media player. It
opens live streams and past broadcasts in **VLC**, **MPC-HC**, **MPV** or any
player you point it at, downloads VODs in the background, and keeps your watch
position across sessions.

Streamlink, yt-dlp, FFmpeg and a Python runtime are **bundled**. Download,
extract, run — there is nothing to install.

---

## Features

- **Live streams and VODs in your own player.** No embedded browser, no ads
  from the Twitch web player.
- **Seekable VOD streaming.** VODs stream with a working seek bar, so you can
  drag around the timeline without downloading the file first. Your position is
  remembered and playback resumes where you left off. (Settings → Player)
- **VOD downloads.** Queue any number; they download one at a time so a batch
  cannot saturate your connection. Progress shows in the title bar and in the
  Library.
- **Library.** Everything you have downloaded in one place, with size, watch
  progress, and filters by channel.
- **Favorites automation.**
  - *Priority auto-play* — when a favorite goes live, it opens automatically,
    following a priority order you drag into place.
  - *Auto-download* — new VODs from a favorite are fetched automatically, with
    a per-channel retention count and a rule that stops at VODs you have
    already watched past a threshold you set.
- **Tray and startup.** Closing the window keeps it monitoring in the tray, and
  it can start with Windows, optionally minimised.
- **Desktop notifications** when a favorite goes live, and when a download
  finishes or fails.
- **Light and dark themes** with a customisable accent colour.
- **Portable mode.** Settings normally live in `%APPDATA%`. Drop a file named
  `portable.txt` next to the executable and they move beside it instead, so the
  whole folder can be carried on a USB drive.
- **Self-updating.** Checks for new releases and applies them in place.

---

## Getting started

### Download

Get **`streamlink-gui-windows.zip`** from the
**[latest release](https://github.com/MohsenBlur/streamlink-gui/releases/latest)**.

Each release publishes a `SHA256SUMS` file. To check your download:

```powershell
Get-FileHash streamlink-gui-windows.zip -Algorithm SHA256
```

### Run

1. Extract the zip anywhere you can write to — your Downloads folder is fine.
   Avoid `C:\Program Files` unless you intend to run as administrator: the
   self-updater replaces the executable in place, which needs write access to
   that folder.
2. Run **`streamlink_gui.exe`**.
3. A first-run wizard walks you through choosing a player and a download
   folder.

### Watching

- **Add a channel** — type a username in the search box and press `+`.
- **Watch live** — click a channel, then the play button on its card. Or
  double-click the channel in the sidebar.
- **Watch a VOD** — pick a channel to see its past broadcasts, then play or
  download any of them.
- **Star a channel** to make it a favorite. Automation for all favorites lives
  behind the button at the top of the Favorites list in the sidebar.

### Connecting your Twitch account (optional)

Past broadcasts and your followed-channel list come from Twitch's API, which
needs a token. Settings → Twitch Auth explains what each one does. Without a token
the app still plays live streams; VOD listings will be empty.

---

## Building from source

You need **Windows**, **Git**, and **Visual Studio 2022** with the *Desktop
development with C++* workload. Everything else — including the Flutter SDK —
is fetched by the setup script into the project folder, so your machine's own
Flutter installation (if any) is left alone.

```powershell
git clone https://github.com/MohsenBlur/streamlink-gui.git
cd streamlink-gui

.\setup.ps1     # downloads and verifies a project-local Flutter SDK (~700 MB)
.\run.ps1       # runs the app in debug mode
.\build.ps1     # produces a release build in build\windows\x64\runner\Release
```

`run.ps1` and `build.ps1` both check the bundled runtime first and fetch it if
anything is missing, so you never get a build that compiles but cannot play
anything.

### What the scripts do

| Script | Purpose |
| --- | --- |
| `setup.ps1` | Downloads the pinned Flutter SDK into `.flutter-sdk\`, verifies its SHA-256, and configures it for Windows desktop. |
| `run.ps1` | `flutter run -d windows` using that local SDK. |
| `build.ps1` | Release build, with the version injected from `pubspec.yaml` so the in-app updater cannot drift from the release tag. |
| `tools\fetch-deps.ps1` | Downloads Streamlink, yt-dlp, FFmpeg and Python into `bin\`, each verified against the hash and size in `bin\deps_manifest.json`. |
| `tools\verify-bundle.ps1` | Fails if `bin\` is incomplete. Run by the build scripts and by CI. |

The contents of `bin\` are not committed — they are large, and reproducible
from the manifest.

The Flutter version is pinned once, in `tools\flutter-sdk.json`, and read from
there by `setup.ps1` and by both GitHub Actions workflows.

### Tests

```powershell
.\.flutter-sdk\flutter\bin\flutter.bat analyze
.\.flutter-sdk\flutter\bin\flutter.bat test
```

The logic that is worth testing lives in `lib\state\` and `lib\utils\`, which
are deliberately free of Flutter imports — command building, automation
decisions, the download registry, log-session lifecycle and settings parsing
are all covered there. CI runs both on every push.

---

## Layout

```
lib/
  main.dart      app shell, screens, wiring
  models/        settings and Twitch data types
  services/      processes, storage, Twitch API, updater, log store
  state/         pure logic, no Flutter imports - unit tested
  utils/         command-line building, formatting
  widgets/       reusable UI
bin/             bundled runtime (fetched, not committed)
tools/           dependency fetch/verify scripts, SDK pin
```

---

## Licence

No licence has been declared for this project yet, so default copyright
applies. The bundled components — Streamlink, yt-dlp, FFmpeg and Python — are
redistributed under their own licences.
