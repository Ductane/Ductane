//
//  WaymarkScanShaders.metal
//  Ductane
//
//  A `WaymarkScan`'s ring, outlines and icons, for `WaymarkScanRenderer`. Compiled at runtime from source when the
//  package was built by `swift build`, which produces no metallib — see `ShaderLibrary`.
//

#include <metal_stdlib>
using namespace metal;

/// The frame, as `WaymarkScanRenderer.Frame` writes it.
struct DUScanFrame {
    float4x4 viewProjection;
    float4 camera;      // xyz where the view is; w the time, seconds
    float4 color;       // rgb the ring's and outlines' colour, linear, times intensity and brightness; a the ring's opacity
    float4 ring;        // x half its width, meters; y its glow reach, meters; z the curtain's height; w how many points
    float4 screen;      // xy the view's size in pixels; z outline width, pixels; w icon size, pixels
    float4 origin;      // xyz where the scan set out; w how far the ring has reached
};

/// A point of the ring: where, and its angle round the origin.
struct DUScanPoint {
    float4 position;
};

/// One found thing's icon, as `WaymarkScanRenderer.Icon` writes it.
struct DUScanIcon {
    float4 position;    // xyz where it floats; w its opacity
    float4 color;       // rgb linear, times brightness; w which icon
    float4 label;       // x meters away (negative: no label)
};

/// What one outlined part is drawn with into the mask.
struct DUScanPart {
    float4x4 modelViewProjection;
    float4 shape;       // x the vertex stride in floats; y its opacity
};

// MARK: The mask: every outlined thing's shape, its opacity where it covers

struct DUScanMaskOut {
    float4 position [[position]];
    float opacity;
};

vertex DUScanMaskOut duScanMaskVertex(uint vertexID [[vertex_id]],
                                      const device float *vertices [[buffer(0)]],
                                      constant DUScanPart &part [[buffer(1)]])
{
    const uint stride = uint(part.shape.x + 0.5);
    const device float *v = vertices + vertexID * stride;
    DUScanMaskOut out;
    out.position = part.modelViewProjection * float4(v[0], v[1], v[2], 1.0);
    out.opacity = part.shape.y;
    return out;
}

fragment float4 duScanMaskFragment(DUScanMaskOut in [[stage_in]])
{
    return float4(in.opacity);
}

// MARK: The ring: a band over the ground, and a curtain above it seen through walls

struct DUScanRingOut {
    float4 position [[position]];
    float across;       // −1…1 across the band; the curtain: 0 at the ground to 1 at its top
    float isCurtain;
    float distance;
};

static DUScanRingOut duScanRing(uint vertexID, bool curtain, const device DUScanPoint *points,
                                constant DUScanFrame &frame)
{
    const uint count = uint(frame.ring.w + 0.5);
    const uint i = (vertexID / 2) % count;
    const float side = (vertexID % 2) == 0 ? -1.0 : 1.0;
    const float3 p = points[i].position.xyz;
    float3 outward = p - frame.origin.xyz;
    outward.y = 0;
    outward = length(outward) > 1e-4 ? normalize(outward) : float3(1, 0, 0);
    DUScanRingOut out;
    out.distance = length(frame.camera.xyz - p);
    if (!curtain) {
        // The band, lying over the ground, lifted a little so the ground between its points does not cover it.
        const float spread = frame.ring.x + frame.ring.y;
        out.position = frame.viewProjection * float4(p + outward * side * spread + float3(0, 0.25, 0), 1.0);
        out.across = side;
        out.isCurtain = 0;
    } else {
        // The curtain: from the ground up, fading as it rises.
        const float up = side < 0 ? 0.0 : 1.0;
        out.position = frame.viewProjection * float4(p + float3(0, up * frame.ring.z, 0), 1.0);
        out.across = up;
        out.isCurtain = 1;
    }
    return out;
}

vertex DUScanRingOut duScanRingVertex(uint vertexID [[vertex_id]], const device DUScanPoint *points [[buffer(0)]],
                                      constant DUScanFrame &frame [[buffer(1)]])
{
    return duScanRing(vertexID, false, points, frame);
}

vertex DUScanRingOut duScanCurtainVertex(uint vertexID [[vertex_id]], const device DUScanPoint *points [[buffer(0)]],
                                         constant DUScanFrame &frame [[buffer(1)]])
{
    return duScanRing(vertexID, true, points, frame);
}

