# v1.7.1 — the settings dialog, and the window ornament

A fix release for v1.7.0.

## The settings dialog was empty

In v1.7.0 the Settings dialog rendered its header and tabs and then a blank grey
rectangle where the content should be. **Only in the release build** — which is
why it shipped.

`NeuDialog`'s footer became a `Wrap` in v1.7.0, and the settings dialog passes a
`Flexible` as one of its footer items. A `Flexible` requires a `Flex` ancestor,
and Flutter checks for that *inside an assert*: a debug build logs the mistake,
declines to apply it and renders on looking perfectly correct, while a release
build strips the check, throws on the cast, and substitutes an error box.

Every screenshot taken while building v1.7.0 was a debug build.

The dialog now rejects that shape outright rather than relying on the
framework's silent-in-debug detection, the layout tests exercise the real footer
instead of a simplified one, and the screenshot tooling warns when it is pointed
at a debug build.

## The corner screws and the edge groove are gone

v1.7.0 put four slotted screws in the window corners and a milled groove just
inside the window edge. Both were wrong.

At 12px a slotted screw is indistinguishable from a minimise button, and the
top-right one sat immediately beside the real close button — it read as a
fourth, disabled window control. A groove reads as a groove because it is cut
into a plate that has a margin around it; this window's chrome reaches its own
edges, so it just drew a hairline across the interface.

The title bar no longer gives up 26px at each end to clear a screw that is not
there any more.

## Also fixed

- A tile request arriving just after a material switch could be dropped, leaving
  that surface permanently without its grain.
- Circular surfaces (every channel avatar, the round add button) were given a
  rounded-rectangle recess instead of a circular one.
- At the 380px minimum window the channel strip rendered a vertical slice of one
  avatar instead of either a whole one or nothing.
- The "Continue watching" row scrolled with its last card hard-clipped; it fades
  at the edges now.
