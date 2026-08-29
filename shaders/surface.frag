#version 460 core
#include <flutter/runtime_effect.glsl>

// ============================================================================
//  surface.frag - one lit surface, shadow and all, in a single draw.
//
//  Replaces seven Canvas layers (shadow stack, gradient fill, tiled texture,
//  gloss wash, 1px bevel ring, Path.combine+blur recess, border stroke) with
//  one drawRect. Every layer it replaces was a function of POSITION. This is a
//  function of a per-pixel surface NORMAL, which is the entire difference
//  between a lit object and a picture of one.
//
//  ---------------------------------------------------------------------------
//  HARD CONSTRAINTS - all verified by running the pinned 3.44.2 toolchain.
//  Windows/Flutter 3.44.2 renders with SKIA, so this compiles to SkSL and is
//  handed to SkRuntimeEffect::MakeForShader in strict-ES2 mode. Therefore:
//
//    * NO fwidth / dFdx / dFdy. They are ES3-gated; impellerc translates them
//      happily and Skia then rejects the shader AT LOAD. Edge width arrives as
//      a uniform (uBevel.y) instead.
//    * NO inverse / determinant / transpose. SPIRV-Cross emits spvInverse and
//      the SkSL backend never emits its definition -> "unknown identifier
//      spvInverse" at load.
//    * NO while / do-while, no dynamically-bounded for, no dynamic array
//      indexing. This file uses no loops at all.
//    * NO int / bool / uint uniforms. Floats only; cast inside.
//    * Output must be PREMULTIPLIED with rgb <= a.
//
//  FlutterFragCoord() is CANVAS-local, not shape-local (measured: a rect drawn
//  at offset 30,20 with no canvas translate reports fragCoord 30,20 there, not
//  0,0). The painter therefore translates to the draw rect origin and draws at
//  zero. Everything below assumes fc originates at the DRAW rect.
// ============================================================================

// --- geometry ---------------------------------------------------------------
uniform vec2 uDraw;     //  0,1  size of the draw rect (shape + 2*pad)
uniform vec2 uShape;    //  2,3  size of the surface itself
uniform vec2 uPadRad;   //  4,5  x = pad around the shape, y = corner radius
uniform vec4 uBevel;    //  6..9  x = chamfer width,
                        //        y = ONE DEVICE PIXEL in local units (the
                        //            fwidth replacement),
                        //        z = profile: 0 = bullnose fillet,
                        //            1 = flat machined land with two arrises,
                        //        w = land angle as a fraction of 90 degrees.

// --- material ---------------------------------------------------------------
uniform vec3 uAlbedo;   // 10,11,12  diffuse colour, sRGB
uniform vec3 uF0;       // 13,14,15  specular reflectance at normal incidence.
                        //           Dielectrics 0.04; aluminium 0.91/0.92/0.92
uniform vec4 uMat;      // 16..19    x roughness, y metalness,
                        //           z anisotropy, w face bow

// --- lighting ---------------------------------------------------------------
uniform vec3 uL;        // 20,21,22  unit vector TO the light, y-UP.
                        //           Precomputed in Dart: no trig per pixel.
uniform vec4 uKey;      // 23..26    x key intensity, y ambient,
                        //           z sheen (broad area lobe), w recess 0..1
uniform vec3 uSky;      // 27,28,29  environment above the horizon
uniform vec3 uGnd;      // 30,31,32  environment below it
uniform vec4 uEnv;      // 33..36    x env amount, y horizon softness,
                        //           z soft-box gain, w rim gain

// --- detail and depth -------------------------------------------------------
uniform vec4 uGrain;    // 37..40  x amplitude (normal tilt, NOT luminance),
                        //         y ACROSS-grain wavelength in logical px.
                        //           Must stay above ~2.5 logical px at dpr 1
                        //           or the Nyquist guard below erases it.
                        //         z brush angle (rad), w seed
uniform vec4 uShadow;   // 41..44  x dx, y dy (y-UP), z blur, w opacity
uniform vec4 uOcc;      // 45..48  x contact-AO opacity, y AO reach,
                        //         z inner-shadow blur, w inner-shadow opacity
