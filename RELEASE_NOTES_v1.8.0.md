# v1.8.0 — lit surfaces

v1.7.0 built a material engine that painted surfaces out of gradients. This
release replaces that with one that **lights** them.

Every panel, card, button and well is now drawn by a fragment shader that
computes a surface normal for each pixel and shades it. That is the whole
difference between a lit object and a picture of one: the highlight travels
when the light moves, the edge brightens where it faces the light and falls
away where it turns from it, the reflection changes with the surface, and a
recess is genuinely inverted rather than just a darker box.

No layout moved. Every control is exactly where it was.

## What you will notice

**Machined edges.** Cards and panels have a real chamfer — a flat land held
at one angle with a crisp arris at each end, which is why a milled faceplate
catches a single even line of light. The bottom edge stays dark but still
carries a bright rim, because at a grazing angle every material reflects
almost everything.

**Things sit in pockets.** A contact shadow hugs each silhouette and the cast
falls away from the light. Controls read as objects dropped into recesses
rather than stickers with a drop shadow.

**Small controls are pillowed.** Buttons and chips take a wider, rounder
edge and a domed face, the way small parts are actually finished; cards and
panels keep the crisp machined land.

**Brushed grain** runs across the metal, and because it tilts the surface
rather than tinting it, it sparkles under the sheen and disappears in shadow
— as brushed aluminium does.

## Instruments

Live state is rendered as hardware instead of as web widgets:

- **Progress bars** are milled slots with a fill that glows.
- **Status dots are lamps** — the sidebar's connection lamp, the log viewer's
  red fault light, the onboarding step lenses.
- **The activity readout** in the title bar is dark glass set into the panel,
  like the log pane.
- **LIVE and NOW PLAYING** badges are backlit; informational chips stay flat.
- **Separators are engraved grooves**, not grey lines.

## Soft (classic), rebuilt in the dark

Soft's dark theme was noticeably flatter than its light counterpart, and
measurably so: its shadow landed 8 levels below the canvas where the light
theme's lands 40+ below its own — a dark shadow on a dark ground has almost
nowhere to go. Its highlight and shadow are much deeper now and the casts
carry all of the depth, so raised elements read as pushed-up regions of the
same slab rather than panels floating above it. Secondary text was lightened
to match.

Light mode is untouched, pixel for pixel, and still verified against a frozen
copy of the original recipe on every build.

## Fixes

- **Shadows were being cut off** wherever a scrolling strip or list clipped
  tightly against its contents — filter chips, the Continue-watching row, the
  Library rails, the sidebar list, dialog panes. Every one of them now
  reserves the room a shadow actually needs, from a single shared definition.
- **The Actions button in the VOD selection bar did nothing.** So did clicking
  a live channel in the collapsed sidebar rail — it launched a player instead
  of opening the channel. Both were the same underlying mistake.
- **The Display menu button looked disabled** and could not be reached by
  keyboard. Every popover trigger now has a proper cursor, keyboard access
  and screen-reader semantics.
- **Hovering a Quick Action rewrote its title** — "Twitch Account" became
  "Twitch Accou…" under the pointer, and the card's contents shifted.
- **The search field drew a box inside itself.**
- **Text was failing contrast in seven places** that the app's own checks
  could not see, because they measured a flat colour while the surface
  painted a gradient. Contrast is now measured against the worst pixel a
  letter can actually land on, per material, per theme.
- **"Connect Account" left Settings without saving or restoring**, so the
  session ran on a material the config did not record and the next launch
  reverted it. Saving Settings could also overwrite a material chosen by a
  newer build.
- **The first frame showed the wrong material** for anyone not on the
  defaults.
- One consistency pass over the whole interface: one way of saying LIVE, one
  icon-button behaviour, one hover language for cards and another for rows,
  one spinner, one set of type steps in dialog footers.

## Under the hood

If the shader cannot be loaded for any reason, every surface falls back to
the v1.7.1 painter rather than failing — the worst case is that the app looks
like last release.
