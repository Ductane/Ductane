//
//  DuctaneWeather.h
//  Ductane
//
//  **What the weather, the wind and the seasons do to a game's own surfaces** — snow lying on what faces the sky, dust
//  settled in a storm, wet ground and puddles, footprints in snow and mud, leaves turning and falling, props swaying in the
//  wind, the clouds' shadows and the volumetric fog over all of it. The engine draws the sky, the clouds, the rain and the
//  fog volume itself (`SkyPass`, `CloudPass`, `WeatherRenderer`, `VolumetricFog`); a game's props and ground are drawn by
//  the game's own shaders, which call these.
//
//  **Include it from a game's `.metal` files** — `#include "DuctaneWeather.h"` — with this folder on the Metal compiler's
//  header search path (Xcode: `MTL_HEADER_SEARCH_PATHS`, `…/Ductane/Sources/Ductane/ShaderHeaders`). Everything
//  here is `static`, so it is compiled into the game's own library and inlined into its shaders: these run for every pixel
//  of the world, where a call into a dynamic library would cost more than the work.
//
//  **One block of uniforms carries the frame's weather**: `DUWeatherSurface`, written each frame by Swift's
//  `WeatherSurface` — put it in the game's own frame uniforms (it is all `float4` and `float4x4`, so it needs no padding)
//  and hand it to these functions. Textures and buffers are the game's to bind where it likes: the weather's cover
//  (`WeatherCover`), the clouds' coverage map (`CloudPass.coverageMap`), the prints and their cells (`FootprintGrid`), the
//  fog volume (`VolumetricFog.Drawn.volume`), and any field over the ground (`duGroundField`).
//

#ifndef DUCTANE_WEATHER_H
#define DUCTANE_WEATHER_H

#include <metal_stdlib>

using namespace metal;

/// **The frame's weather, for a game's surfaces** — Swift's `WeatherSurface`, field for field.
struct DUWeatherSurface {
    /// Lying snow (`Weather.lyingSnow`): x how much, 0…1; y how deep on the ground, metres, 0 for the layer alone; z 1 when
    /// the cover is drawn; w its texels a side.
    float4   snow;
    /// What is overhead (`WeatherCover`): world to its clip space; and x its top, y its depth range.
    float4x4 cover;
    float4   coverTop;
    /// Footprints (`FootprintGrid`): x, y the grid's corner (x and z); z a cell's size, metres. Then x 1 when there are
    /// prints to look for, y cells a side.
    float4   prints;
    float4   printGrid;
    /// Wet ground (`Weather.wetness`, `puddles`): x how wet surfaces are, y how full the puddles are, z how hard it rains
    /// now (0 in snow), w the weather's clock, seconds, wrapped.
    float4   wet;
    /// Fall colors (`FallColors`): the three colours trees turn to, linear.
    float4   fallColours[3];
    /// x how thick fallen leaves lie under turning trees (`FallColors.litter`), y 1 when the field of where they lie is
    /// bound, z how far the litter has gone brown.
    float4   fallLitter;
    /// The clouds (`CloudLayer`), for their shadows: x coverage, y darkness, z base, w thickness; then where they are on
    /// their pattern (`CloudLayer.motion`). Coverage 0 for none.
    float4   clouds;
    float4   cloudMotion;
    /// Dust settled in a dust storm (`Weather.dustColour`, `Settings.dust`): rgb its colour, a how much.
    float4   dust;
    /// The fog volume (`VolumetricFog.Lookup.parameters`): x 1 with a volume, y the first slice's near edge, z
    /// log(far / near), w slices. Hand it to `duFogApply`.
    float4   fogVolume;
};

/// A cell's own random number, 0…1.
static inline float duCellHash(float2 q) { return fract(sin(dot(q, float2(127.1, 311.7))) * 43758.5453); }

/// Smooth value noise, 0…1, one cell a unit.
static inline float duValueNoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(duCellHash(i), duCellHash(i + float2(1, 0)), u.x),
               mix(duCellHash(i + float2(0, 1)), duCellHash(i + float2(1, 1)), u.x), u.y);
}

/// **The clouds' shadow on a point**, 0…1 of the sun let through — Ductane's `CloudLayer.shadow(at:light:)`: the
/// coverage of their layer over the point along the light, read from the engine's coverage map (`duCoverage`), in patches
/// under broken cloud and fading under a sky nearly covered, which the weather has already dimmed.
static inline float duCloudShadow(float3 p, float3 l, constant DUWeatherSurface &weather, texture2d<float> map) {
    float coverage = weather.clouds.x;
    if (coverage <= 0.0) return 1.0;
    constexpr sampler wrap(filter::linear, address::repeat);
    float mid = weather.clouds.z + weather.clouds.w * 0.4;
    // Where the point under them is on their pattern — `CloudLayer.place(_:)`: turned to the way they travel, moved back
    // by how far they have come.
    float2 under = p.xz + l.xz / max(l.y, 0.08) * (mid - p.y);
    float2 q = float2(dot(under, float2(-weather.cloudMotion.y, weather.cloudMotion.x)), dot(under, weather.cloudMotion.xy) - weather.cloudMotion.z);
    float spread = map.sample(wrap, q / 61440.0).r;
    float cover = smoothstep(1.0 - coverage - 0.12, 1.0 - coverage + 0.12, spread);
    return 1.0 - 0.75 * (1.0 - 0.8 * smoothstep(0.6, 1.0, coverage)) * cover;
}

