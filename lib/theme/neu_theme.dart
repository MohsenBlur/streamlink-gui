import 'package:flutter/material.dart';

import 'material/app_material.dart';
import 'material/skeuo_decoration.dart';

export 'neu_tokens.dart';
export 'neu_type.dart';

import 'neu_tokens.dart';

class NeuTheme {
  // Master Color Tokens (Extracted directly from reference Neumorphic design)

  /// The page behind the surfaces.
  ///
  /// Deliberately NOT the same as [lightSurface]. They used to be the same hex,
  /// so light mode had zero surface separation (1.000:1) and every raised card
  /// relied entirely on its shadow to be seen at all.
  ///
  /// The canvas is darkened rather than the surface lightened, which matters:
  /// [lightHighlight] is pure white, so a lighter surface would swallow the
  /// top-left bevel and kill the extrusion the whole look depends on. Moving
  /// the canvas instead gives 1.079:1 - mirroring dark's 1.068:1 - while every
  /// existing raised element renders exactly as before.
  static const Color lightBg = Color(0xFFE1E4EA);
  static const Color lightSurface = Color(0xFFEBECF0);
  static const Color lightText = Color(0xFF2D3748);

  /// 5.11:1 on the canvas, 4.89:1 on the well.
  ///
  /// Was #718096, which measured 3.40:1 - below WCAG AA - while being the
  /// default ink of [subtextStyle] at 11px, the most-used size in the app.
  static const Color lightSubtext = Color(0xFF4F5F75);
  static const Color lightHighlight = Color(0xFFFFFFFF);
  static const Color lightShadow = Color(0xFFA3B1C6);
  static const Color defaultLightAccent = Color(0xFFFF6584); // Soft Pink

  static const Color darkBg = Color(0xFF1D212A);
  static const Color darkSurface = Color(0xFF222632);
  static const Color darkText = Color(0xFFE2E8F0);
  // Lightened with the dark depth redesign: the elevation overlay lifts the
  // worst raised ground to surface+13% white, and the v1.6.0 value measured
  // 3.90:1 there. Part of the same fix - a flat dark theme usually has murky
  // secondary text too.
  static const Color darkSubtext = Color(0xFFABB7C8);
  // Deepened 2026-08-25 with the dark-Soft depth redesign: at #2B303F the
  // light-side cast sat 7 levels over the canvas and the look read flat
  // against its light counterpart. Read by the satellite widgets too (switch
  // knob, LED collar), which gain the same depth.
  static const Color darkHighlight = Color(0xFF39415A);
  static const Color darkShadow = Color(0xFF07090D);
  static const Color defaultDarkAccent = Color(0xFFFF3B30); // Vibrant Red

  // Semantic status colors, previously scattered as inline hexes across the
  // LED indicator, card border and title bar.
  static const Color live = Color(0xFF00E6A5);
  static const Color danger = Color(0xFFFF4565);

  /// Caution / degraded state. Previously re-invented per file as
  /// `Colors.orangeAccent` / `Colors.orange.shade800` at seven sites across
  /// five files - and that idiom measured 2.61:1 in light mode.
  static const Color warning = Color(0xFFFFB020);

  /// "This is favourited" - a distinct semantic from [warning], though both
  /// land in the amber family. Previously a bare `Colors.amber` with no
  /// light/dark branch at all, measuring 1.28:1 on the light canvas.
  static const Color favorite = Color(0xFFFFC24B);

  /// Text/icon variant of a brand fill, made readable on the active material.
  ///
  /// These were frozen `isDark ? hexA : hexB` switches whose doc comments
  /// recorded ratios measured against the grounds of **one** material. They do
  /// not survive a material that moves the ground: `liveText` #006B4B measures
  /// 4.55:1 on Soft's light well floor and **4.03:1** on Rack's champagne — and
  /// that failure is silent, because nothing recomputes.
  ///
  /// So they derive. A palette may pin one through `inkOverrides` for
  /// character — Soft pins all four, because "the look the app had before"
  /// includes its exact inks — but a pin still faces the contrast matrix. What
  /// it buys is character, never an exemption.
  static Color _semanticInk(String name, Color brand, bool isDark,
      {AppMaterial? material, double target = _inkTarget}) {
    final p = palette(isDark, material: material);
    return p.inkOverrides[name] ?? readableOn(brand, p, target: target);
  }

