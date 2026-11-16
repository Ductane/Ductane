//
//  SkyShaders.metal
//  Ductane
//
//  `SkyPass`: the sky of a `DaySky`, behind everything — its gradient, the sun, the stars and the Milky Way, the moon with
//  its phase, and the clouds: `CloudPass`'s volumetric picture, or a flat layer drawn here.
//

#include <metal_stdlib>
using namespace metal;

// MARK: - Clouds, shared

/// **The clouds' coverage at a point of their layer**, 0…1 — `CloudLayer.coverage(at:coverage:)`: the coverage map read
/// there (repeating every 61,440 m), spread so `coverage` is about the share of the sky covered. A renderer casting the
/// clouds' shadows does the same with the same map.
static float duCoverage(texture2d<float> map, float2 p, float coverage) {
    constexpr sampler wrap(filter::linear, address::repeat);
    float spread = map.sample(wrap, p / 61440.0).r;
    return smoothstep(1.0 - coverage - 0.12, 1.0 - coverage + 0.12, spread);
}

/// Mirrors `CloudPass.Uniforms`.
struct CloudUniforms {
    float4x4 inverseViewProjection;
    float4 eye;          // xyz
    float4 light;        // xyz toward the light — the sun, the moon by night
    float4 lightColour;  // rgb radiance
    float4 zenith;
    float4 horizon;
    float4 clouds;       // x coverage, y darkness, z base, w thickness
    float4 drift;        // xy metres; z steps; w frame, for the starting offset
};

struct CloudOut {
    float4 position [[position]];
    float2 ndc;
};

vertex CloudOut cloudVertex(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2) * 2.0 - 1.0;
    CloudOut out;
    out.position = float4(p, 0, 1);
    out.ndc = p;
    return out;
}

/// The clouds' density at `p`: the coverage of their layer there, shaped by height — round bottoms, billowing tops,
/// taller where coverage is thick — and eroded by finer noise at the edges.
static float cloudDensity(float3 p, constant CloudUniforms &u, texture3d<float> noise, texture2d<float> map, sampler s,
                          float detail) {
    float h = (p.y - u.clouds.z) / u.clouds.w;
    if (h <= 0.0 || h >= 1.0) return 0;
    float2 q = p.xz + u.drift.xy;
    float local = duCoverage(map, q, u.clouds.x);
    if (local <= 0.001) return 0;
    // Taller towers where the cover is thick: the top falls away sooner where it is thin.
    float top = mix(0.45, 1.0, local);
    float shape = smoothstep(0.0, 0.12, h) * (1.0 - smoothstep(top * 0.55, top, h));
    float3 w = float3(q.x, p.y * 1.6, q.y) / 2200.0;
    float base = noise.sample(s, w).r * shape;
    // Sharp-edged: what is over the threshold quickly becomes cloud, so a clear sky is clouds and blue, not haze. Broken
    // into separate clouds by the noise unless the sky is overcast, when the deck closes up.
    float reach = mix(0.6, 1.0, u.clouds.x * u.clouds.x);
    float d = saturate((base - (1.0 - local * reach)) * 4.0);
    // The finer erosion, faded out far off: there a pixel spans more than its cells, and it striped the distance.
    if (detail > 0.0 && d > 0.0) {
        float fine = noise.sample(s, w * 7.3).g;
        d = saturate(d - (1.0 - fine) * 0.5 * (1.0 - d) * detail);
    }
    return d;
}

