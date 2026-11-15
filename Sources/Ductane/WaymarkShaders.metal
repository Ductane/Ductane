//
//  WaymarkShaders.metal
//  Ductane
//
//  A `Waymark`'s line, marks and beam, for `WaymarkRenderer`. Compiled at runtime from source when the package was
//  built by `swift build`, which produces no metallib — see `ShaderLibrary`.
//

#include <metal_stdlib>
using namespace metal;

/// A point of the line, or a mark, as `WaymarkRenderer.Vertex` writes it: **two `float4`s**.
struct DUWaymarkVertex {
    float4 positionAndU;     // xyz where, u: meters along the line
    float4 tangentAndSide;   // xyz the way the line heads there, w: −1 or 1, which edge of the ribbon (marks: unused)
};

/// The frame, as `WaymarkRenderer.Frame` writes it.
struct DUWaymarkFrame {
    float4x4 viewProjection;
    float4 camera;      // xyz where the view is; w the time, seconds
    float4 color;       // rgb linear, times intensity and brightness; a glow 0…1
    float4 shape;       // x pattern (0 dots, 1 dashes, 2 arrows, 3 chevrons, 4 line), y width, z spacing, w roundness
    float4 reveal;      // x how far it has swept, meters; y its fade at the end; z pulses' speed, m/s; w its length
    float4 beamColor;   // rgb linear, times intensity and brightness; a the beam's opacity now
    float4 beamShape;   // x core width, y height, z roundness, w glow
    float4 beamBase;    // xyz the place; w how fast its bands climb
    float4 screen;      // x the narrowest the line is drawn, radians; y the beam's core; z a ribbon faces the view (1)
};

// MARK: The marks' shapes