  static Color liveText(bool isDark, {AppMaterial? material}) =>
      _semanticInk('liveText', live, isDark, material: material);

  static Color dangerText(bool isDark, {AppMaterial? material}) =>
      _semanticInk('dangerText', danger, isDark, material: material);

  static Color warningText(bool isDark, {AppMaterial? material}) =>
      _semanticInk('warningText', warning, isDark, material: material);

  /// Held to the 3:1 non-text bar rather than 4.5:1, because it is always an
  /// icon and never a label.
  static Color favoriteText(bool isDark, {AppMaterial? material}) =>
      _semanticInk('favoriteText', favorite, isDark,
          material: material, target: kNonTextInk);

  /// The bar for meaningful non-text graphics, per WCAG 1.4.11.
  static const double kNonTextInk = 3.0;

  /// Ink for content rendered ON an accent fill.
  ///
  /// Picks whichever of white or [_onAccentInk] contrasts better, rather than
  /// asking whether the accent is "dark". `estimateBrightnessForColor` answers
  /// that question against a threshold equivalent to about 3.06:1, so it
  /// returned white for five of the eleven shipped accents where white
  /// measures below AA - Soft Pink 2.82, Magenta 3.55, Vibrant Red 3.55,
  /// Rose 3.67, Electric Purple 4.23. All eleven now pass, worst case 4.59.
  static Color onAccent(Color accent) =>
      contrastRatio(Colors.white, accent) >= contrastRatio(_onAccentInk, accent)
          ? Colors.white
          : _onAccentInk;

  /// Deeper than the previous #1A202C, which bought roughly 1.2x more contrast
  /// on every accent that resolves to dark ink.
  static const Color _onAccentInk = Color(0xFF0B0D12);

  /// Foreground-safe variant of [accent], for content drawn *in* the accent
  /// colour on an ordinary surface — text, icons, focus rings, thin strokes.
  ///
  /// [onAccent] solves the opposite problem (ink *on* an accent fill) and does
  /// not help here. Used raw as a foreground, the shipped accents measure as
  /// little as 1.09:1 on the light canvas (Cyan), and even the default Soft
  /// Pink manages only 2.21:1 — so accent-coloured labels and the keyboard
  /// focus ring were effectively invisible in light mode.
  ///
  /// The value is derived rather than the palette being restricted, for three
  /// reasons: restricting deletes user choice, it would invalidate accents
  /// already saved, and it would not even close the hole, since the hex is a
  /// hand-editable string in channels_config.json and the picker is not the
  /// only way a value arrives. Derivation is total — **the stored accent is
  /// never rewritten**, it is only adjusted at render time, so fills, tints
  /// and glows keep the exact colour the user chose.
  ///
  /// Resolved against the *lowest-contrast* ground in the theme (the well in
  /// light mode, the surface in dark), so one value is safe on all of them.
  ///
  /// Cost is a short loop, so callers should cache — see
  /// `AppThemeNotifier.accentInk`.
  /// How much of the accent a SELECTED control washes over its ground.
  ///
  /// Shared with `NeuButton` so the derivation and the fill cannot drift: the
  /// ink has to be readable on the exact wash the control paints, and a
  /// constant in one file and a literal in the other is how that stops being
  /// true without anything failing.
  static const double selectedTintAlpha = 0.15;

  static Color accentInk(Color accent, bool isDark, {AppMaterial? material}) {
    final p = palette(isDark, material: material);
    // An accent lands on two kinds of ground, and deriving against only the
    // first is how a *selected* control ends up with its label at 4.07:1.
    //
    // Ordinary surfaces are one. The other is the accent's own wash: a
    // selected control fills with `accent @ selectedTintAlpha` and then paints
    // the label on top, so ink and ground are the same hue at close lightness -
    // the hardest case there is, and the one nobody thinks to measure because
    // the ground is not in the palette.
    return readableOnAll(accent, p, grounds: accentGrounds(accent, p));
  }

  /// Every ground the accent is drawn on, as a foreground.
  ///
  /// Public because the contrast tests have to measure against exactly this
  /// set. A test that checks a narrower set will report an ink as "already
  /// readable" when the derivation can see that it is not, which reads as the
  /// derivation restyling something it should have left alone.
  static List<Color> accentGrounds(Color accent, MaterialPalette p) => <Color>[
        p.inkGround,
        for (final role in const [
          SurfaceRole.sunken,
          SurfaceRole.raised,
          SurfaceRole.panel,
        ])
          Color.alphaBlend(
              accent.withValues(alpha: selectedTintAlpha), p.worstGround(role)),
      ];