/// **The clouds, raymarched**, a picture at a lower resolution: in rgb the light they send toward the eye, in alpha how
/// much of the sky behind still shows. Through the layer from its base to its top, lit by a few steps toward the light
/// (Beer's law, and the powder darkening of a cloud's sunlit flank), with a forward-scattering silver lining; darker when
/// the weather is; faded into the horizon far off.
fragment float4 cloudFragment(CloudOut in [[stage_in]], constant CloudUniforms &u [[buffer(0)]],
                              texture3d<float> noise [[texture(0)]], texture2d<float> map [[texture(1)]]) {
    constexpr sampler s(filter::linear, address::repeat);
    float4 far = u.inverseViewProjection * float4(in.ndc, 0.5, 1);
    float3 dir = normalize(far.xyz / far.w - u.eye.xyz);
    if (dir.y < 0.01 || u.clouds.x <= 0.0) return float4(0, 0, 0, 1);
    float base = u.clouds.z, top = u.clouds.z + u.clouds.w;
    float t0 = max((base - u.eye.y) / dir.y, 0.0), t1 = (top - u.eye.y) / dir.y;
    t1 = min(t1, t0 + 12000.0);
    if (t1 <= t0) return float4(0, 0, 0, 1);
    int steps = int(u.drift.z);
    float step = (t1 - t0) / float(steps);
    // A different start in each pixel and frame, so the steps do not band.
    float jitter = fract(52.9829189 * fract(dot(in.position.xy, float2(0.06711056, 0.00583715)) + u.drift.w * 0.618));
    float3 L = normalize(u.light.xyz);
    float cosine = dot(dir, L);
    float g = 0.6, g2 = g * g;
    float forward = (1.0 - g2) / (4.0 * M_PI_F * pow(1.0 + g2 - 2.0 * g * cosine, 1.5));
    float phase = mix(1.0 / (4.0 * M_PI_F), forward, 0.7) * 4.0 * M_PI_F;
    float dark = 1.0 - 0.8 * u.clouds.y;
    float3 ambient = mix(u.horizon.rgb, u.zenith.rgb, 0.5) * 0.6 * dark;
    float3 sunlight = u.lightColour.rgb * 0.9 * dark;
    const float sigma = 0.012;
    float transmittance = 1.0;
    float3 light = 0;
    for (int i = 0; i < steps; i++) {
        float t = t0 + (float(i) + jitter) * step;
        float3 p = u.eye.xyz + dir * t;
        float d = cloudDensity(p, u, noise, map, s, 1.0 - smoothstep(3000.0, 9000.0, t));
        if (d <= 0.0) continue;
        // Toward the light, a few long steps: how much cloud the light comes through.
        float od = 0;
        for (int j = 1; j <= 3; j++) od += cloudDensity(p + L * (float(j) * 140.0), u, noise, map, s, 0.0);
        float lightT = exp(-od * sigma * 140.0 * 1.2);
        float powder = 1.0 - exp(-d * sigma * 220.0);
        float h = saturate((p.y - base) / u.clouds.w);
        float3 scatter = sunlight * lightT * phase * mix(0.6, 1.0, powder) + ambient * mix(0.55, 1.0, h);
        float through = exp(-d * sigma * step);
        light += transmittance * scatter * (1.0 - through);
        transmittance *= through;
        if (transmittance < 0.02) break;
    }
    // Far off, into the horizon's haze: what the sky's own gradient takes over.
    float fade = smoothstep(0.01, 0.12, dir.y) * exp(-t0 / 45000.0);
    return float4(light * fade, mix(1.0, transmittance, fade));
}

// MARK: - The sky

/// Mirrors `SkyPass.Uniforms`.
struct SkyUniforms {
    float4x4 inverseViewProjection;
    float4 eye;          // xyz
    float4 sunDirection; // xyz, toward the light — the sun, the moon by night
    float4 sunColour;    // rgb, radiance
    float4 zenith;
    float4 horizon;
    float4 ground;
    float4 sun;          // xyz toward the sun itself; w 1 to draw its disc
    float4 moon;         // xyz toward the moon; w how much of its face is lit
    float4 night;        // x the stars' brightness; y clouds: 0 none, 1 flat, 2 the volumetric picture; z time, seconds
    float4 starRow0;     // the stars' turning, row by row
    float4 starRow1;
    float4 starRow2;
    float4 clouds;       // x coverage, y darkness, z base, w thickness
    float4 cloudDrift;   // xy metres
};