/// **How much snow lies on a point**, 0…1 (2026-11-15, the owner's choice: every face that looks at the sky). More of a
/// face is white the more snow lies — a little snow only on the flattest tops, a lot on anything not steeper than a
/// wall — its edge broken by two scales of noise, and **none on what is under something**: the weather's cover, drawn
/// from straight above, says how high the uppermost thing is over each point, and a point well under it is a porch, a
/// room or the ground beneath a tree. Past the cover's reach a point is taken as open.
static inline float duSnowOpen(float3 p, constant DUWeatherSurface &weather, depth2d<float> cover) {
    if (weather.snow.z < 0.5) return 1;
    float4 c = weather.cover * float4(p, 1);
    float2 uv = float2(c.x * 0.5 + 0.5, 0.5 - c.y * 0.5);
    if (any(uv < 0.0) || any(uv >= 1.0)) return 1;
    // **One filtered read**: the heights of the four nearest texels blended, so the edge of the bare ground under a tree
    // is soft rather than a staircase of 12.5 cm squares — and one read, not four, on every fragment that faces up.
    constexpr sampler heights(filter::linear, address::clamp_to_edge);
    float d = cover.sample(heights, uv);
    if (d <= 0) return 1;
    float top = weather.coverTop.x - (1.0 - d) * weather.coverTop.y;
    return smoothstep(-0.45, -0.15, p.y - top);
}

/// The snow's grain at `p`, 0…1 — what breaks its edge up and lays a little of it in patches.
static inline float duSnowGrain(float3 p) {
    return duValueNoise(p.xz * 1.9) * 0.55 + duValueNoise(p.xz * 0.41 + 7.0) * 0.45;
}

/// How much of a face looking along `n` takes the snow, open sky or not, with the grain where it is.
static inline float duSnowFacing(float grain, float3 n, float amount) {
    // How far a face must look up for snow to stay on it: at full, anything but a wall; at a little, only the flat.
    float facing = n.y + (grain - 0.5) * 0.35;
    float needs = mix(0.92, 0.05, amount);
    // **A little snow lies in patches**: under about 0.4 the grain decides where, so a dusting is not a white sheet.
    float patches = saturate((amount * 2.5 - (1.0 - grain)) / 0.3);
    return smoothstep(needs, needs + 0.18, facing) * patches;
}

static inline float duSnowOn(float3 p, float3 n, constant DUWeatherSurface &weather, depth2d<float> cover) {
    if (weather.snow.x <= 0 || n.y < -0.2) return 0;
    float facing = duSnowFacing(duSnowGrain(p), n, weather.snow.x);
    // The cover is read only for what would hold snow: a wall or the underside of a leaf never asks.
    return facing > 0 ? facing * duSnowOpen(p, weather, cover) : 0;
}

/// Snow's colour, linear: a little blue.
constant float3 duSnowColour = float3(0.82, 0.86, 0.92);

/// **A field over the ground, read at `xz`**: one float a ground point — how ready the ground is to hold a puddle
/// (``WorldFile/Ground/puddles``), how thick fallen leaves lie — read between its points as the ground's heights are.
/// `ground` is the grid: x half its size, y its spacing (metres), z points a side; 0 there for none.
static inline float duGroundField(float2 xz, float4 ground, device const float *field) {
    int n = int(ground.z);
    if (n < 2) return 0;
    float2 g = (xz + ground.x) / ground.y;
    if (any(g < 0) || any(g > float(n - 1))) return 0;
    int2 c = min(int2(g), int2(n - 2));
    float2 f = g - float2(c);
    int i = c.y * n + c.x, j = i + n;
    return mix(mix(field[i], field[i + 1], f.x), mix(field[j], field[j + 1], f.x), f.y);
}

/// **Rain's rings on a puddle**: the slope of the rings round `p` at `t` — a ring in each 0.4 m cell, each starting at its
/// own moment, growing and fading.
static inline float2 duRainRings(float2 p, float t) {
    const float cell = 0.4;
    float2 g = floor(p / cell), slope = 0;
    for (int i = 0; i < 9; i++) {
        float2 c = g + float2(float(i % 3) - 1.0, float(i / 3) - 1.0);
        float2 centre = (c + 0.2 + 0.6 * float2(duCellHash(c), duCellHash(c + 31.7))) * cell;
        float life = fract(t * 0.9 + duCellHash(c + 7.3));
        float2 d = p - centre;
        float r = length(d);
        float s = r - life * 0.32;
        float bump = exp(-s * s * 900.0) * (1.0 - life) * cos(s * 50.0);
        if (r > 1e-4) slope += d / r * bump;
    }
    return slope;
}

