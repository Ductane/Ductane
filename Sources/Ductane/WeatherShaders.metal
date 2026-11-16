//
//  WeatherShaders.metal
//  Ductane
//
//  Rain, snow and rain's splashes, for `WeatherRenderer`. Every drop is made in the vertex shader from its number and the
//  time — nothing is simulated or stored — in a box that follows the eye. Compiled at runtime from source when the package
//  was built by `swift build`, which produces no metallib — see `ShaderLibrary`.
//

#include <metal_stdlib>
using namespace metal;

/// The frame, as `WeatherRenderer.Frame` writes it.
struct DUWeatherFrame {
    float4x4 viewProjection;
    float4x4 coverViewProjection;
    float4 eye;       // xyz where the view is; w the time, seconds, wrapped
    float4 wind;      // xyz the way the wind pushes a drop, m/s; w how fast it falls, m/s
    float4 shape;     // x the box's half width, y its height, z drops drawn, w a drop's length (rain) or size (snow)
    float4 light;     // rgb the light on a drop, linear; a its opacity
    float4 cover;     // x the cover's top, y its depth range, z whether there is one, w its texels a side
    float4 screen;    // x the angle a pixel spans; y the fog's density; z splashes' reach, m; w unused
    float4 fog;       // rgb what distance fades into
};

struct DUWeatherOut {
    float4 position [[position]];
    float2 uv;         // across −1…1, along 0 tail…1 head (rain); −1…1 both ways (snow, splash)
    float opacity;
};

static float duWeatherHash(uint n)
{
    n = (n ^ 61u) ^ (n >> 16);
    n *= 9u;
    n ^= n >> 4;
    n *= 0x27d4eb2du;
    n ^= n >> 15;
    return float(n) * (1.0 / 4294967296.0);
}

static float3 duWeatherHash3(uint i)
{
    return float3(duWeatherHash(i * 3u + 1u), duWeatherHash(i * 3u + 2u), duWeatherHash(i * 3u + 3u));
}

/// The height of what is uppermost over `p`, or far below everything when nothing is, or there is no cover.
static float duWeatherCover(float3 p, constant DUWeatherFrame &f, depth2d<float> cover)
{
    if (f.cover.z < 0.5) return -1e9;
    const float4 c = f.coverViewProjection * float4(p, 1.0);
    const float2 uv = float2(c.x * 0.5 + 0.5, 0.5 - c.y * 0.5);
    if (any(uv < 0.0) || any(uv >= 1.0)) return -1e9;
    const float d = cover.read(uint2(uv * f.cover.w));
    if (d <= 0.0) return -1e9;
    return f.cover.x - (1.0 - d) * f.cover.y;
}

/// Where drop `i` is now: its place in the box, moved by its fall and the wind, wrapped round the eye.
static float3 duWeatherPlace(uint i, float3 velocity, constant DUWeatherFrame &f, float sway)
{
    const float halfWidth = f.shape.x, height = f.shape.y, t = f.eye.w;
    const float3 h = duWeatherHash3(i);
    const float3 size = float3(halfWidth * 2.0, height, halfWidth * 2.0);
    float3 p = h * size + velocity * t;
    if (sway > 0.0) {
        p.x += sin(t * 0.9 + h.y * 23.0) * sway;
        p.z += cos(t * 0.7 + h.x * 19.0) * sway;
    }
    const float3 origin = f.eye.xyz - float3(halfWidth, height * 0.6, halfWidth);
    const float3 q = p - origin;
    return origin + q - size * floor(q / size);
}

/// How much of a drop at `p` shows: none right at the eye or at the box's edge, less through fog.
static float duWeatherFade(float3 p, constant DUWeatherFrame &f)
{
    const float d = distance(p, f.eye.xyz);
    const float near = smoothstep(0.3, 1.2, d);
    const float far = 1.0 - smoothstep(f.shape.x * 0.7, f.shape.x, distance(p.xz, f.eye.xz));
    const float fog = exp(-pow(f.screen.y * d, 2.0));
    return near * far * fog;
}

constant float2 duWeatherCorners[6] = {
    float2(-1, 0), float2(1, 0), float2(1, 1), float2(-1, 0), float2(1, 1), float2(-1, 1)
};

/// **A raindrop**: a thin streak along the way it falls, facing the eye — a drop seen in a frame's blur.
vertex DUWeatherOut duWeatherRainVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                        constant DUWeatherFrame &f [[buffer(0)]],
                                        depth2d<float> cover [[texture(0)]])
{
    DUWeatherOut out;
    const float3 h = duWeatherHash3(iid ^ 0x5bd1e995u);
    const float fall = f.wind.w * (0.85 + 0.3 * h.x);
    const float3 velocity = float3(f.wind.x, -fall, f.wind.z);
    const float3 head = duWeatherPlace(iid, velocity, f, 0.0);
    const float3 way = normalize(velocity);
    const float3 tail = head - way * f.shape.w * (0.7 + 0.6 * h.y);
    const float2 corner = duWeatherCorners[vid];
    const float3 p = mix(tail, head, corner.y);
    const float distanceToEye = distance(p, f.eye.xyz);
    float3 side = cross(way, f.eye.xyz - p);
    side = length(side) > 1e-5 ? normalize(side) : float3(1, 0, 0);
    // At least a pixel and a half wide, so far rain is a haze rather than flicker.
    const float width = max(0.006, distanceToEye * f.screen.x * 0.75);
    out.position = f.viewProjection * float4(p + side * corner.x * width, 1.0);
    out.uv = corner;
    // Under a roof: nothing.
    const bool covered = head.y < duWeatherCover(head, f, cover) - 0.05;
    out.opacity = covered ? 0.0 : duWeatherFade(head, f) * min(1.0, 0.012 / width + 0.25);
    if (covered) out.position = float4(0, 0, -1, 1);
    return out;
}