  /// [readableOn], but the result has to clear the bar on **every** ground.
  ///
  /// Walking against the single worst ground is not enough once the grounds
  /// are not ordered the same way for every candidate: darkening ink helps it
  /// on a light surface and hurts it on the accent's own dark wash, so the
  /// "worst" ground changes as the walk proceeds. Checking all of them at each
  /// step is the only formulation that terminates on the right value.
  static Color readableOnAll(
    Color source,
    MaterialPalette p, {
    required List<Color> grounds,
    double target = _inkTarget,
  }) {
    bool clears(Color c) =>
        grounds.every((g) => contrastRatio(c, g) >= target);
    if (clears(source)) return source;

    final hsl = HSLColor.fromColor(source);
    final darken = p.isLight;
    final saturation =
        darken ? (hsl.saturation * 1.10).clamp(0.0, 1.0) : hsl.saturation;
    for (var i = 1; i <= 200; i++) {
      final lightness = darken
          ? (hsl.lightness - i * 0.005).clamp(0.03, 1.0)
          : (hsl.lightness + i * 0.005).clamp(0.0, 0.97);
      final candidate =
          hsl.withSaturation(saturation).withLightness(lightness).toColor();
      if (clears(candidate)) return candidate;
    }
    return p.text;
  }

  /// The accent made readable on a [SurfaceRole.screen].
  ///
  /// A separate derivation because a screen is dark in **both** brightnesses,
  /// and asking one colour to clear 4.5:1 against a light material's canvas
  /// *and* against its near-black screen is an empty set — the best any single
  /// colour manages across such a pair is about 3.73:1. A single-direction
  /// walk would exhaust its 200 steps and fall through to the plain text ink,
  /// silently discarding the accent the user picked.
  static Color accentInkOnScreen(Color accent, bool isDark,
          {AppMaterial? material}) =>
      inkOnScreen(accent, isDark, material: material);

  /// Any brand colour walked until it is readable on a given ground.
  ///
  /// Generalised from `accentInk` so the semantic inks can stop being fifty
  /// hand-calibrated hexes. `liveText` and friends were frozen `isDark ? a : b`
  /// switches whose doc comments recorded ratios measured against *today's*
  /// grounds; they do not survive a material that moves the ground, and
  /// duplicating them per material would be fifty values to keep true forever.
  ///
  /// Walks lightness in the direction that helps: darker on a light ground,
  /// lighter on a dark one. Saturation is nudged up when darkening, because
  /// darkening desaturates perceptually and the point is to keep the hue
  /// recognisable as the colour that was asked for.
  static Color readableOn(
    Color source,
    MaterialPalette p, {
    double target = _inkTarget,
    Color? ground,
    bool? darken,
  }) {
    final g = ground ?? p.inkGround;
    if (contrastRatio(source, g) >= target) return source;

    final hsl = HSLColor.fromColor(source);
    // The direction belongs to the PALETTE, not to this particular ground.
    // A light material's worst ground can be mid-tone once its fill has
    // darkened the well - Rack's is #B3B1AB - and choosing by the ground's own
    // luminance would then try to *lighten* ink that has to stay dark, walk
    //200 steps without clearing, and fall through to the plain text colour.
    // Overridable, because the default is a statement about the palette's
    // *surface* family and one ground in the app is not part of it. See
    // `inkOnScreen`.
    final goDark = darken ?? p.isLight;
    final saturation =
        goDark ? (hsl.saturation * 1.10).clamp(0.0, 1.0) : hsl.saturation;

    for (var i = 1; i <= 200; i++) {
      final lightness = goDark
          ? (hsl.lightness - i * 0.005).clamp(0.03, 1.0)
          : (hsl.lightness + i * 0.005).clamp(0.0, 0.97);
      final candidate =
          hsl.withSaturation(saturation).withLightness(lightness).toColor();
      if (contrastRatio(candidate, g) >= target) return candidate;
    }
    // A fully achromatic source can run out of headroom before clearing the
    // bar; fall back to the palette's own text ink rather than returning
    // something unreadable.
    return p.text;
  }

