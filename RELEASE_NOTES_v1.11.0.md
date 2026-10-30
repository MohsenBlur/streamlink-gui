# v1.11.0 — the window always shows, and the lists keep themselves fresh

A large clean-up release: the two most annoying bugs are gone, your Twitch
login is now stored encrypted, and there is a new option to download several
VODs at once.

## Read this first: going back to v1.10.0 means signing in again

Your Twitch login is now **encrypted** with Windows' own protection for your
user account instead of being kept as plain text in the settings file. This
happens automatically the first time v1.11.0 starts.

v1.10.0 cannot read the encrypted login. If you ever reinstall v1.10.0, you
will need to sign in to Twitch again. Nothing else is lost.

Updating also deletes the old plain-text copy of the settings that earlier
versions could leave in the install folder under Program Files.

## The window no longer opens invisible

Started from the Start menu or at login, the app could open as a faint outline
with nothing inside it. The window existed, but the part that draws the app
inside it was never made visible. This happened most often when installed
under Program Files.

The app now checks, right after it first draws, that its content is actually
on screen, and fixes it if not. It also remembers its position and size more
reliably, and no longer steals focus when it starts in the background.

## Channels and VODs update without reselecting the channel

Live status and VOD lists could go stale until you clicked a different channel
and back. They now refresh on their own, whichever channel is open.

## Download several VODs at once (optional)

**Settings → Downloads → Simultaneous downloads** sets how many VODs download
at the same time, from 1 to 4. It stays at 1 unless you change it.

Measured on a fast connection, Twitch sends each download at its own pace,
usually below what the connection can take:

| At once | Total speed |
|---|---|
| 1 | about 35 MiB/s |
| 2 | about 61 MiB/s |
| 3 | about 74 MiB/s |
| 4 | about 77 MiB/s |

Each download is a little slower while they share the connection, but the
queue as a whole finishes much sooner. Beyond 3 there is little to gain.

## MPC-HC is controlled privately now

The app used to switch on MPC-HC's built-in web interface to read the playback
position and to seek. That interface has no password, so while a VOD played,
web pages and other computers on your network could control the player.

The app now uses MPC-HC's private control connection instead, and no longer
changes any MPC-HC setting. Resuming, seeking, saving your place and recovering
from a dropped stream work as before. MPC-BE is now started without an option
it refused to open with.

## One look: Soft

The Broadcast rack, Warm analogue and Retro AV deck looks have been removed.
**Soft** (the classic look) is unchanged, in light and dark, with your accent
colours. If you had one of the removed looks selected, the app opens in Soft.

## Also fixed

- A channel that went offline and came back is announced, and auto-played,
  again. A channel the app only *assumed* was offline because a few checks
  failed is still not announced twice.
- Auto-download no longer downloads the same VOD over and over after you
  delete it or cancel it.
- A custom player is recognised by its program's name only. MPC-HC kept in a
  folder whose name contained "vlc" or "mpv" was started with the wrong options.
- Portable copies each have their own single-instance check, so a portable copy
  and an installed copy no longer get in each other's way.
- Many smaller fixes to downloads, playback and settings found during a full
  review of the code.
