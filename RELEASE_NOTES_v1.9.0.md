# v1.9.0 — three machines, and a VOD that survives being paused

Two new materials, a rebuilt sense of what a material *is*, and a fix for
the bug that made pausing a streamed VOD lose your place.

## Pausing a VOD no longer kills it

Pause a streamed VOD for ten minutes or so, come back, press play: it would
run for a second and then stop as if the video had ended. Worse, relaunching
started from the beginning — the resume mark was gone.

Two separate faults, both fixed.

**The stream died and nothing noticed.** Twitch closes a connection that has
been idle, and the player treats the failed fetch as end-of-file. Nothing
retried. Now the app detects an end-of-stream that arrives mid-VOD, kills the
dead session and relaunches it at your exact position — a fresh launch gets a
fresh connection, which is the actual cure. It happens by itself, in a few
seconds, and the log tells you it happened. Capped at two attempts so it can
never loop, and **closing the player yourself never triggers it**.

**Your progress was being overwritten with a lie.** In its dying moments a
player can report a position it was never at, and the app believed it —
saving it locally *and* pushing it to Twitch, from where it came back even if
you cleared it. A position is now only saved once a second reading confirms
it, so a dying player's last gasp can never be recorded. Progress corrupted
by older versions is repaired the next time you open the VOD.

Both paths verified against the real players, including MPC-HC, whose
end-of-file signal turned out to be unlike the others': it jumps the position
to the full duration and pauses there — which is almost certainly what marked
half-watched VODs as complete.

## Two new materials

**Warm analogue** — a hi-fi console in a lamplit listening room. Light mode is
cream index cards on a parchment desk; dark is oiled walnut under a reading
lamp. Edges are routed rather than milled, shadows warm instead of grey, and
the whole window sits inside a **walnut case** with mitred corners, the way
every silver-face receiver did.

**Retro AV deck** — a mid-80s cassette deck. Black moulded bakelite, or its
grey silver-face trim. Its readouts glow fluorescent cyan in both light and
dark themes, because a fluorescent display does not care what colour the room
is, and they carry a fine scanline raster.

## The materials are now actually different

Each one now reshapes the window rather than just tinting it:

| | Broadcast rack | Warm analogue | Retro AV deck |
|---|---|---|---|
| Surface | brushed satin metal | wood grain, paper tooth | smooth gloss plastic |
| Window | bolted mounting rail | walnut case, all four edges | vent strip + silver band |
| Displays | blue dial glow | warm lamp glow | scanline VFD |
| Meters | LED segments, amber peak | brass needle on a scale | fluorescent cells |
| Lamps | machined socket | brass bezel | bare |

**The brushed metal is real now.** It was previously drawn as *added
brightness* — lines stamped on top of the lighting, which is exactly why it
looked painted on. The scratches are now surface geometry: they catch the
light where the light falls and disappear in shadow, like the real thing. The
grain also had a bug where it rendered at zero strength on ordinary displays,
so most people never saw it at all.

Sidebar rows in Broadcast rack are divided by engraved grooves like a
console's channel strips, and Retro AV deck frames its thumbnails in a
cassette window.

**Soft (classic) is untouched**, as always — pixel-for-pixel the look the app
had before materials existed.

## Also fixed

- Clicking a material in Settings did nothing the first time: its tooltip
  popped up underneath the pointer and swallowed the click.
- The Settings dialog, the title bar and the sidebar take their material's
  own treatment instead of a flat fill.
- Text contrast was re-derived against what each material actually paints, so
  the new lighting never costs legibility.