fragment float4 duScanRingFragment(DUScanRingOut in [[stage_in]], constant DUScanFrame &frame [[buffer(1)]])
{
    const float opacity = frame.color.a;
    if (in.isCurtain > 0.5) {
        // Faint, seen through whatever stands between: where the wave is, not a wall.
        const float rise = pow(1.0 - saturate(in.across), 2.0) * smoothstep(0.0, 0.08, in.across);
        const float a = rise * 0.15 * opacity;
        return float4(frame.color.rgb * a, a * 0.25);
    }
    const float halfWidth = frame.ring.x, reach = frame.ring.y;
    const float d = abs(in.across) * (halfWidth + reach) - halfWidth;
    const float aa = max(fwidth(d), 1e-3);
    const float core = 1.0 - smoothstep(-aa, aa, d);
    const float glow = reach > 1e-4 ? pow(saturate(1.0 - max(d, 0.0) / reach), 2.5) * (1.0 - core) : 0.0;
    // Bright at its leading edge, softer behind it.
    const float leading = mix(0.65, 1.0, saturate(in.across * 0.5 + 0.5));
    const float a = (core + glow * 0.6) * leading * opacity * smoothstep(1.5, 4.0, in.distance);
    return float4(frame.color.rgb * a, saturate((core * 0.7 + glow * 0.2) * leading * opacity));
}

// MARK: Outlines, from the mask: a band round each shape, and a faint fill inside it

struct DUScanScreenOut {
    float4 position [[position]];
};