struct SkyOut {
    float4 position [[position]];
    float2 ndc;
};

/// A full-screen triangle from the vertex id, **at depth 0** — the far plane under reversed-Z — drawn with no depth test
/// or write, so anything drawn after covers it.
vertex SkyOut skyVertex(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2) * 2.0 - 1.0;
    SkyOut out;
    out.position = float4(p, 0, 1);
    out.ndc = p;
    return out;
}

static float skyHash(float3 c) {
    uint3 q = as_type<uint3>(int3(c));
    uint h = (q.x * 73856093u) ^ (q.y * 19349663u) ^ (q.z * 83492791u);
    h = h * 747796405u + 2891336453u;
    h ^= h >> 16;
    return float(h & 0xFFFFu) / 65535.0;
}

/// Smooth value noise in three dimensions, one cell a unit.
static float skyNoise(float3 p) {
    float3 i = floor(p), f = p - i;
    float3 u = f * f * (3.0 - 2.0 * f);
    float a = mix(skyHash(i), skyHash(i + float3(1, 0, 0)), u.x);
    float b = mix(skyHash(i + float3(0, 1, 0)), skyHash(i + float3(1, 1, 0)), u.x);
    float c = mix(skyHash(i + float3(0, 0, 1)), skyHash(i + float3(1, 0, 1)), u.x);
    float d = mix(skyHash(i + float3(0, 1, 1)), skyHash(i + float3(1, 1, 1)), u.x);
    return mix(mix(a, b, u.y), mix(c, d, u.y), u.z);
}

/// **The stars, and the Milky Way**, in a direction on the stars' own sphere: points of differing brightness and warmth,
/// twinkling a little, and a band of faint glow broken by dust along a great circle of it.
static float3 starLight(float3 s, float time) {
    float3 colour = 0;
    // Two scales of cells on the sphere: a few bright stars, more faint ones.
    for (int layer = 0; layer < 2; layer++) {
        float scale = layer == 0 ? 90.0 : 220.0;
        float3 g = s * scale, c = floor(g);
        float h = skyHash(c + float(layer) * 101.0);
        float threshold = layer == 0 ? 0.985 : 0.965;
        if (h > threshold) {
            float3 at = c + 0.5 + (float3(skyHash(c + 7.0), skyHash(c + 13.0), skyHash(c + 19.0)) - 0.5) * 0.6;
            float d = length(g - at);
            float spot = smoothstep(layer == 0 ? 0.16 : 0.11, 0.0, d);
            float bright = (h - threshold) / (1.0 - threshold);
            float twinkle = 0.8 + 0.2 * sin(time * (2.0 + h * 5.0) + h * 40.0);
            float3 tint = mix(float3(1.0, 0.85, 0.7), float3(0.75, 0.85, 1.0), skyHash(c + 29.0));
            colour += tint * spot * (0.3 + 0.7 * bright) * twinkle * (layer == 0 ? 6.0 : 2.5);
        }
    }
    // The Milky Way: a band about the great circle at right angles to this axis, mottled and split by dust.
    float band = exp(-pow(dot(s, normalize(float3(0.35, 0.2, 0.92))) * 7.0, 2.0));
    float mottle = skyNoise(s * 6.0) * 0.5 + skyNoise(s * 14.0) * 0.3 + skyNoise(s * 31.0) * 0.2;
    float dust = smoothstep(0.45, 0.7, skyNoise(s * 11.0 + 5.0) * 0.6 + skyNoise(s * 27.0) * 0.4);
    colour += float3(0.55, 0.6, 0.75) * band * smoothstep(0.3, 0.8, mottle) * (1.0 - 0.75 * dust) * 0.09;
    return colour;
}

