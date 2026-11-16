//
//  FogShaders.metal
//  Ductane
//
//  Volumetric fog (2026-11-16): the air in front of the eye as a grid of cells — a column for every few pixels, sliced
//  deeper the farther they are — each lit by the sun through the shadow map, by the clouds' shadows, and by the world's
//  lights. One thread a column marches its slices front to back and writes, at each, the light the air so far sends
//  toward the eye and how much of what is behind still shows through the ground fog.
//
//  A renderer reads it (`duFogApply`, below — copy it into the shaders that draw surfaces) at a surface's place on the
//  screen and its distance from the eye.
//

#include <metal_stdlib>
using namespace metal;

/// Must match `VolumetricFog.Uniforms`.
struct DUFogUniforms {
    float4x4 inverseViewProjection;
    float4   eye;            // xyz; w where the world's fog starts, metres from the eye
    float4   grid;           // x columns, y rows, z slices, w the distance the sky is read at
    float4   depth;          // x the first slice's near edge, y log(far / near), z the world's fog density, w the share of its light from the sun
    float4   sun;            // xyz toward the light; w 1 when shadows are given
    float4   sunColour;      // rgb; w how much it scatters forward
    float4   ambient;        // rgb: the sky's light, for ground fog
    float4   horizon;        // rgb: the world's fog colour
    float4   groundFog;      // x density at its floor, per metre; y how high it lies; z the floor's base height; w 1 with a floor map
    float4   groundColour;   // rgb; w how much thicker over water
    float4   floorPlace;     // x, y the map's corner (x, z); z its size, metres; w unused
    float4   drift;          // xyz where the wind has carried the fog's wisps (Weather.wisps(at:)); w the haze the lights glow in, per metre
    float4x4 cascades[4];
    float4   cascadeSplits;
    float4   cascadeDepthBias;
    float4   clouds;         // x coverage, y darkness, z base, w thickness
    float4   cloudMotion;    // CloudLayer.motion: xy the way they travel, z how far
    float4   lightCount;     // x
    float4   lightPosition[16];  // xyz; w reach
    float4   lightColour[16];    // rgb
};

/// **Where a point of the world is on the clouds' pattern** — `CloudLayer.place(_:)`: in a frame turned to the way they
/// travel, moved back by how far they have come.
static float2 duCloudPlace(float2 p, float4 motion) {
    return float2(dot(p, float2(-motion.y, motion.x)), dot(p, motion.xy) - motion.z);
}

static float duFogHash(float2 p) {
    p = fract(p * float2(0.1031, 0.1030));
    p += dot(p, p.yx + 33.33);
    return fract((p.x + p.y) * p.x);
}

/// Smooth value noise, 0…1, repeating every `period` cells — so the wisps' drift wraps with no seam.
static float duFogNoise(float2 p, float period) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3 - 2 * f);
    float2 i0 = i - period * floor(i / period), i1 = i0 + 1;
    i1 -= period * floor(i1 / period);
    float a = duFogHash(i0), b = duFogHash(float2(i1.x, i0.y)), c = duFogHash(float2(i0.x, i1.y)), d = duFogHash(i1);
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