/// One print — Ductane's `FootprintGrid.Instance`.
struct DUFootprint {
    float4 placed;   // x, z, heading (radians, 0 along −z), side (−1 left, 1 right)
    float4 look;     // shape (0 boot, 1 bare), strength, length, width (metres)
    float4 height;   // x how high the foot stood
};

/// How far `q` is inside an ellipse at `c` with radii `r`: above 0 inside.
static inline float duInsideEllipse(float2 q, float2 c, float2 r) { return 1.0 - length((q - c) / r); }

/// **A print's shape**, 0…1, in its own terms — across −1…1 of a right foot, along −1 heel … 1 toe. **Ductane's
/// `FootprintTrail.Shape.press(at:)`, term for term.**
static inline float duFootprintShape(float2 q, float shape) {
    if (shape < 0.5) {
        float sole = duInsideEllipse(q, float2(0.05, 0.38), float2(0.95, 0.62));
        float heel = duInsideEllipse(q, float2(0.0, -0.62), float2(0.78, 0.36));
        float arch = duInsideEllipse(q, float2(-0.12, -0.1), float2(0.62, 0.42));
        float tread = fract((q.y + 1.0) * 5.0) < 0.5 ? 0.82 : 1.0;
        return smoothstep(0.0, 0.12, max(max(sole, heel), arch * 0.8)) * tread;
    }
    float ball = duInsideEllipse(q, float2(0.05, 0.3), float2(0.85, 0.42));
    float sole = duInsideEllipse(q, float2(0.2, -0.25), float2(0.55, 0.5));
    float heel = duInsideEllipse(q, float2(0.05, -0.68), float2(0.6, 0.3));
    float toes = 0;
    for (int i = 0; i < 5; i++) {
        float x = -0.62 + float(i) * 0.3;
        float r = i == 0 ? 0.24 : 0.17 - float(i) * 0.012;
        toes = max(toes, duInsideEllipse(q, float2(x, 0.82 - abs(float(i) - 0.5) * 0.04), float2(r, r * 1.15)));
    }
    return smoothstep(0.0, 0.15, max(max(max(ball, sole), heel), toes));
}

/// **How deeply a foot pressed at `xz`**, 0…1, among the prints in the cell — Ductane's `FootprintGrid`: only
/// prints whose foot stood about as high as `y`, so a print in the snow on a deck shows there and not on the roof over it.
static inline float duFootprintPress(float2 xz, float y, constant DUWeatherSurface &weather, device const DUFootprint *prints,
                            device const uint *cells) {
    int n = int(weather.printGrid.y);
    float2 g = (xz - weather.prints.xy) / weather.prints.z;
    if (any(g < 0.0) || any(g >= float(n))) return 0;
    int c = int(g.y) * n + int(g.x), offsets = n * n + 1;
    float deepest = 0;
    for (uint k = cells[c]; k < cells[c + 1]; k++) {
        DUFootprint p = prints[cells[offsets + k]];
        if (abs(y - p.height.x) > 0.6) continue;
        float2 along = float2(sin(p.placed.z), -cos(p.placed.z)), across = float2(-along.y, along.x);
        float2 d = xz - p.placed.xy;
        float2 q = float2(dot(d, across) / (p.look.w * 0.5) * p.placed.w, dot(d, along) / (p.look.z * 0.5));
        if (abs(q.x) > 1.3 || abs(q.y) > 1.2) continue;
        deepest = max(deepest, duFootprintShape(q, p.look.x) * p.look.y);
    }
    return deepest;
}

/// **A footprint at `p`**: x how deep, 0…1; y and z how its sides slope along x and z, per metre — what a dent shades by,
/// from the press a centimetre either way.
static inline float3 duFootprintAt(float3 p, constant DUWeatherSurface &weather, device const DUFootprint *prints, device const uint *cells) {
    if (weather.printGrid.x < 0.5) return 0;
    float press = duFootprintPress(p.xz, p.y, weather, prints, cells);
    if (press <= 0) return 0;
    const float e = 0.01;
    float dx = duFootprintPress(p.xz + float2(e, 0), p.y, weather, prints, cells) - duFootprintPress(p.xz - float2(e, 0), p.y, weather, prints, cells);
    float dz = duFootprintPress(p.xz + float2(0, e), p.y, weather, prints, cells) - duFootprintPress(p.xz - float2(0, e), p.y, weather, prints, cells);
    return float3(press, dx / (2.0 * e), dz / (2.0 * e));
}

