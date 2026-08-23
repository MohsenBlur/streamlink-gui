#version 460 core
#include <flutter/runtime_effect.glsl>

// A lit surface, rather than a picture of one.
//
// Everything the Canvas engine did was a stack of gradients: a fill that
// darkens downward, a white wash at the top, a one-pixel ring. A gradient can
// imitate a lit surface from one angle and never behaves like one - the
// highlight does not travel, the terminator has no shape, the edge does not
// brighten at glancing angles, and nothing reflects anything. That is what
// "very fake" means, precisely.
//
// This computes a normal per pixel and lights it. The shape comes from a
// signed distance field, the edge is a real chamfer that the normal rolls
// over, and the surface has a specular response, an environment to reflect,
// a Fresnel rim and an anisotropic grain that stretches the highlight the way
// brushed metal does.

uniform vec2  uSize;      // 0,1   logical size of the box
uniform float uRadius;    // 2     corner radius
uniform float uBevel;     // 3     chamfer width, in px; 0 = hard edge
uniform vec3  uBase;      // 4,5,6 albedo
uniform vec3  uSpec;      // 7,8,9 specular tint (white-ish for dielectrics)
uniform float uRough;     // 10    0 = mirror, 1 = matte
uniform float uLightAz;   // 11    radians, CCW from +x, naming the SOURCE
uniform float uLightEl;   // 12    radians above the surface plane
uniform float uAmbient;   // 13    0..1 fraction of albedo visible unlit
uniform vec3  uEnvTop;    // 14,15,16  what a surface facing up reflects
uniform vec3  uEnvBot;    // 17,18,19  what a surface facing down reflects
uniform float uEnvAmount; // 20    reflection strength
uniform float uGrain;     // 21    anisotropic normal perturbation
uniform float uGrainScale;// 22    streak stretch along x
uniform float uInset;     // 23    0 = proud, 1 = recessed
uniform float uSeed;      // 24
uniform float uPx;        // 25    one device pixel, in shader units
uniform float uBow;       // 26    shallow convexity across the face
uniform float uSheen;     // 27    broad area-light lobe

out vec4 fragColor;

