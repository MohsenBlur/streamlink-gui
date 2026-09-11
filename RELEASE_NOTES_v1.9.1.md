# v1.9.1 — "Connected" now means connected

A fix release for v1.9.0.

## The app said Connected while Twitch said no

If your Twitch login expired, the app would show a red error across the top —

```
Error loading followed channels: Exception: Failed to get user profile:
{"error":"Unauthorized","status":401,"message":"Invalid OAuth token"}
```

— while Settings → Twitch showed a green tick reading **Connected**, and the
Test button reported **Success!**. Followed channels stopped loading and every
channel showed as Offline, with nothing anywhere telling you to sign in again.

Three separate things claimed to answer "are we connected?" and none of them
actually asked Twitch:

- **The green tick checked whether the token box was empty.** An expired token
  is still text in a box, so it showed Connected forever. It could only ever
  report that a token was *entered*, never that it *worked*.
- **The Test button tested the other token.** The app uses two: an **account
  token** for followed channels and VOD lists, and a **browser token** for
  watch-progress sync. Only the browser one had a Test button, and its success
  message didn't say which token it had tested — so a pass on one read as a
  pass on everything.
- **The only real check could only deliver good news.** A successful sign-in
  added your username to the badge, but a rejected one never took it away.
  That's why it read a bare "Connected" with no name: the app already knew the
  login had failed.

Now one answer is shared by the whole app, and every Twitch response updates
it. If your token is rejected you get a banner that says so plainly, with a
**Reconnect** button on it — not a pointer to where the button lives. Settings
shows the real state, and re-checks every time you open it.

## Everything as Offline was the same bug

Only one of the app's Twitch calls complained about a rejected token. The one
that refreshes each channel quietly treated the rejection as "this channel
isn't live" and gave up — so a dead login looked like all your favourites
having gone offline at once. Every call now reports.

## The two tokens are labelled

They're named for what they do — **Account token — followed channels, VOD
lists, ad-free** and **Browser token — watch-progress sync only** — and each
has its own Test button whose result names the token it tested.

The account token's Test also checks it against your **Client ID**, which is
the pairing that actually gets sent. If you change the Client ID after
connecting, the old token stops working with a rejection that looks exactly
like expiry — so the app used to tell you to reconnect, which cannot fix it.
It now recognises that case and tells you to restore the Client ID instead.

## Also fixed

- Error messages no longer paste raw Twitch API responses into the interface.
- The **Reconnect** and **Details** links on warning banners were nearly
  invisible — they took the accent colour, which disappears into the red
  warning strip. Measured at 1.39:1; they are 6:1 now.
- A dropped connection no longer looks like a rejected login: losing your
  network says "can't reach Twitch" and keeps showing who you were signed in
  as, instead of asking you to reconnect.