/// **How trodden the ground round `p` is**, 0…1: prints within a third of a metre, sampled on a 3×3 — where deep snow is
/// pressed down into a path. A print is smaller than the ground's grid, so one alone barely moves it; many make a trench.
static inline float duTrodden(float3 p, constant DUWeatherSurface &weather, device const DUFootprint *prints, device const uint *cells) {
    if (weather.printGrid.x < 0.5) return 0;
    float sum = 0;
    for (int i = 0; i < 9; i++) {
        float2 o = float2(float(i % 3) - 1.0, float(i / 3) - 1.0) * 0.15;
        sum += duFootprintPress(p.xz + o, p.y, weather, prints, cells);
    }
    return saturate(sum / 9.0 * 2.0);
}

/// Ductane's `FallColors.brownColour` and `strawColour`.
constant float3 duFallBrown = float3(0.30, 0.15, 0.05);

constant float3 duFallStrawColour = float3(0.62, 0.48, 0.22);

/// **A tree's own two numbers, 0…1, from where it stands**: how early it turns, and which colour — Ductane's
/// `FallColors.seed(x:z:)`, bit for bit.
static inline float2 duFallSeed(float2 xz) {
    uint qx = as_type<uint>(int(floor(xz.x * 4.0))), qz = as_type<uint>(int(floor(xz.y * 4.0)));
    uint h = (qx * 73856093u) ^ (qz * 19349663u);
    h = h * 747796405u + 2891336453u;
    h = ((h >> ((h >> 28) + 4u)) ^ h) * 277803737u;
    h = (h >> 22) ^ h;
    return float2(float(h & 0xFFFFu), float(h >> 16)) / 65535.0;
}

/// A tree's leaves at its point in the year: how turned, how many left, and the colour they turn to — `FallColors`'
/// `turn`, `leaves`, `brown` and `colour(pick:)`, term for term.
struct DUFallLeaf { float turn; float leaves; float3 colour; };

static inline DUFallLeaf duFallLeaf(float2 root, float4 foliage, constant DUWeatherSurface &weather) {
    float2 seed = duFallSeed(root);
    float t = foliage.y + (seed.x - 0.5) * 0.36;
    DUFallLeaf f;
    f.turn = smoothstep(0.45, 1.15, t) * (1.0 - smoothstep(2.55, 2.85, t)) * foliage.w;
    f.leaves = foliage.z > 0.5 ? saturate(1.0 - smoothstep(1.15, 1.75, t) + smoothstep(2.6, 3.0, t)) : 1.0;
    float brown = smoothstep(1.3, 1.9, t) * (1.0 - smoothstep(2.55, 2.85, t));
    float p = seed.y * 2.0;
    float3 c = p < 1.0 ? mix(weather.fallColours[0].rgb, weather.fallColours[1].rgb, p)
                       : mix(weather.fallColours[1].rgb, weather.fallColours[2].rgb, p - 1.0);
    f.colour = mix(c, duFallBrown, brown);
    return f;
}

/// How far grass has gone to straw — `FallColors.straw`.
static inline float duFallStraw(float2 root, float4 foliage) {
    float t = foliage.y + (duFallSeed(root).x - 0.5) * 0.36;
    return smoothstep(0.6, 1.3, t) * (1.0 - smoothstep(2.7, 3.1, t)) * foliage.w;
}

/// **How much a surface of a prop that turns is leaf**, 0…1, by how green it is — a canopy's green, never its bark's
/// brown. **Never by being cut out**: a pack's tree often draws bark and leaves from one cut-out sheet, and taking every
/// cut-out pixel for leaf took the trunks away in winter. A cut-out leaf card is a little readier to count.
static inline float duGreenLeaf(float3 albedo, bool cutOut) {
    // **By hue, not by green alone being the largest**: an olive reed or bush, a fern's dark green and a yellow-green leaf
    // all count — green only a little over red is still a leaf's — while bark's brown and a birch's grey do not.
    float green = (albedo.g - max(albedo.r * 0.85, albedo.b * 1.2)) / max(albedo.g, 1e-3);
    return cutOut ? smoothstep(0.0, 0.12, green) : smoothstep(0.03, 0.15, green);
}

/// **Whether a pixel is leaf, for leaves falling**: green, or — on a cut-out sheet — a leaf's edge, which left behind hung
/// round bare branches as a cloud of specks: what is partly see-through (bark on a sheet is solid), and what is dark
/// unless it is bark's brown. Asked only while leaves fall; colouring asks ``greenLeaf`` alone, as every leaf pixel of a
/// forest pays for it.
static inline float duLeafness(float3 albedo, bool cutOut, float alpha = 1.0) {
    float green = duGreenLeaf(albedo, cutOut);
    if (!cutOut) return green;
    float brown = smoothstep(0.1, 0.3, (albedo.r - albedo.g) / max(albedo.r, 1e-3));
    float dark = 1.0 - smoothstep(0.02, 0.07, dot(albedo, float3(0.2126, 0.7152, 0.0722)));
    return max(max(green, dark * (1.0 - brown)), 1.0 - smoothstep(0.85, 0.98, alpha));
}