/// Signed distance to a box of half-size `b` with corners rounded by `r`.
static float duRoundBox(float2 p, float2 b, float r)
{
    r = min(r, min(b.x, b.y));
    const float2 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

/// Distance to the segment a–b.
static float duSegment(float2 p, float2 a, float2 b)
{
    const float2 pa = p - a, ba = b - a;
    const float h = saturate(dot(pa, ba) / dot(ba, ba));
    return length(pa - ba * h);
}

/// Signed distance to a triangle (Inigo Quilez's).
static float duTriangle(float2 p, float2 p0, float2 p1, float2 p2)
{
    const float2 e0 = p1 - p0, e1 = p2 - p1, e2 = p0 - p2;
    const float2 v0 = p - p0, v1 = p - p1, v2 = p - p2;
    const float2 pq0 = v0 - e0 * saturate(dot(v0, e0) / dot(e0, e0));
    const float2 pq1 = v1 - e1 * saturate(dot(v1, e1) / dot(e1, e1));
    const float2 pq2 = v2 - e2 * saturate(dot(v2, e2) / dot(e2, e2));
    const float s = sign(e0.x * e2.y - e0.y * e2.x);
    const float2 d = min(min(float2(dot(pq0, pq0), s * (v0.x * e0.y - v0.y * e0.x)),
                             float2(dot(pq1, pq1), s * (v1.x * e1.y - v1.y * e1.x))),
                         float2(dot(pq2, pq2), s * (v2.x * e2.y - v2.y * e2.x)));
    return -sqrt(d.x) * sign(d.y);
}

/// Half a mark's length along the line, meters, for a mark `w` wide.
static float duHalfLength(int pattern, float w, float spacing)
{
    if (pattern == 1) return max(spacing * 0.32, w * 0.5);
    if (pattern == 3) return w * 0.42;
    return w * 0.5;
}

/// **Signed distance to a mark**, `p` meters along the line from its middle and across it.
static float duMark(int pattern, float2 p, float w, float spacing, float roundness)
{
    if (pattern == 4) return abs(p.y) - w * 0.5;
    if (pattern == 1) return duRoundBox(p, float2(duHalfLength(1, w, spacing), w * 0.5), roundness * w * 0.5);
    if (pattern == 2) {
        // An arrowhead pointing on along the line, its corners rounded by shrinking it and growing it back.
        const float r = roundness * w * 0.18;
        const float k = 1.0 - r / max(w * 0.5, 1e-4);
        return duTriangle(p, float2(w * 0.5, 0) * k, float2(-w * 0.45, w * 0.5) * k, float2(-w * 0.45, -w * 0.5) * k) - r;
    }
    if (pattern == 3) {
        // A chevron: two strokes meeting at the front. Round, its ends are round; square, they are cut by its box.
        const float stroke = w * 0.24;
        const float2 tip = float2(w * 0.3, 0);
        const float s = min(duSegment(p, float2(-w * 0.3, w * 0.5), tip), duSegment(p, float2(-w * 0.3, -w * 0.5), tip));
        const float rounded = s - stroke * 0.5;
        const float square = max(rounded, duRoundBox(p, float2(w * 0.3 + stroke * 0.3, w * 0.5), 0.0));
        return mix(square, rounded, roundness);
    }
    return duRoundBox(p, float2(w * 0.5), roundness * w * 0.5);
}

/// **How far a mark's glow reaches**, meters: its width times the glow — never past the gap to the next mark, so a
/// glow fades out before the next one's begins, and before the edge of what it is drawn on.
static float duGlowReach(int pattern, float w, float spacing, float glow)
{
    const float reach = w * glow;
    if (pattern == 4) return reach;
    return min(reach, max(spacing * 0.5 - duHalfLength(pattern, w, spacing), 0.0));
}

/// How much wider than its width a mark is drawn `distance` off: at least a few pixels — but a pattern stops growing
/// before its marks crowd each other.
static float duGrow(constant DUWaymarkFrame &frame, float distance)
{
    const float width = frame.shape.y, spacing = frame.shape.z;
    float grow = max(1.0, distance * frame.screen.x / width);
    if (frame.shape.x < 3.5) grow = min(grow, max(1.0, spacing * 0.7 / width));
    return grow;
}

/// **A mark's color and coverage** from its distance `d`: its core, the glow round it falling to nothing at its reach,
/// the sweep's bright front, the pulses, the fade at the end and near the lens.
static float4 duShade(constant DUWaymarkFrame &frame, float d, float reach, float u, float distance)
{
    const float aa = max(fwidth(d), 1e-4);
    const float core = 1.0 - smoothstep(-aa, aa, d);
    const float glow = reach > 1e-4 ? pow(saturate(1.0 - max(d, 0.0) / reach), 2.5) * (1.0 - core) : 0.0;

    const float front = frame.reveal.x;
    const float shown = 1.0 - smoothstep(front - 0.4, front + 0.05, u);
    const float head = 1.0 + 0.9 * exp(-max(front - u, 0.0) / 1.5);
    // **Pulses running on toward the place**: a band of light every twelve meters, a couple of meters wide.
    float pulse = 1.0;
    if (frame.reveal.z > 0.0) {
        const float period = 12.0;
        const float x = fract((u - frame.camera.w * frame.reveal.z) / period) * period - period * 0.5;
        pulse = 0.8 + 1.1 * exp(-x * x / 1.6);
    }
    // In from nothing over its first meter, and out of the way of the lens.
    const float fade = frame.reveal.y * shown * smoothstep(0.2, 1.2, u) * smoothstep(1.5, 3.5, distance);
    const float3 rgb = frame.color.rgb * (core + glow * 0.6) * head * pulse * fade;
    return float4(rgb, saturate((core * 0.85 + glow * 0.25) * fade));
}

// MARK: The ribbon: the line, or marks on the ground

struct DUWaymarkRibbonOut {
    float4 position [[position]];
    float2 at;          // meters along the line, meters across it
    float grow;
    float distance;     // meters from the view
};

vertex DUWaymarkRibbonOut duWaymarkRibbonVertex(uint vertexID [[vertex_id]],
                                                const device DUWaymarkVertex *vertices [[buffer(0)]],
                                                constant DUWaymarkFrame &frame [[buffer(1)]])
{
    const DUWaymarkVertex v = vertices[vertexID];
    const float3 centre = v.positionAndU.xyz;
    const float3 tangent = normalize(v.tangentAndSide.xyz);
    const float3 toView = frame.camera.xyz - centre;
    const float distance = max(length(toView), 1e-3);
    // **On the ground**, flat as paint, square to the line and to up; **facing the view** — a floating line — square to
    // the line and the view. Either way, end on, the other.
    const float3 flat = cross(float3(0, 1, 0), tangent), facing = cross(tangent, toView / distance);
    float3 across = frame.screen.z > 0.5 ? facing : flat;
    if (length(across) < 1e-3) across = frame.screen.z > 0.5 ? flat : facing;
    across = normalize(across);

    const int pattern = int(frame.shape.x + 0.5);
    const float grow = duGrow(frame, distance);
    const float w = frame.shape.y * grow;
    const float spread = w * 0.5 + duGlowReach(pattern, w, frame.shape.z, frame.color.a);

    DUWaymarkRibbonOut out;
    out.position = frame.viewProjection * float4(centre + across * v.tangentAndSide.w * spread, 1.0);
    out.at = float2(v.positionAndU.w, v.tangentAndSide.w * spread);
    out.grow = grow;
    out.distance = distance;
    return out;
}

fragment float4 duWaymarkRibbonFragment(DUWaymarkRibbonOut in [[stage_in]],
                                        constant DUWaymarkFrame &frame [[buffer(1)]])
{
    const float u = in.at.x;
    if (u > frame.reveal.x + 0.05) discard_fragment();
    const int pattern = int(frame.shape.x + 0.5);
    const float w = frame.shape.y * in.grow, spacing = frame.shape.z;
    // Centred on the nearest mark along, meters across.
    const float along = pattern == 4 ? 0.0 : u - spacing * round(u / spacing);
    const float d = duMark(pattern, float2(along, in.at.y), w, spacing, frame.shape.w);
    return duShade(frame, d, duGlowReach(pattern, w, spacing, frame.color.a), u, in.distance);
}

// MARK: Floating marks: one square to the view for each

struct DUWaymarkMarkOut {
    float4 position [[position]];
    float2 at;          // meters along the line from the mark's middle, and across it
    float u;            // the mark's meters along the line
    float grow;
    float distance;
};

vertex DUWaymarkMarkOut duWaymarkMarkVertex(uint vertexID [[vertex_id]], uint instanceID [[instance_id]],
                                            const device DUWaymarkVertex *marks [[buffer(0)]],
                                            constant DUWaymarkFrame &frame [[buffer(1)]])
{
    const float2 corners[6] = { float2(-1, -1), float2(1, -1), float2(1, 1), float2(-1, -1), float2(1, 1), float2(-1, 1) };
    const float2 c = corners[vertexID];
    const DUWaymarkVertex m = marks[instanceID];
    const float3 centre = m.positionAndU.xyz;
    const float3 toView = frame.camera.xyz - centre;
    const float distance = max(length(toView), 1e-3);
    // The view's own right and up here, and the line's heading as the view sees it: an arrow points along the line on
    // screen, whichever way it is looked at.
    const float3 forward = -toView / distance;
    float3 right = cross(forward, float3(0, 1, 0));
    right = length(right) > 1e-3 ? normalize(right) : float3(1, 0, 0);
    const float3 up = cross(right, forward);
    const float3 tangent = m.tangentAndSide.xyz;
    float2 heading = float2(dot(tangent, right), dot(tangent, up));
    heading = length(heading) > 1e-3 ? normalize(heading) : float2(1, 0);
    const float3 alongAxis = right * heading.x + up * heading.y;
    const float3 acrossAxis = right * -heading.y + up * heading.x;

    const int pattern = int(frame.shape.x + 0.5);
    const float grow = duGrow(frame, distance);
    const float w = frame.shape.y * grow, spacing = frame.shape.z;
    const float reach = duGlowReach(pattern, w, spacing, frame.color.a);
    const float2 extent = float2(duHalfLength(pattern, w, spacing), w * 0.5) + reach;

    DUWaymarkMarkOut out;
    out.position = frame.viewProjection * float4(centre + alongAxis * c.x * extent.x + acrossAxis * c.y * extent.y, 1.0);
    out.at = c * extent;
    out.u = m.positionAndU.w;
    out.grow = grow;
    out.distance = distance;
    return out;
}

fragment float4 duWaymarkMarkFragment(DUWaymarkMarkOut in [[stage_in]],
                                      constant DUWaymarkFrame &frame [[buffer(1)]])
{
    if (in.u > frame.reveal.x + 0.05) discard_fragment();
    const int pattern = int(frame.shape.x + 0.5);
    const float w = frame.shape.y * in.grow, spacing = frame.shape.z;
    const float d = duMark(pattern, in.at, w, spacing, frame.shape.w);
    return duShade(frame, d, duGlowReach(pattern, w, spacing, frame.color.a), in.u, in.distance);
}

// MARK: The beam

struct DUWaymarkBeamOut {
    float4 position [[position]];
    float2 at;          // the column: meters across from its axis, meters up; the foot: −1…1 across and up
    float core;         // the core's width here, meters
    float isFoot;
};

vertex DUWaymarkBeamOut duWaymarkBeamVertex(uint vertexID [[vertex_id]],
                                            constant DUWaymarkFrame &frame [[buffer(1)]])
{
    const float2 corners[6] = { float2(-1, 0), float2(1, 0), float2(1, 1), float2(-1, 0), float2(1, 1), float2(-1, 1) };
    const float2 c = corners[vertexID % 6];
    const bool foot = vertexID >= 6;
    const float3 base = frame.beamBase.xyz;
    const float3 toView = frame.camera.xyz - base;
    const float distance = max(length(toView), 1e-3);
    float3 across = cross(float3(0, 1, 0), toView);
    across = length(across) > 1e-3 ? normalize(across) : float3(1, 0, 0);
    const float core = max(frame.beamShape.x, distance * frame.screen.y);

    DUWaymarkBeamOut out;
    out.core = core;
    if (foot) {
        // A glow at its foot, square to the view.
        const float3 up = normalize(cross(toView / distance, across));
        const float size = max(2.0, core * 4.0);
        const float2 q = float2(c.x, c.y * 2.0 - 1.0);
        out.position = frame.viewProjection * float4(base + float3(0, 0.3, 0) + (across * q.x + up * q.y) * size, 1.0);
        out.at = q;
        out.isFoot = 1.0;
    } else {
        const float spread = core * 0.5 * (1.0 + 4.0 * frame.beamShape.w);
        const float height = frame.beamShape.y;
        out.position = frame.viewProjection * float4(base + across * c.x * spread + float3(0, c.y * height, 0), 1.0);
        out.at = float2(c.x * spread, c.y * height);
        out.isFoot = 0.0;
    }
    return out;
}

fragment float4 duWaymarkBeamFragment(DUWaymarkBeamOut in [[stage_in]],
                                      constant DUWaymarkFrame &frame [[buffer(1)]])
{
    const float opacity = frame.beamColor.a;
    if (in.isFoot > 0.5) {
        // Falling to nothing before its square's edge, so no square shows.
        const float r2 = dot(in.at, in.at);
        const float g = exp(-4.0 * r2) * saturate(1.0 - r2) * opacity;
        return float4(frame.beamColor.rgb * g * 0.6, g * 0.3);
    }
    const float roundness = frame.beamShape.z, glow = frame.beamShape.w;
    const float k = abs(in.at.x) / (in.core * 0.5);
    const float aa = max(fwidth(k), 1e-3) * (1.0 + roundness * 3.0);
    const float edge = 1.0 - smoothstep(1.0 - aa, 1.0 + aa, k);
    // Flat and hard-edged at no roundness; brightest down its middle and soft at its sides at full.
    const float core = edge * mix(1.0, sqrt(saturate(1.0 - k * k)), roundness);
    // Its glow falls to nothing at the column's edge.
    const float reach = max(in.core * 2.0 * glow, 1e-4);
    const float halo = glow > 0.0 ? glow * pow(saturate(1.0 - max(abs(in.at.x) - in.core * 0.5, 0.0) / reach), 2.5) * (1.0 - edge)
                                  : 0.0;
    const float y = in.at.y, height = frame.beamShape.y;
    // Strongest at the foot, fading as it rises; soft where it meets the ground.
    const float rise = pow(saturate(1.0 - y / height), 1.3) * smoothstep(0.0, 0.6, y);
    float bands = 1.0;
    if (frame.beamBase.w > 0.0) {
        const float x = fract((y - frame.camera.w * frame.beamBase.w * 6.0) / 10.0) * 10.0 - 5.0;
        bands = 0.85 + 0.6 * exp(-x * x / 1.5);
    }
    const float shown = rise * opacity;
    return float4(frame.beamColor.rgb * (core + halo * 0.7) * bands * shown, saturate((core * 0.95 + halo * 0.35) * shown));
}
