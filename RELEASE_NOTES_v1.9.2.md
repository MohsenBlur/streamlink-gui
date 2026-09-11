# v1.9.2 — links open in your browser again

A fix release for v1.9.1.

## Reconnect offered the Microsoft Store

Clicking **Reconnect** — or any link in the app with a query string in it —
produced a Windows dialog instead of a browser:

> **Get an app to open this 'user' link.** Your PC doesn't have an app that can
> open this link.

Nothing was wrong with your PC. The app hands links to Windows Explorer to
open, and Explorer does not read its input the way ordinary programs do: given
a web address containing `&`, it chopped it into pieces and asked Windows to
open the last piece on its own. The Twitch sign-in address ends with
`scope=user:read:follows`, so Windows saw a `user:` link, found no app
registered for it, and offered to go looking in the Store.

Links without a query string were always fine, which is why the GitHub link
worked and this one didn't.

The address is now passed as a single quoted value, so it reaches your browser
whole. Verified by checking what actually arrives at the other end, rather than
by inspection.

Nothing else changed — if v1.9.1 is working for you, this only matters the next
time you click a link that has a `&` in it, which includes signing in.