/// **The colour a leaf turns to, for each unit of its own brightness** (vertex stage, once a tree): `colour` scaled so a
/// leaf keeps its own light and dark, a little brighter, as turned leaves are.
static inline float3 duTurnScale(float3 colour) {
    return colour * 2.0 / max(dot(colour, float3(0.2126, 0.7152, 0.0722)), 1e-3);
}

/// A leaf's colour turned by `amount` toward a ``turnScale`` colour.
static inline float3 duTurnedTo(float3 albedo, float3 scaled, float amount) {
    float3 turned = min(scaled * dot(albedo, float3(0.2126, 0.7152, 0.0722)), 1.0);
    return mix(albedo, turned, amount);
}

/// **Whether a leaf here has fallen**, with `leaves` of them left: in clumps a fifth of a metre across, each its own
/// moment, so a tree thins rather than fades.
static inline bool duFallen(float3 p, float leaves) {
    if (leaves >= 1.0) return false;
    if (leaves <= 0.0) return true;
    uint3 q = as_type<uint3>(int3(floor(p * 5.0)));
    uint h = (q.x * 73856093u) ^ (q.y * 19349663u) ^ (q.z * 83492791u);
    h = h * 747796405u + 2891336453u;
    h ^= h >> 16;
    return float(h & 0xFFFFu) / 65535.0 >= leaves;
}

/// A corner's own number, 0…1, for ``shed``'s noise.
static inline float duShedHash(int3 c) {
    uint3 q = as_type<uint3>(c);
    uint h = (q.x * 73856093u) ^ (q.y * 19349663u) ^ (q.z * 83492791u);
    h = h * 747796405u + 2891336453u;
    h ^= h >> 16;
    return float(h & 0xFFFFu) / 65535.0;
}

/// **Whether a tree's leaf here has fallen** (vertex stage; a submesh that is leaves alone — `leafCard`): smooth noise
/// a metre and a half across sets each place's moment, so a card's corners, a few tens of centimetres apart, fall
/// together, and a fallen corner is given no position (``duFallenPosition``), which culls its triangles. A thinning tree
/// then draws less, not more: dropped pixel by pixel, its holes let the forest behind show and cost a late-autumn frame
/// up to 14 ms.
static inline bool duShed(float3 p, float leaves) {
    if (leaves >= 1.0) return false;
    if (leaves <= 0.0) return true;
    float3 g = p / 1.5, f = fract(g);
    int3 c = int3(floor(g));
    float3 u = f * f * (3.0 - 2.0 * f);
    float n = mix(mix(mix(duShedHash(c), duShedHash(c + int3(1, 0, 0)), u.x),
                      mix(duShedHash(c + int3(0, 1, 0)), duShedHash(c + int3(1, 1, 0)), u.x), u.y),
                  mix(mix(duShedHash(c + int3(0, 0, 1)), duShedHash(c + int3(1, 0, 1)), u.x),
                      mix(duShedHash(c + int3(0, 1, 1)), duShedHash(c + int3(1, 1, 1)), u.x), u.y), u.z);
    // Value noise gathers round a half; spread back out so `leaves` is about the share left.
    return smoothstep(0.25, 0.75, n) >= leaves;
}

/// A position no triangle is drawn with: a triangle with a corner here is culled whole.
constant float4 duFallenPosition = float4(NAN, NAN, NAN, NAN);

/// How much of a turning tree's leaves are left where it stands — `FallColors.leaves`; 1 for anything else.
static inline float duLeavesLeft(float2 root, float4 foliage) {
    if (foliage.x < 0.5 || foliage.x > 1.5 || foliage.z < 0.5) return 1.0;
    float t = foliage.y + (duFallSeed(root).x - 0.5) * 0.36;
    return saturate(1.0 - smoothstep(1.15, 1.75, t) + smoothstep(2.6, 3.0, t));
}