  static const double _inkTarget = 4.5;

  /// WCAG 2.x relative-contrast ratio between two opaque colors.
  ///
  /// `Color.computeLuminance()` already implements the sRGB-linearised
  /// relative luminance the formula calls for.
  static double contrastRatio(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    final hi = la > lb ? la : lb;
    final lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }

  /// Recessed "well" surface (track slots, sockets, sunken fields).
  ///
  /// Canonicalized on the value most widgets already used; NeuContainer's
  /// slightly different light well was the outlier.
  static Color wellSurface(bool isDark, {AppMaterial? material}) =>
      palette(isDark, material: material).well;

  /// Keyboard-focus visual consistent with the neumorphic style: an accent
  /// border with a soft outer glow, readable on both themes' low-contrast
  /// surfaces.
  static BoxDecoration focusRing(bool isDark, Color accent, {double radius = 16}) {
    return BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: accent, width: 2),
      boxShadow: [
        BoxShadow(
          color: accent.withValues(alpha: 0.35),
          blurRadius: 6,
          spreadRadius: 1,
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------
  // Raw tokens vs resolved tokens.
  //
  // The `raw*` functions are the v1.6.0 values, frozen. They exist because
  // `Soft`'s palette is built FROM them: if the public accessors dispatched to
  // the palette and the palette read the public accessors, the first colour
  // read would recurse forever.
  //
  // Everything public below reads the ACTIVE MATERIAL's palette. Every one
  // keeps its `(bool isDark)` shape, so all ~330 call sites compile unchanged,
  // and every one gains an optional `material` — which is not a convenience:
  // the Settings picker previews a material that is not active, the contrast
  // matrix iterates all of them, and widget tests call these with a literal
  // bool and no notifier configured.
  // ---------------------------------------------------------------------

  static Color rawCanvas(bool isDark) => isDark ? darkBg : lightBg;
  static Color rawSurface(bool isDark) => isDark ? darkSurface : lightSurface;
  static Color rawText(bool isDark) => isDark ? darkText : lightText;
  static Color rawSubtext(bool isDark) => isDark ? darkSubtext : lightSubtext;
  static Color rawHighlight(bool isDark) =>
      isDark ? darkHighlight : lightHighlight;
  static Color rawShadow(bool isDark) => isDark ? darkShadow : lightShadow;
  static Color rawDisabledText(bool isDark) =>
      // Dark lightened with the depth redesign (2.10:1 on the lifted worst
      // ground); light untouched.
      isDark ? const Color(0xFF93A0B2) : const Color(0xFF6C7A91);
  static Color rawWellSurface(bool isDark) =>
      isDark ? const Color(0xFF13151A) : const Color(0xFFD8E0EB);
  static Color rawBorder(bool isDark) => isDark
      ? const Color(0xFF49566B).withValues(alpha: 0.8)
      : const Color(0xFF8494AD).withValues(alpha: 0.9);
  static Color rawTerminalBg(bool isDark) =>
      isDark ? const Color(0xFF0F131E) : const Color(0xFFF8FAFC);

  /// The page behind everything. [background] is kept as an alias so the ~30
  /// existing call sites need no edit.
  static Color canvas(bool isDark, {AppMaterial? material}) =>
      palette(isDark, material: material).canvas;
  static Color background(bool isDark, {AppMaterial? material}) =>
      canvas(isDark, material: material);
  static Color surface(bool isDark, {AppMaterial? material}) =>
      palette(isDark, material: material).surface;
  static Color text(bool isDark, {AppMaterial? material}) =>
      palette(isDark, material: material).text;
  static Color subtext(bool isDark, {AppMaterial? material}) =>
      palette(isDark, material: material).subtext;

  /// 3.18:1 at worst in light mode, held to the 3:1 non-text bar.
  ///
  /// Was #A0AEC0 = 1.91:1, which NeuButton then multiplied by `Opacity(0.45)`.
  /// This value is calibrated to be exactly as dim as it should be, so nothing
  /// may dim it further - the disabled affordance is carried by the flat
  /// (shadowless) treatment and the cursor, not by fading the label away.
  static Color disabledText(bool isDark, {AppMaterial? material}) =>
      palette(isDark, material: material).disabledText;
  static Color highlight(bool isDark, {AppMaterial? material}) =>
      palette(isDark, material: material).highlight;
  static Color shadow(bool isDark, {AppMaterial? material}) =>
      palette(isDark, material: material).shadow;

  /// Component boundaries: 2.19:1 light (was 1.33), 1.74:1 dark (was 1.15).
  ///
  /// Deliberately short of WCAG 1.4.11's 3:1. Reaching it needs a hard
  /// hairline that destroys the soft-material read this app is built on, so
  /// the boundary is strengthened as far as the style allows and the burden of
  /// meeting the standard is carried by the focus ring instead, which is held
  /// to >= 4.5:1.
  static Color border(bool isDark, {AppMaterial? material}) =>
      palette(isDark, material: material).border;

  /// The log pane's ground. Tracks the material's `screen`, because a log pane
  /// is a display set into a bezel and that is what `screen` means.
  static Color terminalBg(bool isDark, {AppMaterial? material}) =>
      palette(isDark, material: material).screen;

  // Unified Typography Tokens
  // titleStyle / bodyStyle / subtextStyle lived here. Each took an overridable
  // fontSize and EVERY call site overrode it, so they unified colour and
  // nothing else - 17 distinct sizes across 271 sites. NeuType replaces them
  // with named steps; see neu_type.dart.

  // ---------------------------------------------------------------------
  // The one neumorphic recipe.
  //
  // There were two, and they did not match. This flat token painted a solid
  // colour with hardcoded +/-5 offsets and no depth parameter; NeuContainer
  // painted a top-left gradient with depth-driven offsets and a highlight
  // border. A comment in neu_container.dart claimed they were "the same
  // recipe" - they differed on three of five properties, so two adjacent
  // raised surfaces built through different paths visibly disagreed.
  //
  // The gradient recipe wins, for three reasons: only it can express state
  // (NeuButton already drives depth on press and hover, and the flat one has
  // no depth parameter at all, so 36 surfaces were frozen at one elevation);
  // the gradient IS the neumorphism, since a flat rectangle with two drop
  // shadows reads as a card WITH a shadow rather than material extruded from
  // the surface; and the flat version is a strict subset of it.
  // ---------------------------------------------------------------------

  /// Shifts a colour's HSL lightness.
  ///
  /// Replaces a flat per-channel RGB offset, which is not perceptually
  /// uniform, clips at 0, and misbehaved on the translucent bases NeuButton
  /// passes for its selected state. On the dark well the old offset landed
  /// near-black; this stays proportional.
  /// How far a raised fill's gradient darkens from its base, in HSL lightness.
  ///
  /// Public because it is not a private styling detail: it is the difference
  /// between the colour a token declares and the colour text actually lands
  /// on, and WCAG F83 judges contrast against the latter.
  static const double fillSpread = 0.030;

  /// The darkest point a raised fill reaches - the real ground under text.
  ///
  /// A gradient means an ink sits on a *range* of colours, and F83's rule is
  /// the worst pixel behind the letter, not the declared base. Checking the
  /// base alone hid seven genuine failures in the light theme: liveText,
  /// dangerText, warningText, disabledText and favoriteText all cleared their
  /// bar against the flat token and missed it by 0.05-0.25 against the floor.
  static Color fillFloor(Color base) => _shade(base, -fillSpread);

  static Color _shade(Color base, double delta) {
    final hsl = HSLColor.fromColor(base);
    return hsl.withLightness((hsl.lightness + delta).clamp(0.0, 1.0)).toColor();
  }

  /// The palette the engine paints from.
  ///
  /// `material` defaults to the active one. It is not a convenience: the
  /// Settings picker previews a material that is *not* active, the contrast
  /// matrix iterates all of them, and widget tests call these with a literal
  /// `isDark` and no notifier configured. Global-only dispatch forbids all
  /// three.
  static MaterialPalette palette(bool isDark, {AppMaterial? material}) =>
      MaterialSpec.of(material ?? activeMaterial).palette(isDark);

  /// Which material the app is wearing.
  ///
  /// A plain static rather than a read through the notifier, so `neu_theme`
  /// does not depend on the widget layer. `AppThemeNotifier.setMaterial`
  /// assigns it, in the same call that invalidates the derived-colour cache.
  /// Rack, not Soft. Shipping the work behind an off-by-default switch means
  /// nobody sees it; `Soft (classic)` is one dropdown away and persists.
  static AppMaterial activeMaterial = AppMaterial.rack;

  /// A surface extruded from the page.
  ///
  /// Returns a `Decoration`, not a `BoxDecoration`: a material needs seven
  /// paint layers including a true inset shadow, and `BoxDecoration` can carry
  /// two. Every call site assigns into a `decoration:` or
  /// `foregroundDecoration:` slot that already accepts the wider type.
  static Decoration raised(
    bool isDark, {
    Color? base,
    double radius = NeuRadius.r12,
    double depth = NeuElevation.d3,
    double? blur,
    Border? border,
    Gradient? gradient,
    bool circle = false,
    AppMaterial? material,
  }) =>
      SkeuoDecoration.role(
        palette: palette(isDark, material: material),
        role: SurfaceRole.raised,
        depth: depth,
        radius: radius,
        circle: circle,
        base: base,
        border: border,
        gradient: gradient,
        blur: blur,
      );

  /// A surface recessed into the page.
  ///
  /// The base defaults to [wellSurface], not [surface]. A sunken thing is a
  /// well; defaulting to the surface colour meant NeuSwitch's off-track was
  /// the exact colour of the panel behind it, so **the off state was invisible
  /// in light mode**. That default now lives in the role table, which routes
  /// `sunken` to `Ground.well`.
  static Decoration sunken(
    bool isDark, {
    Color? base,
    double radius = NeuRadius.r12,
    double depth = NeuElevation.d2,
    double? blur,
    Border? border,
    bool circle = false,
    AppMaterial? material,
  }) =>
      SkeuoDecoration.role(
        palette: palette(isDark, material: material),
        role: SurfaceRole.sunken,
        depth: depth,
        radius: radius,
        circle: circle,
        base: base,
        border: border,
        blur: blur,
      );

  /// A faceplate: textured, bevelled, lightly shadowed.
  static Decoration panel(
    bool isDark, {
    Color? base,
    double radius = NeuRadius.r12,
    double depth = NeuElevation.d2,
    Border? border,
    bool circle = false,
    AppMaterial? material,
  }) =>
      SkeuoDecoration.role(
        palette: palette(isDark, material: material),
        role: SurfaceRole.panel,
        depth: depth,
        radius: radius,
        circle: circle,
        base: base,
        border: border,
      );

  /// Inset glass — a display set into a bezel.
  /// The hairline that separates a status dot from whatever is behind it.
  ///
  /// Five sites drew this ring in the **surface colour**, knocking the dot out
  /// of the avatar underneath. That works exactly as long as the ring's colour
  /// is the colour behind it, and a material breaks the premise rather than
  /// the value: a dot sits at an avatar's bottom-right corner, half over the
  /// picture and half over the panel, and the panel now carries a fill ramp
  /// and a grain. A flat ring over that is a small bright disc — the dot stops
  /// reading as a dot and starts reading as a target. No colour swap fixes it,
  /// because there is no single colour that matches a gradient.
  ///
  /// So the ring stops matching anything and becomes a **darkening**, which is
  /// ground-independent by construction. On a light ground it is a dark
  /// hairline; on a dark ground it vanishes into it, which is correct — there
  /// the dot's own edge is what separates it, and a bright green dot on a
  /// graphite panel needs no help.
  ///
  /// That makes the right question a disjunction rather than a ratio: for
  /// every ground, *either* the ring separates the dot from what is behind it
  /// *or* the dot separates itself. `status_ring_test` asserts exactly that,
  /// and the alpha below is the sweep's answer rather than a value picked by
  /// eye. Worst-case legibility climbs steeply to 0.74 and is flat above it —
  /// the ceiling is an offline dot on a black avatar, where the ring is black
  /// too and no alpha can help — so 0.74 is the lightest touch that reaches
  /// the best result available. Every lighter value is strictly worse and
  /// every heavier one is gratuitously heavier for nothing.
  ///
  /// The binding case is the *offline* dot, not the live one. That was not
  /// obvious: the live green is bright and clears the bar against a white
  /// avatar at 0.54, while `disabledText` is a mid-tone and mid-tones have the
  /// least room in both directions.
  static Border statusRing({double width = 1}) =>
      Border.all(color: statusRingInk, width: width);

  static const Color statusRingInk = Color(0xBD000000);

  /// The rim around a recessed display, painted **over** what it surrounds.
  ///
  /// Null when the material declares no bezel, which is how Soft opts out
  /// without the call site knowing Soft exists. A null `foregroundDecoration`
  /// paints nothing, so the site is `foregroundDecoration: NeuTheme.bezel(...)`
  /// with no conditional around it.
  ///
  /// It is the `screen` role minus its fill: the same inverted bevel, the same
  /// inset band and the same edge, over a picture that has to survive. Painting
  /// the fill would obliterate the thumbnail this exists to frame.
  static Decoration? bezel(
    bool isDark, {
    double radius = NeuRadius.r12,
    double depth = NeuElevation.d2,
    Border? border,
    AppMaterial? material,
  }) {
    final id = material ?? activeMaterial;
    if (!MaterialSpec.of(id).furniture.bezels) return null;
    return SkeuoDecoration.role(
      palette: palette(isDark, material: id),
      role: SurfaceRole.screen,
      depth: depth,
      radius: radius,
      border: border,
      fillOpacity: 0,
    );
  }

  /// Ink for text drawn on a [SurfaceRole.screen].
  ///
  /// Not the same as [text], and the gap is not cosmetic. A lit readout stays
  /// dark in a lit room, so a material's screen is dark in **both**
  /// brightnesses — which means in light mode `text` and `screen` are both
  /// dark and measure as little as 1.08:1 against each other. Every string
  /// inside a log pane or a readout takes this instead.
  static Color screenText(bool isDark, {AppMaterial? material}) =>
      palette(isDark, material: material).screenText;

  static Color screenSubtext(bool isDark, {AppMaterial? material}) =>
      palette(isDark, material: material).screenSubtext;

  /// Any colour walked until it is readable on the screen ground.
  ///
  /// The semantic inks need this for exactly the reason above: `dangerText` is
  /// calibrated against the surface, and a log line coloured by severity lands
  /// on the screen instead.
  /// Any colour walked until it is readable on the screen ground.
  ///
  /// Two things here are not the obvious ones, and the contrast matrix caught
  /// both the first time it ran.
  ///
  /// The ground is the screen's **worst stop**, not the flat `screen` token.
  /// The screen role carries a fill like every other role, so no log line has
  /// ever sat on the declared colour — this is the same F83 correction the
  /// ordinary grounds got, applied to the one ground that had been left out.
  /// Against the flat token the dark theme derived inks measuring 4.09:1.
  ///
  /// The direction is read from the ground rather than from the palette. That
  /// is the opposite of [readableOn]'s default, and deliberately: the default
  /// exists because a light material's worst *surface* ground can be mid-tone
  /// and choosing by luminance would try to lighten ink that has to stay dark.
  /// A screen is not a family of surfaces, it is one surface, and an emissive
  /// one is dark inside a light material — so the palette's own direction is
  /// exactly wrong there. Left as the default, every light material's log ink
  /// walked *darker* against a near-black screen, exhausted its 200 steps and
  /// fell through to the plain text colour at 1.08:1.
  static Color inkOnScreen(Color source, bool isDark,
      {AppMaterial? material}) {
    final p = palette(isDark, material: material);
    return readableOn(
      source,
      p,
      ground: p.worstGround(SurfaceRole.screen),
      darken: p.inkIsDarkOn(SurfaceRole.screen),
    );
  }

  static Decoration screen(
    bool isDark, {
    Color? base,
    double radius = NeuRadius.r12,
    double depth = NeuElevation.d2,
    Border? border,
    bool circle = false,
    AppMaterial? material,
  }) =>
      SkeuoDecoration.role(
        palette: palette(isDark, material: material),
        role: SurfaceRole.screen,
        depth: depth,
        radius: radius,
        circle: circle,
        base: base,
        border: border,
      );

  /// Kept so the ~36 existing call sites need no edit. They silently gain the
  /// gradient and a depth parameter.
  static Decoration raisedDecoration(bool isDark,
          {Color? customBase, double radius = NeuRadius.r12, Border? border}) =>
      raised(isDark, base: customBase, radius: radius, border: border);

  /// Kept for the same reason. Note the base default change documented on
  /// [sunken]: call sites that want the panel colour must now say so.
  static Decoration sunkenDecoration(bool isDark,
          {Color? customBase, double radius = NeuRadius.r12, Border? border}) =>
      sunken(isDark, base: customBase, radius: radius, border: border);
}