/// **How much ground fog a stretch of the eye's ray passes through** — its optical depth, from `a` to `b`: its floor's
/// density, thinning above the smoothed ground to a third every `height` metres, worked out exactly along the stretch so a
/// layer a few metres thick is never missed between two far slices; thicker over water, broken into slow wisps, and fading
/// out beyond the edge of the floor's map — no fog over the void past a world's ground.
static float duGroundFogDepth(float3 a, float3 b, constant DUFogUniforms &u, texture2d<float> floorMap) {
    if (u.groundFog.x <= 0) return 0;
    constexpr sampler edge(filter::linear, address::clamp_to_edge);
    float3 mid = (a + b) * 0.5;
    float floorHeight = u.groundFog.z, water = 0, inside = 1;
    if (u.groundFog.w > 0.5) {
        float2 uv = (mid.xz - u.floorPlace.xy) / u.floorPlace.z;
        float2 f = floorMap.sample(edge, uv, level(0)).rg;
        floorHeight += f.r;
        water = f.g;
        float2 beyond = max(max(-uv, uv - 1), 0.0) * u.floorPlace.z;
        inside = 1 - smoothstep(0.0, 20.0, max(beyond.x, beyond.y));
    }
    float span = distance(a, b), h = u.groundFog.y;
    float lo = min(a.y, b.y) - floorHeight, hi = max(a.y, b.y) - floorHeight;
    float along;
    if (hi - lo < 1e-3) {
        along = span * exp(-max(lo, 0.0) / h);
    } else {
        // Below the floor the fog is at its densest; above, exp(-height / h), integrated over the height it climbs.
        float below = clamp(-lo, 0.0, hi - lo);
        float above = h * (exp(-max(lo, 0.0) / h) - exp(-max(hi, 0.0) / h));
        along = span / (hi - lo) * (below + above);
    }
    // 18 m cells, 256 to `VolumetricFog.wispPeriod`; the finer octave three to each.
    float2 q = duCloudPlace(mid.xz, u.drift) / 18.0;
    float wisps = 0.55 + 0.9 * (duFogNoise(q, 256.0) * 0.65 + duFogNoise(q * 3.0 + 5.0, 768.0) * 0.35);
    return u.groundFog.x * (1 + water * u.groundColour.w) * along * wisps * inside;
}

static float duFogSun(float3 p, float distance, constant DUFogUniforms &u, depth2d_array<float> shadows) {
    if (u.sun.w < 0.5) return 1;
    constexpr sampler compare(filter::linear, address::clamp_to_edge, compare_func::greater_equal);   // reversed-Z
    int cascade = 3;
    for (int i = 0; i < 4; ++i) { if (distance < u.cascadeSplits[i]) { cascade = i; break; } }
    float4 l = u.cascades[cascade] * float4(p, 1);
    float3 projected = l.xyz / l.w;
    float2 uv = projected.xy * float2(0.5, -0.5) + 0.5;
    if (any(uv < 0) || any(uv > 1) || projected.z <= 0) return 1;
    return shadows.sample_compare(compare, uv, cascade, projected.z + u.cascadeDepthBias[cascade], level(0));
}

static float duFogCloudShadow(float3 p, constant DUFogUniforms &u, texture2d<float> map) {
    float coverage = u.clouds.x;
    if (coverage <= 0) return 1;
    constexpr sampler wrap(filter::linear, address::repeat);
    float3 l = u.sun.xyz;
    float mid = u.clouds.z + u.clouds.w * 0.4;
    float2 q = duCloudPlace(p.xz + l.xz / max(l.y, 0.08) * (mid - p.y), u.cloudMotion);
    float spread = map.sample(wrap, q / 61440.0, level(0)).r;
    float cover = smoothstep(1 - coverage - 0.12, 1 - coverage + 0.12, spread);
    return 1 - 0.75 * (1 - 0.8 * smoothstep(0.6, 1.0, coverage)) * cover;
}

/// Henyey–Greenstein, scaled so it averages 1 over every direction.
static float duPhase(float g, float cosine) {
    float g2 = g * g;
    return (1 - g2) / pow(max(1 + g2 - 2 * g * cosine, 1e-4), 1.5);
}