/// **A prop moved by the wind** (vertex stage; Ductane's `Sway`, `Weather.foliageWind`): `sway` is the prop's (x 1 a tree,
/// 2 a plant, 3 cloth, 4 cloth fastened to the rest — then y its hem's height and z its own — 0 still; y its height, z half its width, metres in its own space), `wind` the frame's (x, z the way
/// it blows, y how hard, w seconds, wrapped hourly). A tree bends from its root, more toward the top, swaying a little even in still air, its leaf cards (`leafCard`)
/// fluttering; a plant bends harder, all of it, in waves across a field; cloth ripples and billows, the more the further it
/// hangs from its pole or wall. Each copy gusts at its own moment, from where it stands.
static inline float3 duSwayed(float3 world, float3 root, float scale, float4 sway, float4 wind, bool leafCard) {
    float kind = sway.x;
    if (kind < 0.5) return world;
    float3 along = float3(wind.x, 0, wind.z);
    // The clock wraps every hour (`Weather.foliageWind(at:)`), so every wave turns a whole number of times in an hour —
    // at any other rate each tree twitched once an hour as the clock wrapped.
    float strength = wind.y, t = wind.w * (2.0 * M_PI_F / 3600.0);
    float phase = root.x * 0.37 + root.z * 0.23;
    float gust = 0.6 + 0.4 * sin(t * 516.0 + phase * 0.3) * sin(t * 212.0 + phase);
    float height = max(sway.y * scale, 0.3);
    float rise = max(world.y - root.y, 0.0);
    float h = saturate(rise / height);
    float3 offset = 0;
    if (kind < 1.5) {
        float bend = h * h * height * (0.005 + 0.07 * strength * gust);
        float idle = sin(t * 516.0 + phase) * h * h * height * (0.006 + 0.025 * strength);
        offset = along * bend + float3(along.z, 0, -along.x) * idle;
        if (leafCard) {
            float f = sin(t * 4011.0 + dot(world, float3(3.1, 2.7, 4.3))) * (0.015 + 0.06 * strength) * h;
            offset += float3(f, f * 0.4, -f * 0.7);
        }
    } else if (kind < 2.5) {
        float k = pow(h, 1.5) * height;
        float wave = sin(t * 1604.0 + dot(world.xz, float2(0.6, 0.4)) * 1.3 + phase);
        offset = along * k * (0.04 + 0.35 * strength * gust + (0.06 + 0.25 * strength) * wave);
    } else if (kind > 3.5) {
        // **Cloth fastened to the rest of the prop** (2026-11-21) — a wagon's canvas: held at its hem (`sway.y` above the
        // root), billowing and rippling more the higher it rises over its `sway.z` metres.
        float u = saturate((world.y - root.y - sway.y * scale) / max(sway.z * scale, 0.1));
        float hold = sin(u * M_PI_F * 0.5);
        float ripple = sin(t * 2865.0 + dot(world, float3(1.7, 2.3, 1.1)) * 3.0) * (0.008 + 0.06 * strength * gust);
        float billow = 0.004 + 0.1 * strength * gust;
        offset = (along * (billow + ripple) + float3(0, ripple * 0.5, 0)) * hold;
    } else {
        float out_ = saturate(length(world.xz - root.xz) / max(sway.z * scale, 0.2));
        float ripple = sin(t * 2865.0 + dot(world, float3(1.7, 2.3, 1.1)) * 2.0) * (0.02 + 0.1 * strength * gust);
        float billow = (0.02 + 0.25 * strength * gust);
        offset = (along * (billow + ripple) + float3(0, ripple * 0.6, 0)) * out_;
    }
    // Bent, not stretched: the top comes down a little as it leans.
    offset.y -= dot(offset.xz, offset.xz) / (2.0 * max(rise, 0.5));
    return world + offset;
}

/// **A tree's numbers through the year, once a copy** (vertex stage): the colour its leaves turn to and how far — straw
/// and how far for grass — and how much of its leaves it has. Nothing for a prop the season leaves alone.
///
/// **`foliage` is the prop's** (the same vector `duLeavesLeft` takes): x what the season does to it (`Foliage`: 1 a tree
/// that turns, 2 grass, 0 neither); y where foliage is in its year (`FallColors.phase(yearPosition:southern:)`, 0
/// midsummer … 2 midwinter … 4); z 1 when trees stand bare in winter (`FallColors.bareInWinter`); w how far leaves turn
/// (`FallColors.extent`). All zero through high summer (`FallColors.changesAnything`), when nothing changes.
static inline void duSeasonOf(float2 root, float4 foliage, constant DUWeatherSurface &weather,
                     thread float4 &colour, thread float &leaves) {
    colour = float4(0);
    leaves = 1;
    if (foliage.x < 0.5) return;
    if (foliage.x < 1.5) {
        DUFallLeaf f = duFallLeaf(root, foliage, weather);
        colour = float4(duTurnScale(f.colour), f.turn);
        leaves = f.leaves;
    } else {
        colour = float4(duTurnScale(duFallStrawColour), duFallStraw(root, foliage));
    }
}

/// **A prop's surface through the year**: a turning tree's leaves coloured, or gone; grass gone straw. False when this
/// pixel's leaf has fallen.
static inline bool duThroughTheYear(thread float3 &albedo, float alpha, float3 p, float4 colour, float leaves, bool cutOut,
                             bool leafCard) {
    if (colour.a <= 0.0 && leaves >= 1.0) return true;
    // Leaves alone shrink away in the vertex stage (``shed``); only leaves sharing a submesh with bark drop here.
    if (leaves < 1.0 && !leafCard && duLeafness(albedo, cutOut, alpha) > 0.5 && duFallen(p, leaves)) return false;
    if (colour.a > 0.0) albedo = duTurnedTo(albedo, colour.rgb, colour.a * duGreenLeaf(albedo, cutOut));
    return true;
}


