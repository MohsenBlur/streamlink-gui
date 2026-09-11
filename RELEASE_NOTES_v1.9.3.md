# v1.9.3 — reconnecting updates the screen too

A fix release for v1.9.2.

## The error stayed on screen after signing back in

After reconnecting your Twitch account, a channel could keep showing

> Helix Stream API error: status 401

for up to a minute, and then clear on its own. Nothing was wrong — the account
was already working. The screen was just showing what it had been told while
the old token was still dead.

When a channel fails to load, the app remembers the failure against that
channel and only forgets it the next time that same channel is fetched
successfully. Reconnecting reloaded your **followed** list and nothing else, so
your favourites kept the old error until a routine background refresh came
round a minute later and quietly fixed it.

Signing back in now refreshes everything the outage made stale — favourites,
followed channels, and the video list of whichever channel you have open. In
testing, a channel showing the error went back to normal within about fifteen
seconds of clicking Reconnect, instead of waiting on the background refresh.

This also covers pasting a working token into Settings, which never triggered a
refresh at all.

## Also fixed

- Dismissing the reconnect warning used to silence it permanently, as long as
  the next problem had the same cause — so a genuine expiry weeks later would
  say nothing. The warning is re-armed once the account is working again.
- One more raw error message ("Twitch API returned 401 for helix/videos") no
  longer reaches the video list.