vertex DUScanScreenOut duScanOutlineVertex(uint vertexID [[vertex_id]])
{
    const float2 corners[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    DUScanScreenOut out;
    out.position = float4(corners[vertexID], 0, 1);
    return out;
}

fragment float4 duScanOutlineFragment(DUScanScreenOut in [[stage_in]],
                                      constant DUScanFrame &frame [[buffer(1)]],
                                      texture2d<float> mask [[texture(0)]])
{
    constexpr sampler near(filter::linear, address::clamp_to_edge);
    // The mask is the scene's own size, so a pixel here is a texel there.
    const float2 size = float2(mask.get_width(), mask.get_height());
    const float2 uv = in.position.xy / size;
    const float here = mask.sample(near, uv).r;
    // The most of any shape within the outline's width: two rings of samples.
    const float width = frame.screen.z;
    float around = 0.0;
    for (int k = 0; k < 12; k++) {
        const float a = float(k) * (M_PI_F / 6.0);
        const float2 dir = float2(cos(a), sin(a));
        around = max(around, mask.sample(near, uv + dir * width / size).r);
        around = max(around, mask.sample(near, uv + dir * width * 0.5 / size).r);
    }
    const float band = max(around - here, 0.0);
    // Inside, the faintest hint of the colour — enough to read a shape seen through a wall, never enough to wash out
    // one seen plainly: the colour is HDR, and in a dark scene's exposure a fill of a few percent tinted a figure whole.
    const float fill = here * 0.01;
    if (band + fill < 1e-3) discard_fragment();
    return float4(frame.color.rgb * (band + fill), saturate(band * 0.85));
}

// MARK: Icons and their distances

/// Signed distance to a box of half-size `b` with corners rounded by `r`.
static float duScanBox(float2 p, float2 b, float r)
{
    r = min(r, min(b.x, b.y));
    const float2 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

static float duScanSegment(float2 p, float2 a, float2 b)
{
    const float2 pa = p - a, ba = b - a;
    const float h = saturate(dot(pa, ba) / dot(ba, ba));
    return length(pa - ba * h);
}

/// Signed distance to a five-pointed star (Inigo Quilez's).
static float duScanStar(float2 p, float r, float rf)
{
    const float2 k1 = float2(0.809016994375, -0.587785252292);
    const float2 k2 = float2(-k1.x, k1.y);
    p.x = abs(p.x);
    p -= 2.0 * max(dot(k1, p), 0.0) * k1;
    p -= 2.0 * max(dot(k2, p), 0.0) * k2;
    p.x = abs(p.x);
    p.y -= r;
    const float2 ba = rf * float2(-k1.y, k1.x) - float2(0, 1);
    const float h = clamp(dot(p, ba) / dot(ba, ba), 0.0, r);
    return length(p - ba * h) * sign(p.y * ba.x - p.x * ba.y);
}

/// **An icon's glyph**, signed distance in the icon's own units: −1…1 across, +y up.
static float duScanGlyph(int icon, float2 p)
{
    switch (icon) {
    case 1: // circle
        return abs(length(p) - 0.42) - 0.1;
    case 2: // star
        return duScanStar(p * float2(1, -1) + float2(0, 0.04), 0.55, 0.45);
    case 3: { // exclamation
        const float bar = duScanSegment(p, float2(0, 0.5), float2(0, -0.08)) - 0.11;
        const float dot = length(p - float2(0, -0.42)) - 0.12;
        return min(bar, dot);
    }
    case 4: { // question
        const float2 q = p - float2(0, 0.22);
        float arc = abs(length(q) - 0.26) - 0.09;
        // Only the top and right of the circle, then a stem down.
        arc = max(arc, -(q.x + q.y * 0.9 + 0.12));
        const float stem = duScanSegment(p, float2(0.1, 0.02), float2(0, -0.16)) - 0.09;
        const float dot = length(p - float2(0, -0.44)) - 0.11;
        return min(min(arc, stem), dot);
    }
    case 5: // cross
        return min(duScanBox(p, float2(0.5, 0.16), 0.04), duScanBox(p, float2(0.16, 0.5), 0.04));
    case 6: { // crate
        const float outer = abs(duScanBox(p, float2(0.46), 0.06)) - 0.07;
        const float lid = abs(p.y - 0.12) - 0.06;
        return min(outer, max(lid, duScanBox(p, float2(0.46), 0.0)));
    }
    case 7: { // crosshair
        const float ring = abs(length(p) - 0.36) - 0.07;
        const float2 a = abs(p);
        const float ticks = min(duScanBox(a - float2(0.42, 0), float2(0.16, 0.05), 0.02),
                                duScanBox(a - float2(0, 0.42), float2(0.05, 0.16), 0.02));
        return min(ring, min(ticks, length(p) - 0.07));
    }
    case 8: { // door
        const float frame = max(abs(duScanBox(p - float2(0, -0.04), float2(0.3, 0.5), 0.03)) - 0.07, -(p.y + 0.54));
        const float knob = length(p - float2(0.13, -0.06)) - 0.06;
        return min(frame, knob);
    }
    case 9: { // pin
        const float head = abs(length(p - float2(0, 0.14)) - 0.22) - 0.09;
        const float2 q = p - float2(0, 0.14);
        const float tip = max(abs(q.x) * 1.6 - (0.44 + q.y) * 0.62, -q.y - 0.56);
        return min(head, max(tip, -(length(q) - 0.13)));
    }
    default: // diamond
        return (abs(p.x) + abs(p.y) - 0.5) * 0.7071;
    }
}

/// **One seven-segment digit**, `p` in a cell 1 wide and 1.6 tall, centred.
static float duScanDigit(int digit, float2 p)
{
    // Segments a–g, as bits: a top, b top right, c bottom right, d bottom, e bottom left, f top left, g middle.
    const int masks[10] = { 0x3F, 0x06, 0x5B, 0x4F, 0x66, 0x6D, 0x7D, 0x07, 0x7F, 0x6F };
    const int m = masks[clamp(digit, 0, 9)];
    const float w = 0.34, h = 0.66, t = 0.09;
    float d = 1e3;
    if (m & 0x01) d = min(d, duScanSegment(p, float2(-w, h), float2(w, h)));
    if (m & 0x02) d = min(d, duScanSegment(p, float2(w, h), float2(w, 0)));
    if (m & 0x04) d = min(d, duScanSegment(p, float2(w, 0), float2(w, -h)));
    if (m & 0x08) d = min(d, duScanSegment(p, float2(-w, -h), float2(w, -h)));
    if (m & 0x10) d = min(d, duScanSegment(p, float2(-w, 0), float2(-w, -h)));
    if (m & 0x20) d = min(d, duScanSegment(p, float2(-w, h), float2(-w, 0)));
    if (m & 0x40) d = min(d, duScanSegment(p, float2(-w, 0), float2(w, 0)));
    return d - t;
}

/// A small "m": three stems and an arch, in a digit's cell.
static float duScanMetre(float2 p)
{
    const float h = 0.3, w = 0.36, t = 0.08;
    float d = duScanSegment(p, float2(-w, -0.66), float2(-w, h - 0.36));
    d = min(d, duScanSegment(p, float2(0, -0.66), float2(0, h - 0.36)));
    d = min(d, duScanSegment(p, float2(w, -0.66), float2(w, h - 0.36)));
    d = min(d, duScanSegment(p, float2(-w, h - 0.36), float2(w, h - 0.36)));
    return d - t;
}

struct DUScanIconOut {
    float4 position [[position]];
    float2 at;          // the icon: −1…1 over its square; the label: digit cells along, and up within one
    float4 color;
    float icon;
    float isLabel;
    float label;        // meters, the label's
    float cells;        // how many cells the label holds
};

vertex DUScanIconOut duScanIconVertex(uint vertexID [[vertex_id]], uint instanceID [[instance_id]],
                                      const device DUScanIcon *icons [[buffer(0)]],
                                      constant DUScanFrame &frame [[buffer(1)]])
{
    const float2 corners[6] = { float2(-1, -1), float2(1, -1), float2(1, 1), float2(-1, -1), float2(1, 1), float2(-1, 1) };
    const float2 c = corners[vertexID % 6];
    const bool isLabel = vertexID >= 6;
    const DUScanIcon icon = icons[instanceID];
    float4 clip = frame.viewProjection * float4(icon.position.xyz, 1.0);
    DUScanIconOut out;
    out.color = float4(icon.color.rgb, icon.position.w);
    out.icon = icon.color.w;
    out.isLabel = isLabel ? 1.0 : 0.0;
    out.label = icon.label.x;
    // Behind the view: nowhere.
    if (clip.w <= 0.05 || (isLabel && icon.label.x < 0)) {
        out.position = float4(0, 0, -2, 1);
        out.at = 0;
        out.cells = 0;
        return out;
    }
    const float px = frame.screen.w;
    const float2 toNDC = 2.0 / frame.screen.xy;
    float2 offset;
    if (!isLabel) {
        offset = c * px * 0.5;
        out.at = c;
        out.cells = 0;
    } else {
        // Up to four digits and an "m"; "1.2k m" is not worth the shapes: a kilometer shows as its meters.
        const float meters = round(icon.label.x);
        const float digits = meters >= 1000 ? 4.0 : meters >= 100 ? 3.0 : meters >= 10 ? 2.0 : 1.0;
        const float cells = digits + 1.0;
        const float cellW = px * 0.3, cellH = cellW * 1.6;
        const float2 halfSize = float2(cells * cellW * 0.5 + cellW * 0.4, cellH * 0.5 + cellW * 0.3);
        offset = c * halfSize + float2(0, -px * 0.5 - halfSize.y - 3.0);
        out.at = float2((c.x * halfSize.x) / cellW + cells * 0.5, (c.y * halfSize.y) / cellH * 2.0);
        out.cells = cells;
    }
    clip.xy += offset * toNDC * clip.w;
    // Over everything: at the near plane's depth, reversed-Z.
    clip.z = clip.w;
    out.position = clip;
    return out;
}

fragment float4 duScanIconFragment(DUScanIconOut in [[stage_in]])
{
    const float opacity = in.color.a;
    if (in.isLabel < 0.5) {
        const float2 p = in.at;
        const float disc = length(p) - 0.92;
        const float aa = max(fwidth(disc), 1e-3);
        const float inside = 1.0 - smoothstep(-aa, aa, disc);
        const float rim = 1.0 - smoothstep(-aa, aa, abs(length(p) - 0.84) - 0.06);
        const float glyph = duScanGlyph(int(in.icon + 0.5), p * 1.2);
        const float g = 1.0 - smoothstep(-aa * 1.2, aa * 1.2, glyph);
        // A dark disc behind, so it reads over a bright sky; the rim and glyph in its colour.
        const float lit = max(rim, g);
        const float3 rgb = in.color.rgb * lit;
        const float a = (inside * 0.55 + lit * 0.45) * opacity;
        return float4(rgb * opacity, saturate(a));
    }
    const float cells = in.cells;
    const float x = in.at.x, y = in.at.y;
    // A soft dark plate behind the numbers.
    const float plate = duScanBox(float2(x - cells * 0.5, y * 0.8), float2(cells * 0.5 + 0.3, 1.05), 0.4);
    const float paa = max(fwidth(plate), 1e-3);
    const float back = 1.0 - smoothstep(-paa, paa, plate);
    const int cell = int(floor(x));
    float d = 1e3;
    if (cell >= 0 && cell < int(cells)) {
        const float2 p = float2(fract(x) - 0.5, y * 0.8);
        if (cell == int(cells) - 1) {
            d = duScanMetre(p);
        } else {
            const int digits = int(cells) - 1;
            const int place = digits - 1 - cell;
            const int meters = int(round(in.label));
            int value = meters;
            for (int k = 0; k < place; k++) value /= 10;
            d = duScanDigit(value % 10, p);
        }
    }
    // Smoothed by how far a pixel spans in a cell — not by `fwidth(d)`, which jumps where one cell's shape meets the next's
    // and drew a bright seam down every edge.
    const float aa = max(length(fwidth(float2(x, y * 0.8))) * 0.7, 1e-3);
    const float ink = 1.0 - smoothstep(-aa, aa, d);
    const float3 rgb = mix(float3(0), in.color.rgb, ink);
    return float4(rgb * opacity, saturate((back * 0.5 + ink * 0.5) * opacity));
}