uniform vec4 uTone;     // 49..52  x exposure, y white point,
                        //         z dither in 8-bit LSB, w surface opacity

// --- surface pattern --------------------------------------------------------
uniform vec4 uPattern;  // 53..56  x kind: 0 none, 1 scanline, 2 dialGlow
                        //         y period in DEVICE px
                        //         z primary strength
                        //         w secondary: scanline = aperture-grille
                        //           strength, dialGlow = falloff exponent
uniform vec3 uPatternColor; // 57..59  dialGlow emissive tint (sRGB)

// --- sampled micro-normal grain ---------------------------------------------
uniform vec4 uGrainTex; // 60..63  x strength (normal tilt), y tile W dev px,
                        //         z tile H dev px, w mean of the tile's
                        //           distribution (subtracted so the tilt is
                        //           signed)
// The hairline source. A DEVICE-PIXEL texture, not an analytic field,
// because analytic noise has a ~2.5 logical px Nyquist floor and real brush
// is finer than that. Sampled in CANVAS space so the scratches continue
// across neighbouring surfaces like parts cut from one sheet, and applied
// as a NORMAL perturbation - never a luminance add - so every scratch is
// lit by the same specular, environment and key terms as the face it is
// cut into: blazing inside the sheen band, gone in shadow. Adding the
// scratches as luminance was the "painted-on lines" defect.
//
// sampler2D, not `uniform shader`: the .frag is GLSL, and impellerc maps
// sampler2D onto the runtime effect's child slot that setImageSampler
// fills. Sampling coordinates are NORMALISED, hence the divide by the tile
// size carried in uGrainTex.yz.
uniform sampler2D uGrainImg;

out vec4 fragColor;

// --- colour space -----------------------------------------------------------
// Every light term below is LINEAR. Skia composites this window in 8-bit sRGB,
// so decode on the way in and encode once on the way out. Mixing lit colours in
// gamma space is a large part of why a hand-tuned gradient reads as plastic:
// the midpoint of an sRGB interpolation is dragged toward grey.
// Cheap polynomial fits - pow(x, 2.2) six times a pixel is real money.
vec3 toLinear(vec3 c) {
  return c * (c * (c * 0.305306011 + 0.682171111) + 0.012522878);
}
vec3 toSRGB(vec3 c) {
  vec3 s = sqrt(max(c, vec3(0.0)));
  vec3 t = sqrt(s);
  vec3 u = sqrt(t);
  return 0.585122381 * s + 0.783140355 * t - 0.368262736 * u;
}

// --- signed distance --------------------------------------------------------
// Inigo Quilez, 2D distance functions. MIT ("all technical code snippets you
// will find are under the MIT license"). p is relative to the box centre.
float sdRoundBox(vec2 p, vec2 b, float r) {
  vec2 q = abs(p) - b + r;
  return min(max(q.x, q.y), 0.0) + length(max(q, vec2(0.0))) - r;
}

// Its exact gradient, in closed form. Unit length everywhere the field is
// differentiable. This is what replaces fwidth: we do not sample the field
// twice and subtract, we differentiate it once by hand.
vec2 sdRoundBoxGrad(vec2 p, vec2 b, float r) {
  vec2 q = abs(p) - b + r;
  vec2 qp = max(q, vec2(0.0));
  float L = length(qp);
  vec2 g = (L > 1e-6) ? qp / L : ((q.x > q.y) ? vec2(1.0, 0.0) : vec2(0.0, 1.0));
  return g * vec2((p.x < 0.0) ? -1.0 : 1.0, (p.y < 0.0) ? -1.0 : 1.0);
}

// --- noise ------------------------------------------------------------------
// sin-free hash: sin() is an SFU-rate transcendental and this is called four
// times per noise sample.
float hash21(vec2 p) {
  vec3 q = fract(vec3(p.x, p.y, p.x) * vec3(0.1031, 0.1030, 0.0973));
  q += dot(q, vec3(q.y, q.z, q.x) + 33.33);
  return fract((q.x + q.y) * q.z);
}