// MARK: - A surface under its weather

/// What `duWeathered` made of a surface: its colour and shading normal under the weather, and how much snow, wet, puddle
/// and running water there is on it — for its shine (`duWetRoughness`, `duWetSheen`).
struct DUWeathered {
    float3 albedo;
    float3 normal;
    float snow;
    float wetness;
    float puddle;
    float running;
    /// How glossy the wet makes it: a soaked surface, running water or a puddle.
    float gloss;
};

/// **Everything the weather lays on a surface, in order**: fallen leaves on the ground under turning trees, lying snow,
/// settled dust, wet surfaces, puddles and running water, and footprints in snow and soft ground — given the surface's
/// colour and shading normal as its material has them, its normal as built (`faceNormal`, which snow and wet lie by), and
/// where it is. `ground` is true for the ground (litter and puddles lie only there); `settles` false for what moves
/// through the world — a player, a creature, a held weapon — on which none of it settles. `soft` is how soft the ground is
/// here, 0…1 (`WorldFile.Ground.softness`), where footprints show without snow. `groundGrid` is `duGroundField`'s grid;
/// `puddles` and `litter` its fields — the export's `game/ground.puddles`, and how thick fallen leaves lie.
static inline DUWeathered duWeathered(float3 albedo, float3 n, float3 faceNormal, float3 worldPosition, bool ground, bool settles,
                               float soft, constant DUWeatherSurface &weather, float4 groundGrid, depth2d<float> cover,
                               device const DUFootprint *prints, device const uint *cells, device const float *puddles,
                               device const float *litterField) {
    float4 grid = groundGrid;
    // **Fallen leaves on the ground** under turning trees: in drifts, each leaf-sized patch its own colour, browning
    // through winter, under any snow.
    if (ground && weather.fallLitter.y > 0.5 && weather.fallLitter.x > 0) {
        float2 p = worldPosition.xz;
        float under = duGroundField(p, grid, litterField);
        if (under > 0) {
            float drift = duValueNoise(p * 0.9) * 0.6 + duValueNoise(p * 3.7 + 11.0) * 0.4;
            float amount = weather.fallLitter.x * smoothstep(0.35, 0.75, drift * 0.7 + under * 0.6) * under;
            float pick = duValueNoise(p * 6.0 + 3.0) * 2.0;
            float3 c = pick < 1.0 ? mix(weather.fallColours[0].rgb, weather.fallColours[1].rgb, pick)
                                  : mix(weather.fallColours[1].rgb, weather.fallColours[2].rgb, pick - 1.0);
            c = mix(c, duFallBrown, max(weather.fallLitter.z, duValueNoise(p * 11.0) * 0.5));
            albedo = mix(albedo, c * (0.75 + 0.5 * duValueNoise(p * 23.0)), amount * 0.9);
        }
    }
    // **Lying snow** over whatever is here, on what faces the sky; it lies on the face as built, lit a little more
    // from above.
    float snow = settles ? duSnowOn(worldPosition, faceNormal, weather, cover) : 0;
    if (snow > 0) {
        albedo = mix(albedo, duSnowColour, snow);
        n = normalize(mix(n, float3(0, 1, 0), snow * 0.5));
    }
    // **Dust settled** in a dust storm (2026-11-16): a drift of the dust's colour over what faces up and is open to the sky,
    // patchy, under any snow.
    if (settles && weather.dust.a > 0) {
        float open = duSnowOpen(worldPosition, weather, cover);
        float facing = smoothstep(0.45, 0.9, faceNormal.y);
        float drift = smoothstep(0.25, 0.7, duValueNoise(worldPosition.xz * 1.7) * 0.6 + duSnowGrain(worldPosition) * 0.4);
        albedo = mix(albedo, weather.dust.rgb, weather.dust.a * facing * open * drift * (1.0 - snow));
    }
    // **Wet ground** (2026-11-16): what faces the sky darker and shining while wet, dry under cover; puddles filling the
    // ground's hollows to the weather's level, smooth and rippled by rain; water running down slopes while it rains.
    float wetness = 0, puddle = 0, running = 0;
    if (settles && (weather.wet.x > 0 || weather.wet.y > 0)) {
        float open = duSnowOpen(worldPosition, weather, cover);
        wetness = weather.wet.x * open * mix(0.35, 1.0, saturate(faceNormal.y)) * (1.0 - snow);
        albedo *= mix(1.0, 0.55, wetness);
        if (ground && weather.wet.y > 0) {
            float field = duGroundField(worldPosition.xz, grid, puddles) + (duSnowGrain(worldPosition) - 0.5) * 0.18;
            float level = 1.0 - weather.wet.y;
            puddle = smoothstep(level, level + 0.06, field) * open * (1.0 - snow);
            if (puddle > 0) {
                albedo = mix(albedo, albedo * 0.3, puddle);
                float2 rings = weather.wet.z > 0 ? duRainRings(worldPosition.xz, weather.wet.w) * weather.wet.z * 0.6 : float2(0);
                n = normalize(mix(n, normalize(float3(-rings.x, 1.0, -rings.y)), puddle));
            }
        }
        if (weather.wet.z > 0 && faceNormal.y < 0.97 && faceNormal.y > -0.2 && open > 0.5) {
            // Down the face, and across it: streaks along the way water runs, moving down.
            float3 down = float3(0, -1, 0) - faceNormal * dot(float3(0, -1, 0), faceNormal);
            if (length(down) > 1e-3) {
                down = normalize(down);
                float3 across = normalize(cross(down, faceNormal));
                float streak = duValueNoise(float2(dot(worldPosition, across) * 9.0, dot(worldPosition, down) * 1.2 - weather.wet.w * 1.8));
                running = smoothstep(0.66, 0.8, streak) * weather.wet.z * saturate((1.0 - faceNormal.y) * 2.5) * (1.0 - snow);
                albedo *= 1.0 - 0.25 * running;
            }
        }
    }

    // **Footprints, in snow and soft ground, on what faces up** (Ductane's `FootprintGrid`): a dent shaded by its
    // sides' slope — deeper in snow than in mud — and a little darker, compacted snow greyer and pressed mud wetter.
    float takes = settles ? max(snow, soft) * smoothstep(0.55, 0.8, faceNormal.y) : 0;
    if (takes > 0) {
        float3 print = duFootprintAt(worldPosition, weather, prints, cells);
        if (print.x > 0) {
            float deep = mix(0.03, 0.12, snow);
            n = normalize(n + float3(print.y, 0, print.z) * deep * takes);
            // Pressed snow is packed and shaded, a little blue; pressed mud is wet and dark.
            float3 pressed = mix(albedo * 0.62, albedo * float3(0.70, 0.76, 0.86), snow);
            albedo = mix(albedo, pressed, print.x * takes);
        }
    }

    DUWeathered w;
    w.albedo = albedo;
    w.normal = n;
    w.snow = snow;
    w.wetness = wetness;
    w.puddle = puddle;
    w.running = running;
    // Wet is glossy: a soaked surface toward 0.15, a puddle toward a mirror.
    w.gloss = max(max(wetness * 0.8, running), puddle);
    return w;
}

