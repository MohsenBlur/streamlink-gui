# v1.7.0 — Materials

The app is made of something now.

Up to v1.6.0 it was *neumorphic*: soft extruded plastic imitating no particular
object. This release replaces that with a **material engine** and the first
material world built in it, selectable in **Settings → Appearance**.

## The material picker

Two materials ship in this release:

- **Broadcast rack** — a 19-inch milled aluminium faceplate. Graphite hard-anodise
  in dark, 1970s champagne silver-face in light. Horizontal brush grain, a milled
  edge groove, corner screws, engraved legends in DIN condensed, recessed dial
  windows.
- **Soft (classic)** — the exact look the app had through v1.6.0, pixel for pixel.

**The default changes to Broadcast rack**, on fresh install and on upgrade. If
you want the old look back it is one click: Settings → Appearance → Material →
Soft (classic). It is a permanent option, not a deprecated fallback — a test
paints both and fails the build if the classic recipe drifts by more than one
level of anti-aliasing.

Warm analogue, Retro AV deck and Polished glass follow in v1.8.0 and v1.9.0.

## What did not change

Every layout, breakpoint, control position, tap target and responsive behaviour
is where v1.6.0 left it. Only the material and the light changed.

## Fixes found along the way

Building the light material lit up several defects that had been invisible while
every surface was one flat colour:

- **Three live overflows** at the enforced 380×500 minimum window — the portrait
  rail (48px), the compact channel header (40px) and the dialog footer (17px).
  All three shipped, and none of them were reachable by the old overflow sweep,
  which pumped a copy of a card footer defined inside the test file rather than
  the real surfaces.
- **Headings frozen on the wrong theme.** A `const` widget that reads the theme
  global never rebuilds — Flutter skips the subtree entirely — so on a
  light-theme install several section headings rendered permanently in the dark
  theme's near-white ink. Six call sites.
- **Log-pane text at 1.08:1** in any light material. A lit readout stays dark in a
  lit room, so the screen is dark even in a light theme, and the ink that landed
  on it was calibrated for a light panel.
- **Sidebar ink splashes painting behind the row** they belonged to.
- **A lit LED dimming to 40%** mid-pulse, which reads as flickering rather than
  breathing.
- Seven contrast failures fixed before this work started, when the contrast test
  learned that `raised()` has always painted a gradient rather than a flat colour.

## Notes

- Panel legends use **Bahnschrift** where Windows provides it, requested through
  the `wght` and `wdth` font axes rather than by family name — the twelve
  `Bahnschrift *` family names Windows lists are GDI aliases and resolve to Segoe
  UI Semibold through Flutter. Every size and letterfit works in plain Segoe UI,
  so nothing depends on the face being present.
- The material choice is stored as a plain string and validated where it is used,
  so a config written by a newer build keeps its material rather than having it
  overwritten on the next window resize.