fragment float4 duWeatherRainFragment(DUWeatherOut in [[stage_in]], constant DUWeatherFrame &f [[buffer(0)]])
{
    const float across = 1.0 - in.uv.x * in.uv.x;
    const float along = smoothstep(0.0, 0.6, in.uv.y) * (1.0 - smoothstep(0.92, 1.0, in.uv.y) * 0.5);
    const float a = across * along * in.opacity * f.light.a;
    return float4(f.light.rgb * a, a * 0.6);
}

/// **A snowflake**: a small soft disc facing the eye, drifting as it falls.
vertex DUWeatherOut duWeatherSnowVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                        constant DUWeatherFrame &f [[buffer(0)]],
                                        depth2d<float> cover [[texture(0)]])
{
    DUWeatherOut out;
    const float3 h = duWeatherHash3(iid ^ 0x68e31da4u);
    const float fall = f.wind.w * (0.7 + 0.6 * h.x);
    const float3 velocity = float3(f.wind.x, -fall, f.wind.z);
    const float3 centre = duWeatherPlace(iid, velocity, f, 0.35);
    const float2 corner = duWeatherCorners[vid] * float2(1, 2) - float2(0, 1);
    const float distanceToEye = distance(centre, f.eye.xyz);
    const float size = max(f.shape.w * (0.6 + 0.8 * h.y), distanceToEye * f.screen.x * 1.2);
    // Facing the eye: a square across the line of sight.
    const float3 look = normalize(f.eye.xyz - centre);
    float3 right = cross(float3(0, 1, 0), look);
    right = length(right) > 1e-4 ? normalize(right) : float3(1, 0, 0);
    const float3 up = cross(look, right);
    out.position = f.viewProjection * float4(centre + (right * corner.x + up * corner.y) * size, 1.0);
    out.uv = corner;
    const bool covered = centre.y < duWeatherCover(centre, f, cover) - 0.05;
    out.opacity = covered ? 0.0 : duWeatherFade(centre, f);
    if (covered) out.position = float4(0, 0, -1, 1);
    return out;
}

fragment float4 duWeatherSnowFragment(DUWeatherOut in [[stage_in]], constant DUWeatherFrame &f [[buffer(0)]])
{
    const float r = length(in.uv);
    const float a = (1.0 - smoothstep(0.4, 1.0, r)) * in.opacity * f.light.a;
    return float4(f.light.rgb * a, a);
}

/// **A raindrop landing**: a ring spreading on whatever is uppermost near the eye, then gone. Each splash comes back
/// somewhere else every 0.4 s.
vertex DUWeatherOut duWeatherSplashVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                          constant DUWeatherFrame &f [[buffer(0)]],
                                          depth2d<float> cover [[texture(0)]])
{
    DUWeatherOut out;
    const float duration = 0.4;
    const float phase = duWeatherHash(iid * 7u + 3u);
    const float cycle = f.eye.w / duration + phase;
    const uint round = uint(floor(cycle));
    const float life = fract(cycle);
    const float3 h = duWeatherHash3(iid * 131u + round * 7919u);
    const float reach = f.screen.z;
    // **Where it lands is fixed in the world**: a place in a square of the world, the square repeated so the one round
    // the eye holds it — so a splash stays where its drop hit while the eye moves on, and only one at the far edge,
    // already faded, ever moves to the other side.
    const float tile = reach * 2.0;
    const float2 local = h.xy * tile;
    const float2 place = local + tile * floor((f.eye.xz - local) / tile + 0.5);
    float3 at = float3(place.x, f.eye.y, place.y);
    const float radius = distance(place, f.eye.xz);
    at.y = duWeatherCover(at, f, cover);
    const bool none = at.y < f.eye.y - 40.0 || at.y > f.eye.y + 20.0;
    const float size = 0.03 + 0.09 * life;
    const float2 corner = duWeatherCorners[vid] * float2(1, 2) - float2(0, 1);
    out.position = f.viewProjection * float4(at + float3(corner.x, 0.02, corner.y) * size, 1.0);
    out.uv = corner;
    out.opacity = none ? 0.0 : (1.0 - life) * duWeatherFade(at, f) * (1.0 - smoothstep(reach * 0.6, reach, radius));
    if (none) out.position = float4(0, 0, -1, 1);
    return out;
}

fragment float4 duWeatherSplashFragment(DUWeatherOut in [[stage_in]], constant DUWeatherFrame &f [[buffer(0)]])
{
    const float r = length(in.uv);
    const float ring = smoothstep(0.55, 0.85, r) * (1.0 - smoothstep(0.85, 1.0, r));
    const float a = ring * in.opacity * f.light.a * 0.8;
    return float4(f.light.rgb * a, a * 0.6);
}