// Value noise with ANALYTIC derivatives (Quilez, value noise derivatives).
// Returning the derivative is the whole point: a value-only noise can only
// tint the surface, and a 2-level tint is invisible. The derivative TILTS THE
// NORMAL, so the specular amplifies it - you get more visible detail from less
// amplitude, and the grain vanishes in shadow and sparkles in the highlight,
// which is what real brushed metal does.
vec3 noised(vec2 x) {
  vec2 i = floor(x);
  vec2 f = x - i;
  vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
  vec2 du = 30.0 * f * f * (f * (f - 2.0) + 1.0);
  float a = hash21(i);
  float b = hash21(i + vec2(1.0, 0.0));
  float c = hash21(i + vec2(0.0, 1.0));
  float e = hash21(i + vec2(1.0, 1.0));
  float k1 = b - a;
  float k2 = c - a;
  float k3 = a - b - c + e;
  return vec3(a + k1 * u.x + k2 * u.y + k3 * u.x * u.y,
              du.x * (k1 + k3 * u.y),
              du.y * (k2 + k3 * u.x));
}

// --- environment ------------------------------------------------------------
// A studio in five numbers: ground below, sky above, a SHARP horizon, a
// directional soft-box, and roughness that widens both.
//
// The sharp horizon is the point. A real reflection puts near-black
// immediately next to near-white, and it is that step sweeping across a curved
// chamfer that the eye reads as "shiny". A soft 6% white wash has neither the
// contrast nor the step, which is why no amount of tuning its stops will ever
// make it read as a reflection.
vec3 environment(vec3 R, float rough, vec3 sky, vec3 gnd) {
  float t = clamp(R.y, -1.0, 1.0);
  // Roughness widens the horizon exactly as a blurrier reflection would - a
  // free stand-in for a roughness mip chain.
  //
  // uEnv.y wants to be generous, NOT razor sharp, and that is worth stating
  // because the instinct is the opposite. A hard step is right on a chamfer,
  // where the normal swings 90 degrees inside a few pixels and the step reads
  // as a crisp reflection. Swept across a broad bowed FACE, whose normal
  // crosses R.y = 0 exactly once, the same step paints a dead-straight seam
  // across the middle of every panel - an artifact, not a reflection. The
  // chamfer still gets its contrast from the sheer range of normals it covers.
  float soft = clamp(uEnv.y + rough * rough * 1.1, 0.012, 2.0);
  vec3 col = mix(gnd, sky, smoothstep(-soft, soft, t));

  // A DIRECTIONAL soft-box, not a horizontal band. Without it every chamfer
  // glows evenly all the way round, which is the loudest fake-bevel tell.
  float sb = pow(max(dot(R, uL), 0.0), mix(200.0, 5.0, rough));
  col += sky * sb * uEnv.z;

  // FLOOR BOUNCE. The term UI designers always omit, and one of the two that
  // make a surface read as "in a room" rather than "on paper" (the other is
  // the sharp horizon above). Light falling on the floor scatters back up, so
  // a down-facing normal is never as dark as the ground it reflects. Without
  // it the bottom lip of every control goes black and the control reads as a
  // sticker lying on the background rather than an object standing on it.
  col += sky * pow(max(-t, 0.0), 2.5) * 0.34;
  return col;
}

// 0.5*(1 - erf(x)) without erf and without tanh (tanh is ES3-gated).
// x*inversesqrt(1+x*x) tracks a Gaussian CDF closely enough for a UI shadow,
// and gives a real penumbra instead of MaskFilter.blur's offscreen pass.
float softStep(float x) { return 0.5 - 0.5 * x * inversesqrt(1.0 + x * x); }