kernel void duFogVolume(uint2 id [[thread_position_in_grid]],
                        constant DUFogUniforms &u [[buffer(0)]],
                        texture3d<half, access::write> volume [[texture(0)]],
                        depth2d_array<float> shadows [[texture(1)]],
                        texture2d<float> floorMap [[texture(2)]],
                        texture2d<float> cloudMap [[texture(3)]],
                        texture2d<half, access::write> skyPicture [[texture(4)]]) {
    int columns = int(u.grid.x), rows = int(u.grid.y), slices = int(u.grid.z);
    if (int(id.x) >= columns || int(id.y) >= rows) return;
    float2 ndc = (float2(id) + 0.5) / float2(columns, rows) * float2(2, -2) + float2(-1, 1);
    float4 far = u.inverseViewProjection * float4(ndc, 0.5, 1);
    float3 eye = u.eye.xyz;
    float3 direction = normalize(far.xyz / far.w - eye);

    float near = u.depth.x, logRatio = u.depth.y, rho = u.depth.z, sunShare = u.depth.w, start = u.eye.w;
    float phase = duPhase(u.sunColour.w, dot(direction, u.sun.xyz));
    // A fixed offset per column, so the slices' steps do not line up into bands.
    float jitter = 0.35 + 0.3 * duFogHash(float2(id) * 1.37 + 0.5);
    int lights = min(int(u.lightCount.x), 16);
    float3 scattered = 0;
    // **What the sky gets**: the same light without the shafts' darkening. That darkening takes away the world fog's
    // light where the sun cannot reach — light a surface was given by the world's fog, but the sky never is. Taken from
    // the sky it went below nothing, and the clouds' shadows printed dark, off-colour patches across it.
    float3 skyward = 0;
    float skyDistance = u.grid.w;
    bool skyWritten = false;
    float through = 1;       // what still shows through the ground fog
    float before = 0;
    for (int i = 0; i < slices; ++i) {
        float after = near * exp(logRatio * float(i + 1) / float(slices));
        float d = mix(before, after, jitter);
        float span = after - before;
        float3 p = eye + direction * d;
        // The world's own fog: exponential-squared from where it starts, as surfaces have it; its thickness here.
        float past = max(d - start, 0.0);
        float worldThrough = exp(-(rho * past) * (rho * past));
        float worldThickness = 2 * rho * rho * past;
        float depth = duGroundFogDepth(eye + direction * before, eye + direction * after, u, floorMap);
        float ground = depth / max(span, 1e-4);
        bool lit = depth > 0 || (worldThickness > 0 && sunShare > 0) || lights > 0;
        if (lit) {
            float sun = duFogSun(p, d, u, shadows) * duFogCloudShadow(p, u, cloudMap);
            float seen = through * worldThrough;
            // Ground fog: lit by the sky and the sun, forward-scattering toward a low sun.
            float slice = exp(-depth);
            float3 groundLight = u.groundColour.rgb * (u.ambient.rgb * 0.7 + u.sunColour.rgb * sun * phase * 0.15);
            scattered += groundLight * (1 - slice) * seen;
            skyward += groundLight * (1 - slice) * seen;
            // The world's fog already greys toward the horizon colour; where the sun cannot reach it, it is darker —
            // the shafts.
            scattered += u.horizon.rgb * max(sunShare * phase * (sun - 1), -1.0) * worldThickness * span * seen;
            // The lights glow in whatever air there is.
            float glowIn = ground + worldThickness + u.drift.w;
            for (int k = 0; k < lights; ++k) {
                float3 to = u.lightPosition[k].xyz - p;
                float t = saturate(length(to) / max(u.lightPosition[k].w, 0.01));
                float fall = (1 - t) * (1 - t);
                float3 glow = u.lightColour[k].rgb * fall * fall * glowIn * span * 0.3 * seen;
                scattered += glow;
                skyward += glow;
            }
            through *= slice;
        }
        volume.write(half4(half3(scattered), half(through)), uint3(id.x, id.y, uint(i)));
        if (!skyWritten && (after >= skyDistance || i == slices - 1)) {
            skyPicture.write(half4(half3(skyward), half(through)), id);
            skyWritten = true;
        }
        before = after;
    }
}

/// **Laying the volume over a surface** — copy into a renderer's shaders. `lookup` is ``VolumetricFog/Lookup``'s
/// `parameters`: x 1 with a volume, y the first slice's near edge, z log(far / near), w slices. `colour` is the surface
/// already fogged by the world's own fog; `distance` how far it is from the eye (a pixel of sky: the lookup's
/// `skyDistance`). The volume's cell holds what the air up to its far edge sends toward the eye, and how much of what is
/// behind still shows through the ground fog.
static inline float3 duFogApply(float3 colour, float3 worldPosition, float distance, float4x4 viewProjection, float4 lookup,
                         texture3d<float> volume) {
    if (lookup.x < 0.5) return colour;
    constexpr sampler cells(filter::linear, address::clamp_to_edge);
    float4 clip = viewProjection * float4(worldPosition, 1);
    float2 uv = clip.xy / max(clip.w, 1e-5) * float2(0.5, -0.5) + 0.5;
    float slice = log(max(distance, 1e-3) / lookup.y) / lookup.z * lookup.w - 1;
    float4 cell = volume.sample(cells, float3(uv, (slice + 0.5) / lookup.w));
    return colour * cell.a + cell.rgb;
}