/// **The moon**, where the eye looks at it: its disc a degree and a quarter across, lit on the side facing the sun — its
/// phase — with faint earthshine on the rest and a little mottling of seas. Nothing elsewhere.
static float3 moonLight(float3 dir, float3 moon, float3 sun) {
    const float radius = 0.02;
    float3 o = dir - moon * dot(dir, moon);
    float r = length(o) / radius;
    if (dot(dir, moon) <= 0.0 || r >= 1.0) return 0;
    // The point of the ball under this pixel, its normal facing back toward the eye.
    float3 n = normalize(o / radius - moon * sqrt(max(1.0 - r * r, 0.0)));
    float day = smoothstep(-0.05, 0.05, dot(n, sun));
    float3 seas = float3(0.82, 0.82, 0.8) - 0.18 * skyHash(floor(o / radius * 4.0 + 50.0));
    return seas * (day * 1.6 + 0.02) * smoothstep(1.0, 0.92, r);
}

/// The zenith overhead fading to the horizon, the ground's colour below it, the sun's disc, the night's stars and moon —
/// and the clouds over all of them.
fragment float4 skyFragment(SkyOut in [[stage_in]], constant SkyUniforms &sky [[buffer(0)]],
                            texture2d<float> clouds [[texture(0)]], texture2d<float> map [[texture(1)]]) {
    float4 far = sky.inverseViewProjection * float4(in.ndc, 0.5, 1);
    float3 direction = normalize(far.xyz / far.w - sky.eye.xyz);
    float up = direction.y;
    float3 colour = up >= 0
        ? mix(sky.horizon.rgb, sky.zenith.rgb * 1.6, pow(up, 0.6))
        : mix(sky.horizon.rgb, sky.ground.rgb, saturate(-up * 4));
    float above = smoothstep(-0.01, 0.03, up);
    // What lies beyond the air: the stars and the Milky Way by night, the moon at any hour, the sun's disc.
    float3 beyond = 0;
    if (sky.night.x > 0.0 && up > -0.05) {
        float3x3 turn = float3x3(sky.starRow0.xyz, sky.starRow1.xyz, sky.starRow2.xyz);
        beyond += starLight(transpose(turn) * direction, sky.night.z) * sky.night.x * smoothstep(0.0, 0.12, up);
    }
    beyond += moonLight(direction, sky.moon.xyz, sky.sun.xyz) * above;
    if (sky.sun.w > 0.5) {
        float disc = smoothstep(0.9995, 0.9998, dot(direction, sky.sun.xyz));
        beyond += sky.sunColour.rgb * disc * 4;
    }
    // The clouds over all of it: the raymarched picture, or a flat layer.
    float through = 1.0;
    float3 cloudLight = 0;
    if (sky.night.y > 1.5) {
        constexpr sampler linear(filter::linear, address::clamp_to_edge);
        float4 c = clouds.sample(linear, in.ndc * float2(0.5, -0.5) + 0.5);
        cloudLight = c.rgb;
        through = c.a;
    } else if (sky.night.y > 0.5 && up > 0.01) {
        float t = (sky.clouds.z + sky.clouds.w * 0.3 - sky.eye.y) / up;
        float2 p = sky.eye.xz + direction.xz * t + sky.cloudDrift.xy;
        float cover = duCoverage(map, p, sky.clouds.x);
        float2 toward = normalize(sky.sunDirection.xz + 1e-4) * 300.0;
        float shade = 1.0 - 0.5 * duCoverage(map, p + toward, sky.clouds.x);
        float dark = 1.0 - 0.8 * sky.clouds.y;
        float fade = smoothstep(0.01, 0.15, up) * exp(-t / 45000.0);
        float a = cover * fade;
        cloudLight = (sky.sunColour.rgb * 0.3 * shade + mix(sky.horizon.rgb, sky.zenith.rgb, 0.5)) * dark * a;
        through = 1.0 - a;
    }
    return float4((colour + beyond) * through + cloudLight, 1);
}