void main() {
  vec2 fc = FlutterFragCoord().xy;

  // Flutter local space is y-DOWN. Flip once, here, and shade in a y-UP frame
  // so every normal, light and reflection below reads the way it does on
  // paper. Nothing downstream has to remember the flip.
  vec2 centre = uDraw * 0.5;
  vec2 p = vec2(fc.x - centre.x, centre.y - fc.y);
  vec2 b = max(uShape * 0.5, vec2(0.5));
  float rr = clamp(uPadRad.y, 0.0, min(b.x, b.y));

  float d = sdRoundBox(p, b, rr);

  // --- coverage: analytic, exact, derivative-free ---------------------------
  float px = max(uBevel.y, 1e-4);
  float cov = clamp(0.5 - d / px, 0.0, 1.0);

  vec3 sky = toLinear(uSky);
  vec3 gnd = toLinear(uGnd);

  // --- outer shadow and CONTACT OCCLUSION -----------------------------------
  // These are two different phenomena that UI code habitually collapses into
  // one blurred blob. The cast shadow is directional and offset along -L. The
  // contact term is NON-directional, has ZERO offset, hugs the silhouette and
  // is much darker. Its absence is exactly why UI elements float.
  float dCast = sdRoundBox(p - uShadow.xy, b, rr);
  float castS = softStep(1.9 * dCast / max(uShadow.z, 0.25)) * uShadow.w;
  float ao = softStep(2.6 * d / max(uOcc.y, 0.2)) * uOcc.x;
  float sh = clamp(castS + ao, 0.0, 1.0) * (1.0 - cov);
  // A shadow is the ambient environment MINUS the blocked portion, so it is
  // tinted toward the environment, never neutral black. Black-at-low-alpha
  // desaturates whatever is behind it and reads as smudge or dirt.
  vec3 shCol = clamp(toSRGB(gnd * 0.35), 0.0, 1.0);

  if (cov <= 0.0) {
    float a0 = clamp(sh, 0.0, 1.0);
    fragColor = vec4(shCol * a0, a0);
    return;
  }

  // --- the chamfer ----------------------------------------------------------
  // A one-pixel ring cannot resolve a specular transition; a real chamfer
  // swings from near-white to near-black across the band, and you need 2-4px
  // to show that. Never thinner than 1.5 device px or it aliases into a
  // shimmering wire.
  float w = max(uBevel.x, 1.5 * px);
  vec2 g2 = sdRoundBoxGrad(p, b, rr);

  // Exact quarter-round profile. t = 0 at the silhouette, 1 at the flat face.
  //   N = normalize(vec3(g*(1-t), sqrt(t*(2-t))))
  // which is unit by construction: (1-t)^2 + 2t - t^2 == 1. At t=0 the normal
  // lies flat in the screen plane, which is precisely where Fresnel must reach
  // 1; at t=1 it is (0,0,1). No sqrt of a negative, no division.
  float t = clamp(-d / w, 0.0, 1.0);
  float bend = mix(1.0, -1.0, clamp(uKey.w, 0.0, 1.0)); // raised <-> recessed

  // BULLNOSE: the exact quarter-round. Unit by construction, and correct for a
  // moulded or tumbled edge.
  float cosB = 1.0 - t;
  float sinB = sqrt(max(t * (2.0 - t), 1e-5));

  // FLAT MACHINED LAND: a constant-angle face with a crisp arris at each end.
  //
  // This exists because a bullnose is the wrong shape for most of this app. A
  // quarter-round spends almost none of its width at a grazing angle - one
  // pixel in from the silhouette of a 3.5px fillet the normal has already
  // rolled up to n.z = 0.70 - so the bright lip is a sub-pixel sliver and the
  // edge reads as a soft smudge. A real 19-inch faceplate is CNC-chamfered:
  // every edge is a flat land held at one angle across its whole width, which
  // is why a machined edge catches a single even line of light. Holding the
  // angle constant across the band is what makes the edge read as machined
  // rather than moulded, and the two arrises are what make it read as cut.
  float landT = 0.5 * smoothstep(0.0, 0.14, t) + 0.5 * smoothstep(0.86, 1.0, t);
  float phi = landT * 1.5707963267948966 * (uBevel.w * 2.0);
  float cosF = cos(phi);
  float sinF = sin(phi);

  float prof = clamp(uBevel.z, 0.0, 1.0);
  vec2 nxy = g2 * (bend * mix(cosB, cosF, prof));
  float nz = mix(sinB, sinF, prof);

  // A shallow bow across the face. Rolled sheet is never dead flat, so the
  // highlight TRAVELS across it. Without this the interior normal is constant,
  // a constant normal dotted with a fixed light is a constant, and the face is
  // one flat colour - which is exactly what the gradient already did.
  nxy += (p / b) * uMat.w * bend;

  vec3 n = normalize(vec3(nxy, nz));

  // --- anisotropic brush grain ----------------------------------------------
  float ca = cos(uGrain.z);
  float sa = sin(uGrain.z);
  vec2 q = vec2(ca * p.x + sa * p.y, -sa * p.x + ca * p.y);
  // Cells per pixel. Along the brush the wavelength is ~120x the across-grain
  // one, which is what makes a streak a streak rather than a blob.
  float acr = max(uGrain.y, 1.2);
  vec2 sc = vec2(1.0 / (acr * 120.0), 1.0 / acr);
  vec3 n1 = noised(q * sc);
  // A second, finer octave. One octave of value noise at the coarsest
  // wavelength the display can resolve reads as horizontal BANDING - regular
  // stripes, not brush. Two octaves at 2.7x break up that regularity.
  vec3 n2 = noised(q * sc * 2.7 + vec2(19.3, 7.1));

  // Analytic LOD, PER OCTAVE. We know the pixel footprint exactly, so we
  // know how many noise cells a pixel spans and can fade each octave out
  // before it aliases - the job fwidth would normally do, done without
  // fwidth. Half a cell per pixel IS the Nyquist limit, so the fade has to
  // begin below it.
  //
  // Per octave, and this is a bug fix with a release of history behind it:
  // v1.8.0 derived ONE fade from the finer octave and multiplied the whole
  // grain by it, which erased BOTH octaves the moment the fine one aliased.
  // Every shipped material's grainAcross sat in exactly that band, so at
  // 100%/125%/150% Windows scaling the grain amplitude was mathematically
  // zero - brushed aluminium that never showed its brush on any ordinary
  // display, and one root of "the materials all look like tints".
  float aFine = 1.0 - smoothstep(0.24, 0.50, (sc.y * 2.7) * px);
  float aCoarse = 1.0 - smoothstep(0.24, 0.50, sc.y * px);
  // Chain rule through the second octave's frequency, or the tilt is wrong.
  vec3 nn = vec3(n1.x * aCoarse + 0.5 * n2.x * aFine,
                 n1.y * aCoarse + 0.5 * 2.7 * n2.y * aFine,
                 n1.z * aCoarse + 0.5 * 2.7 * n2.z * aFine) * (1.0 / 1.5);
  float amp = uGrain.x;

  vec3 gdir = vec3(ca, sa, 0.0);
  vec3 T = gdir - n * dot(n, gdir);
  T = (dot(T, T) > 1e-8) ? normalize(T) : vec3(1.0, 0.0, 0.0);
  vec3 B = cross(n, T);
  n = normalize(n - T * (nn.y * sc.x * amp) - B * (nn.z * sc.y * amp));

  // The sampled hairlines. fc is canvas-local; dividing by px converts to
  // device pixels, so one tile row is one physical scratch at every window
  // scale. The tilt is across-grain only (B), exactly like a real groove:
  // its walls face up-slope and down-slope, never along the cut.
  if (uGrainTex.x > 0.001) {
    vec2 gq = vec2(ca * fc.x + sa * fc.y, -sa * fc.x + ca * fc.y) / px;
    vec2 tcoord = mod(gq, uGrainTex.yz) / uGrainTex.yz;
    float scratch = texture(uGrainImg, tcoord).r - uGrainTex.w;
    n = normalize(n - B * (scratch * uGrainTex.x));
  }

  // --- shading --------------------------------------------------------------
  vec3 V = vec3(0.0, 0.0, 1.0);          // orthographic UI: V is constant
  vec3 H = normalize(uL + V);
  float ndl = dot(n, uL);
  float ndv = max(n.z, 1e-4);
  float ndh = max(dot(n, H), 0.0);

  float rough = clamp(uMat.x, 0.045, 1.0);
  float metal = clamp(uMat.y, 0.0, 1.0);
  float a2 = rough * rough;

  // GGX / Trowbridge-Reitz. Its longer tail is what separates metal from
  // plastic; Blinn-Phong's highlight has no tail and no Fresnel, which is why
  // every Blinn-Phong surface reads as plastic.
  float dn = ndh * ndh * (a2 * a2 - 1.0) + 1.0;
  float D = (a2 * a2) / (3.14159265 * dn * dn + 1e-6);
  float k = a2 * 0.5;
  float gv = ndv * (1.0 - k) + k;
  float gl = max(ndl, 0.0) * (1.0 - k) + k;
  float Vis = 0.25 / max(gv * gl, 1e-4);

  // Anisotropy: the highlight elongates PERPENDICULAR to the brush lines,
  // which is the brushed-metal read. Kajiya-Kay's term, one dot and one pow.
  float aniso = clamp(uMat.z, 0.0, 0.98);
  float toh = dot(T, H);
  float stretch = mix(1.0, pow(max(1.0 - toh * toh, 0.0), 8.0), aniso);

  // Schlick. On a chamfer this is what lights the lip - the term a 1px bevel
  // ring is a crude stand-in for. At grazing incidence ALL materials approach
  // 100% reflectance regardless of F0, so a flat 6% white wash is roughly 2x
  // too bright in the middle and about 10x too dim at the edge.
  vec3 F0 = mix(vec3(0.04), toLinear(uF0), metal);
  vec3 F = F0 + (1.0 - F0) * pow(1.0 - max(dot(H, V), 0.0), 5.0);

  vec3 albedo = toLinear(uAlbedo);

  // SCANLINE (pattern kind 1): a luminance modulation of the surface itself,
  // not a lighting term - a CRT's raster darkens the phosphor gaps whatever
  // the room does. Multiplicative and applied to the albedo, so text drawn
  // over the screen keeps its contrast: the modulation can only DARKEN the
  // ground, never lift it toward a light ink. The period arrives in device
  // pixels so the raster stays crisp at every window scale; px converts.
  if (uPattern.x > 0.5 && uPattern.x < 1.5) {
    float rowPhase = 6.2831853 * p.y / max(uPattern.y * px, 2.0 * px);
    float rows = 0.5 + 0.5 * cos(rowPhase);
    float grille = 0.0;
    if (uPattern.w > 0.001) {
      // The aperture grille: a finer vertical mask at 1/3 the row strength,
      // which is what separates "CRT" from "venetian blind".
      float colPhase = 6.2831853 * p.x / max(uPattern.y * px, 2.0 * px);
      grille = uPattern.w * (0.5 + 0.5 * cos(colPhase));
    }
    albedo *= 1.0 - uPattern.z * rows - grille;
  }

  vec3 kd = albedo * (1.0 - metal);   // metals have no diffuse term at all

  // Wrapped Lambert: a hard terminator across a 3px chamfer looks like a
  // die-cut, not a moulding.
  float diff = max((ndl + 0.25) / 1.25, 0.0);

  vec3 amb = mix(gnd, sky, 0.5 + 0.5 * n.y) * uKey.y;

  // Rim, gated to the OUTER half of the chamfer. A rim that reaches the flat
  // land reads as a glow rather than a lit edge.
  //
  // The exponent is 2, not the 4 or 5 a Fresnel curve wants, and that is
  // deliberate. The quarter-round rolls n.z from 0 to 1 across the chamfer, so
  // a 5th-power term is numerically dead more than one pixel in from the
  // silhouette: on a 3.5px chamfer it lights a sub-pixel sliver nobody can
  // see, and the bottom edge stays darker than the face - measurably the
  // opposite of what a real object does. The steep curve is already carried
  // where it belongs, in F applied to the environment term; this one is the
  // visible band, so it is shaped to span the chamfer.
  float rimGate = 1.0 - smoothstep(0.35, 0.95, t);
  float rim = pow(1.0 - ndv, 2.0) * rimGate * uEnv.w;

  vec3 R = reflect(-V, n);
  vec3 env = environment(R, rough, sky, gnd) * uEnv.x;
  // A grazing chamfer reflects the HORIZON, and a sharp horizon is bright.
  // Without this nudge the lower chamfer samples pure ground and goes black,
  // which is the "floating sticker" look: real objects pick up the floor-to-
  // wall transition along their bottom edge.
  env += mix(gnd, sky, 0.5) * uEnv.x * rimGate * 0.45;


  // Cavity occlusion. The wall of a well sees far less of the room than the
  // crown of a boss does. Gating only the DIFFUSE is why a sunken panel still
  // reads as raised - the reflection fills the well straight back in. So this
  // multiplies the specular and the environment too.
  float rec = clamp(uKey.w, 0.0, 1.0);
  float cavity = mix(1.0, 1.0 - 0.78 * rimGate, rec);

  // Inner shadow, from the same SDF - no Path.combine, no MaskFilter.blur,
  // no clipPath, no offscreen render target.
  float dIn = sdRoundBox(p - uShadow.xy * 0.5, b, rr);
  float inS = 1.0 - softStep(1.9 * dIn / max(uOcc.z, 0.25));
  float occ = mix(1.0, 1.0 - uOcc.w * inS, rec);

  vec3 col = kd * (uKey.x * diff + amb * cavity) * occ;
  col += F * (D * Vis * stretch * max(ndl, 0.0) * uKey.x) * occ;
  col += F * env * occ * cavity;
  col += sky * (pow(ndh, 2.5) * uKey.z) * occ;
  col += sky * rim;

  // DIAL GLOW (pattern kind 2): the lamp behind a receiver's dial window.
  // Emissive - added AFTER the surface shading, because backlight is not
  // reflection - and strongest at the top of the pane, falling away with
  // the secondary exponent. Occlusion still applies: a recessed pane's
  // walls shade its own lamp.
  if (uPattern.x > 1.5 && uPattern.x < 2.5) {
    float gT = clamp(0.5 + 0.5 * (p.y / b.y), 0.0, 1.0);
    float glow = pow(gT, max(uPattern.w, 0.25));
    col += toLinear(uPatternColor) * (uPattern.z * glow) * occ;
  }

  // --- tone map -------------------------------------------------------------
  // NOT optional decoration. An energy-normalised GGX lobe peaks far above 1.0
  // in linear radiance (measured above 20x on a brushed-aluminium preset), and
  // hard-clipping that paints a flat white slab across the whole streak -
  // which is precisely what fake looks like. A shoulder keeps a streak a
  // streak.
  col *= uTone.x;
  float wp = max(uTone.y * uTone.y, 1e-3);
  col = (col * (1.0 + col / wp)) / (1.0 + col);

  float surfA = cov * clamp(uTone.w, 0.0, 1.0);
  vec3 surfC = clamp(toSRGB(col), 0.0, 1.0);

  vec4 outPre = vec4(surfC * surfA, surfA)
              + vec4(shCol * sh, sh) * (1.0 - surfA);

  // Triangular-PDF dither at +/- 1 LSB. An 8-bit destination cannot hold a
  // smooth low-contrast gradient: a 6-level ramp across 256px renders as 7
  // hard bands. This is what the old 2-level texture layer was accidentally
  // doing, and it is cheaper and more reliable done here.
  float r1 = hash21(fc + uGrain.w);
  float r2 = hash21(vec2(fc.y, fc.x) + uGrain.w * 1.7 + 11.3);
  outPre.rgb += (r1 + r2 - 1.0) * (uTone.z / 255.0) * outPre.a;

  // Skia clamps to a valid premultiplied colour; do it here so the clamp can
  // never silently shift hue.
  outPre.a = clamp(outPre.a, 0.0, 1.0);
  outPre.rgb = clamp(outPre.rgb, vec3(0.0), vec3(outPre.a));
  fragColor = outPre;
}