/// **A wet surface's roughness**: its own, toward 0.15 as it soaks, toward a mirror in a puddle.
static inline float duWetRoughness(float roughness, DUWeathered w) {
    return clamp(mix(roughness, w.puddle > 0.5 ? 0.06 : 0.15, w.gloss), 0.05, 1.0);
}

/// **How much of the sky a wet surface reflects**, by Schlick's Fresnel — more at a glance, a puddle most: multiply the
/// sky's light along `reflect(-v, n)` by it, where `w.gloss` is above 0. A puddle is a mirror for the sky more than
/// physics says — what reads as water from above, as every game paints it.
static inline float duWetSheen(float3 n, float3 v, DUWeathered w) {
    float fresnel = 0.02 + 0.98 * pow(1.0 - saturate(dot(n, v)), 5.0);
    float mirror = mix(fresnel, 1.0, 0.3);
    return fresnel * (w.wetness * 0.18 + w.running * 0.4) + mirror * w.puddle;
}

// MARK: - Snow on props

/// **Snow built up on a prop** (`SnowCap`): a cap vertex raised in the world by the lying snow's `depth` as it says —
/// `capUV.x` how much, `capUV.y` 0 or `1 + angle / 2π`, the level direction its rim leans out toward by a third of the
/// depth, turned with `model`. Draw the cap's pixels as plain lit snow, and only where `duSnowOpen` is at least 0.4: none
/// where it could not have fallen, under a roof or a tree.
static inline float4 duSnowCapRaise(float4 world, float4x4 model, float2 capUV, float depth) {
    world.y += depth * capUV.x;
    if (capUV.y >= 1.0) {
        float a = (capUV.y - 1.0) * 2.0 * M_PI_F;
        float3 lean = (model * float4(cos(a), 0, sin(a), 0)).xyz;
        lean.y = 0;
        float l = length(lean);
        if (l > 1e-4) world.xyz += lean / l * depth * 0.35;
    }
    return world;
}

// MARK: - Fog

/// **Laying the volume over a surface** — a renderer's surfaces call it last. `lookup` is ``VolumetricFog/Lookup``'s
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

#endif