// Inigo Quilez, "distance functions" (MIT). The workhorse of 2D SDF UI.
float sdRoundBox(vec2 p, vec2 b, float r) {
    vec2 q = abs(p) - b + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

// The gradient of the above, in closed form.
//
// Flutter's SkSL has no derivative instructions - `fwidth`, `dFdx` and `dFdy`
// are all rejected by the compiler ("no match for fwidth(float)"), which is
// the first thing that bites when porting a Shadertoy-shaped shader. That is
// no loss here: differentiating a round box by hand is four lines and gives
// the exact normal instead of a two-pixel finite difference of it.
//
// Outside the corner quadrant the box is flat, so the gradient is one axis;
// inside it, the distance is to the corner centre, so the gradient points
// away from it.
vec2 sdRoundBoxGrad(vec2 p, vec2 b, float r) {
    vec2 sgn = sign(p);
    vec2 q = abs(p) - b + r;
    if (q.x > 0.0 && q.y > 0.0) {
        return sgn * normalize(q);
    }
    return sgn * (q.x > q.y ? vec2(1.0, 0.0) : vec2(0.0, 1.0));
}

float hash21(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

float vnoise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + vec2(1.0, 0.0));
    float c = hash21(i + vec2(0.0, 1.0));
    float d = hash21(i + vec2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void main() {
    vec2 fc = FlutterFragCoord().xy;
    vec2 halfSize = uSize * 0.5;
    vec2 p = fc - halfSize;

    float d = sdRoundBox(p, halfSize, uRadius);

    // Shape antialiasing from the SDF itself: one device pixel of coverage,
    // correct on any radius. The pixel size arrives as a uniform because SkSL
    // cannot ask for it.
    float aa = max(uPx, 1e-5);
    float alpha = 1.0 - smoothstep(-aa, aa, d);
    if (alpha <= 0.0) {
        fragColor = vec4(0.0);
        return;
    }

    // The outward direction in the plane, analytically.
    vec2 outward = sdRoundBoxGrad(p, halfSize, uRadius);

    // The chamfer. `t` runs 0 in the flat interior to 1 at the outline, and
    // the normal rolls a quarter turn over it. This is the whole reason the
    // edge reads as a machined edge rather than a drawn line: a 1px ring is a
    // stroke, a chamfer is geometry that catches light on one side and loses
    // it on the other.
    float bevel = max(uBevel, 0.001);
    float t = clamp((d + bevel) / bevel, 0.0, 1.0);
    float tilt = sin(t * 1.5707963);

    // Recessed surfaces roll the other way, so the lit side swaps sides. That
    // is what makes a well look pressed in rather than raised.
    float sgnI = mix(1.0, -1.0, uInset);
    vec2 nxy = outward * tilt * sgnI;

    // A shallow bow across the face.
    //
    // The single largest "real" cue, and the one a flat normal cannot give at
    // any amount of shading: rolled sheet metal is never dead flat, so the
    // highlight TRAVELS as your eye moves across it and the face has a soft
    // terminator instead of one constant value. Without this the interior is
    // one colour, because a flat normal dotted with a fixed light is a
    // constant - which is exactly what a gradient already does, and exactly
    // what looked fake.
    //
    // Fractions of a degree of tilt; it reads as light, not as curvature.
    vec2 uvc = p / halfSize;
    nxy += uvc * uBow * mix(1.0, -1.0, uInset);

    vec3 n = normalize(vec3(nxy, sqrt(max(1.0 - min(dot(nxy, nxy), 0.999), 1e-5))));

    // Anisotropic grain: streaks along x, so the normal wobbles in y. A
    // brushed surface scatters light across the brush direction and reflects
    // it along the direction, which is why its highlight is a smeared band
    // rather than a dot.
    if (uGrain > 0.0) {
        float g = vnoise(vec2(fc.x / max(uGrainScale, 0.01), fc.y * 1.7)
                         + uSeed);
        float g2 = vnoise(vec2(fc.x / max(uGrainScale * 6.0, 0.01),
                               fc.y * 0.35) + uSeed * 1.7);
        float streak = (g - 0.5) * 0.75 + (g2 - 0.5) * 0.25;
        n = normalize(n + vec3(0.0, streak * uGrain, 0.0));
    }

    // Screen space has y growing downward; the light's elevation is out of the
    // screen toward the viewer.
    vec3 L = normalize(vec3(cos(uLightAz) * cos(uLightEl),
                            -sin(uLightAz) * cos(uLightEl),
                            sin(uLightEl)));
    vec3 V = vec3(0.0, 0.0, 1.0);
    vec3 H = normalize(L + V);

    float ndl = max(dot(n, L), 0.0);
    float ndh = max(dot(n, H), 0.0);
    float ndv = max(dot(n, V), 0.0);

    // Blinn-Phong. Cheap, and at UI scale indistinguishable from GGX once the
    // exponent is mapped from roughness the same way.
    float shininess = mix(400.0, 6.0, clamp(uRough, 0.0, 1.0));
    float spec = pow(ndh, shininess) * (1.0 - uRough * 0.65);

    // A second, very broad lobe. Real rooms light objects with panels and
    // windows, not points; the wide soft sheen is what separates a photograph
    // from a render with one light in it.
    float sheen = pow(ndh, 2.5) * uSheen;

    // An analytic environment: sky above, floor below, sampled by where the
    // surface points. No HDRI, no texture, and it gives the one cue a gradient
    // cannot fake - the reflection moves when the surface curves.
    vec3 r = reflect(-V, n);
    float up = clamp(-r.y * 0.5 + 0.5, 0.0, 1.0);
    vec3 env = mix(uEnvBot, uEnvTop, up);

    // Schlick. Edges brighten at glancing angles; this is most of why a real
    // object's silhouette is bright even when its face is dark.
    float fres = 0.04 + 0.96 * pow(1.0 - ndv, 5.0);

    vec3 col = uBase * (uAmbient + (1.0 - uAmbient) * ndl);
    col += env * fres * uEnvAmount;
    col += uSpec * (spec + sheen);

    // Contact darkening in the chamfer's shadowed half. A real edge occludes
    // itself; without this the chamfer reads as a bright outline all the way
    // round.
    float occl = smoothstep(0.0, 1.0, t) * (1.0 - ndl);
    col *= 1.0 - occl * 0.35;

    fragColor = vec4(clamp(col, 0.0, 1.0) * alpha, alpha);
}
