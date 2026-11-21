//
//  WorldShaders.metal
//  Ductane
//
//  A world's shaders (`WorldRenderer`): the ground, props and scattered copies lit by the sun through its shadows, the
//  sky and ground's light and the point lights, under the weather (`DuctaneWeather.h`), in the fog; far pictures; snow
//  caps; liquids; water and streams; and an editor's grid.
//
//  Everything is drawn in radiance into the engine's HDR target; the engine tone maps it.
//

#include <metal_stdlib>
using namespace metal;

/// What the weather, the wind and the seasons do to a surface: Ductane's (`ShaderHeaders/`).
#include "DuctaneWeather.h"

/// Must match `FrameUniforms` in WorldRenderer.swift, field for field. All `float4`/`float4x4`, so
/// there is no padding for the two sides to disagree about.
struct FrameUniforms {
    float4x4 viewProjection;
    float4x4 inverseViewProjection;
    float4   cameraPosition;   // xyz; w: 1 while the grid is shown (`WorldRenderer.showsGrid`)
    float4   sunDirection;     // xyz, towards the sun; w: the near plane while water reflects the scene (`GraphicsSettings.reflections`), 0 for the sky alone
    float4   sunColour;        // rgb radiance; w unused
    float4   skyColour;        // rgb, the zenith and the ambient from above
    float4   horizonColour;    // rgb
    float4   groundColour;     // rgb, the ambient from below
    float4   grid;             // x: fade distance, y: centre x, z: centre z, w: half size
    /// The sun's shadows: Ductane's cascades, four of them, world to each one's light clip space.
    float4x4 cascadeViewProjection[4];
    float4   cascadeSplits;
    float4   cascadeBlendStart;
    float4   cascadeDepthBias;
    float4   shadowParams;     // x: one texel of the shadow map, y: 1 when the sun casts, w: 1 when multisampled
    float4   fogParams;        // x: the sky's fog density (Ductane's `DaySky.fogDensity`), 0 for none; y: where it starts; z: the ground's grain (`WorldScene.groundGrain`)
    /// **The weather on the world's surfaces** (Ductane's `WeatherSurface`, read by `DuctaneWeather.h`): lying snow
    /// and what is overhead, footprints, wet ground, fall colors, the clouds' shadows, dust and the fog volume.
    DUWeatherSurface weather;
    /// **The scene's point lights nearest the view** — torches, glowing things (`WorldScene.Light`). x: how many.
    float4   lightCount;
    /// The shown ground, for what is under it (`skyReaching`): x half its size, y its spacing, z points a side, 0 for none.
    float4   ground;
    float4   lightPosition[16]; // xyz; w: reach, metres
    float4   lightColour[16];   // rgb × intensity
};


/// **Whether the weather on surfaces is compiled in** (function constant 0; ``WorldRenderer``'s two sets of surface
/// pipelines). Snow lying, dust, wet ground and puddles, footprints and fallen leaves (`duWeathered`), and snow raising the
/// ground, are a large part of the surface shaders, and **present in a shader they cost a frame whether or not they draw
/// anything**: a GPU keeps fewer pixels in flight for a shader that might need all of it. A wooded 400 m scene's meadow
/// on a clear day went from 16 to 38 ms of GPU as they were added (2026-11-16, measured build by build). So the surfaces are
/// drawn by a set compiled without them whenever the frame's weather lays nothing (``WeatherSurface/laysOnSurfaces``),
/// and by this full set the moment it does. Undefined — a library used without specializing — means compiled in.
constant bool weatherOnSurfacesConstant [[function_constant(0)]];
constant bool weatherOnSurfaces = is_function_constant_defined(weatherOnSurfacesConstant) ? weatherOnSurfacesConstant : true;
/// **Whether the seasons on foliage are compiled in** (function constant 1): leaves turning, thinning and falling, grass
/// going straw (`duSeasonOf`, `duThroughTheYear`, `duShed`) — compiled in only while a scene's calendar is changing its
/// foliage. In and doing nothing, they cost a wooded scene's meadow with no calendar about 5 ms of GPU a frame.
constant bool seasonsOnFoliageConstant [[function_constant(1)]];
constant bool seasonsOnFoliage = is_function_constant_defined(seasonsOnFoliageConstant) ? seasonsOnFoliageConstant : true;

/// **Whether the ground is drawn from its layers' textures** (function constant 2; ``WorldRenderer``'s textured ground
/// pipelines): only the ground's pipeline is made with it, and only drawn with it while a layer has a texture — an untextured
/// ground keeps the painted colours in its vertices and pays nothing for this.
constant bool texturedGroundConstant [[function_constant(2)]];
constant bool texturedGround = is_function_constant_defined(texturedGroundConstant) ? texturedGroundConstant : false;

/// Must match `WorldRenderer.GroundLayerUniforms`: the ground's eight layers as its textured pipeline draws them.
struct GroundLayers {
    /// rgb the layer's colour, linear — what it is drawn as without a texture; w its slice in the arrays, −1 for none.
    float4 colour[8];
    /// x repeats a metre (1 / its tile size); y how strongly its normal map bends the light; zw unused.
    float4 params[8];
};

/// **A textured layer's surface at a point**: colour and height, normal, roughness and occlusion.
struct LayerSample {
    float3 albedo;
    float height;
    float3 normal;
    float roughness;
    float occlusion;
};

/// **A layer's maps from above, with no repeat to be seen** (Inigo Quilez, *Texture Repetition*, technique 3): a smooth
/// noise over the ground picks, patch by patch, one of eight offsets into the texture, and neighbouring patches blend
/// where they meet — the blend leaning toward whichever is darker, as a material's crevices would — so the same tile is
/// never laid out in a grid. Explicit gradients, since the offsets would otherwise break the mip choice at every seam.
static void untiled(texture2d_array<float> albedoMap, texture2d_array<float> surfaceMap, sampler s, uint slice, float2 uv,
                    float2 dx, float2 dy, thread float4 &albedo, thread float4 &surface) {
    float k = duValueNoise(uv * 0.23);
    float l = k * 8.0, f = fract(l);
    float ia = floor(l), ib = ia + 1.0;
    float2 offA = sin(float2(3.0, 7.0) * ia), offB = sin(float2(3.0, 7.0) * ib);
    gradient2d g(dx, dy);
    float4 a1 = albedoMap.sample(s, uv + offA, slice, g), a2 = albedoMap.sample(s, uv + offB, slice, g);
    float t = smoothstep(0.2, 0.8, f - 0.1 * dot(a1.rgb - a2.rgb, float3(1.0)));
    albedo = mix(a1, a2, t);
    surface = mix(surfaceMap.sample(s, uv + offA, slice, g), surfaceMap.sample(s, uv + offB, slice, g), t);
}

/// **One layer, sampled the way its slope wants** (`params.x` repeats a metre): from above on gentle ground, and from the
/// sides too where it steepens — triplanar — so rock on a cliff is not smeared down it. Normals are blended by the UDN
/// method (Ben Golus, *Normal Mapping for a Triplanar Shader*), every map stored with green toward +z. The ground's
/// derivatives come in from outside (`dpdx`, `dpdy`): a layer is sampled only where it is painted, and derivatives taken
/// in a branch some pixels skip are undefined.
static LayerSample sampleLayer(texture2d_array<float> albedoMap, texture2d_array<float> surfaceMap, sampler s, uint slice,
                               float scale, float bend, float3 p, float3 n, float3 dpdx, float3 dpdy) {
    float3 blend = pow(abs(n), float3(4.0));
    blend /= max(blend.x + blend.y + blend.z, 1e-4);
    bool sides = blend.y < 0.97;
    float4 aY, sY;
    untiled(albedoMap, surfaceMap, s, slice, p.xz * scale, dpdx.xz * scale, dpdy.xz * scale, aY, sY);
    LayerSample out;
    float3 tY = float3((sY.xy * 2.0 - 1.0) * bend, 0);
    if (!sides) {
        out.albedo = aY.rgb;
        out.height = aY.a;
        out.normal = normalize(float3(tY.x + n.x, n.y, tY.y + n.z));
        out.roughness = sY.z;
        out.occlusion = sY.w;
        return out;
    }
    gradient2d gX(dpdx.zy * scale, dpdy.zy * scale), gZ(dpdx.xy * scale, dpdy.xy * scale);
    float2 uvX = p.zy * scale, uvZ = p.xy * scale;
    float4 aX = albedoMap.sample(s, uvX, slice, gX), aZ = albedoMap.sample(s, uvZ, slice, gZ);
    float4 sX = surfaceMap.sample(s, uvX, slice, gX), sZ = surfaceMap.sample(s, uvZ, slice, gZ);
    float3 tX = float3((sX.xy * 2.0 - 1.0) * bend, 0), tZ = float3((sZ.xy * 2.0 - 1.0) * bend, 0);
    // UDN: each projection's tangent normal swizzled into the world and added to the surface's.
    float3 wX = float3(n.x, tX.y + n.y, tX.x + n.z);
    float3 wY = float3(tY.x + n.x, n.y, tY.y + n.z);
    float3 wZ = float3(tZ.x + n.x, tZ.y + n.y, n.z);
    out.albedo = aX.rgb * blend.x + aY.rgb * blend.y + aZ.rgb * blend.z;
    out.height = aX.a * blend.x + aY.a * blend.y + aZ.a * blend.z;
    out.normal = normalize(wX * blend.x + wY * blend.y + wZ * blend.z);
    float4 sAll = sX * blend.x + sY * blend.y + sZ * blend.z;
    out.roughness = sAll.z;
    out.occlusion = sAll.w;
    return out;
}

/// **The ground's surface from its painted layers** (`texturedGround`): each layer's weight at the point, read between
/// the four grid points round it from `weights` (eight bytes a point, `WorldGroundWeights`), then — Unity's and Unreal's
/// height blend — sharpened by each layer's height map, so the higher of two layers shows through where they meet: pebbles
/// poke out of the mud rather than fading into it. A layer with no texture is its colour, flat, at mid height.
static LayerSample texturedGroundSurface(float3 p, float3 n, constant FrameUniforms &frame, constant GroundLayers &layers,
                                         device const uchar4 *weights, texture2d_array<float> albedoMap,
                                         texture2d_array<float> surfaceMap) {
    constexpr sampler s(filter::linear, mip_filter::linear, address::repeat, max_anisotropy(16));
    int side = int(frame.ground.z);
    float2 g = clamp((p.xz + frame.ground.x) / frame.ground.y, 0.0, float(side - 1));
    int2 c = min(int2(g), int2(side - 2));
    float2 f = g - float2(c);
    int i00 = c.y * side + c.x, i10 = i00 + 1, i01 = i00 + side, i11 = i01 + 1;
    float4 lo = mix(mix(float4(weights[i00 * 2]), float4(weights[i10 * 2]), f.x),
                    mix(float4(weights[i01 * 2]), float4(weights[i11 * 2]), f.x), f.y) / 255.0;
    float4 hi = mix(mix(float4(weights[i00 * 2 + 1]), float4(weights[i10 * 2 + 1]), f.x),
                    mix(float4(weights[i01 * 2 + 1]), float4(weights[i11 * 2 + 1]), f.x), f.y) / 255.0;
    float w[8] = { lo.x, lo.y, lo.z, lo.w, hi.x, hi.y, hi.z, hi.w };
    float3 dpdx = dfdx(p), dpdy = dfdy(p);
    LayerSample got[8];
    float key[8];
    float top = -1;
    for (int k = 0; k < 8; k++) {
        key[k] = -1;
        if (w[k] < 0.004) continue;
        float slice = layers.colour[k].w;
        if (slice >= 0) {
            got[k] = sampleLayer(albedoMap, surfaceMap, s, uint(slice), layers.params[k].x, layers.params[k].y, p, n,
                                 dpdx, dpdy);
        } else {
            got[k].albedo = layers.colour[k].rgb;
            got[k].height = 0.5;
            got[k].normal = n;
            got[k].roughness = 0.9;
            got[k].occlusion = 1;
        }
        // Height counts for as much as about a third of a layer's weight: enough to break up a soft edge, not to
        // swallow a lightly painted layer.
        key[k] = w[k] + (got[k].height - 0.5) * 0.35;
        top = max(top, key[k]);
    }
    LayerSample out = { float3(0), 0, float3(0), 0, 0 };
    float total = 0;
    for (int k = 0; k < 8; k++) {
        if (key[k] < 0) continue;
        float b = max(key[k] - (top - 0.12), 0.0) * w[k];
        out.albedo += got[k].albedo * b;
        out.normal += got[k].normal * b;
        out.roughness += got[k].roughness * b;
        out.occlusion += got[k].occlusion * b;
        out.height += got[k].height * b;
        total += b;
    }
    if (total <= 0) {
        out.albedo = layers.colour[0].rgb; out.normal = n; out.roughness = 0.9; out.occlusion = 1; out.height = 0.5;
        return out;
    }
    out.albedo /= total;
    out.normal = normalize(out.normal);
    out.roughness /= total;
    out.occlusion /= total;
    out.height /= total;
    // **Broad variation**, a few tens of metres across, so a field is not one tone however well its texture repeats.
    float broad = duValueNoise(p.xz * 0.035) * 0.6 + duValueNoise(p.xz * 0.11 + 31.0) * 0.4;
    out.albedo *= mix(0.86, 1.1, broad);
    return out;
}

/// The season of a copy standing at `root` (`duSeasonOf`) — none where the seasons are compiled out.
static inline void seasonOf(float2 root, float4 foliage, constant DUWeatherSurface &weather, thread float4 &colour,
                            thread float &leaves) {
    colour = float4(0);
    leaves = 1;
    if (seasonsOnFoliage) duSeasonOf(root, foliage, weather, colour, leaves);
}

/// **How much of the sky's light reaches a point, 0…1: none deep under the ground.** A cave's walls and roof are props
/// under ground that runs over them, and lit by the open sky they glowed like daylight however dark the cave was meant
/// to be. The ground over a point is read from the ground's own vertices — holes are drawn as nothing but keep their
/// heights there, so a cut in the ground does not open the sky over what is beneath it. A little light is kept, so a
/// cave with no torch is very dark, not black.
static float skyReaching(float3 p, constant FrameUniforms &frame, device const float *groundVertices) {
    int n = int(frame.ground.z);
    if (n < 2) return 1;
    float2 g = (p.xz + frame.ground.x) / frame.ground.y;
    if (any(g < 0) || any(g > float(n - 1))) return 1;
    int2 c = min(int2(g), int2(n - 2));
    float2 f = g - float2(c);
    int i = (c.y * n + c.x) * 12 + 1, j = i + n * 12;   // a vertex is 12 floats, its height the second
    float over = mix(mix(groundVertices[i], groundVertices[i + 12], f.x), mix(groundVertices[j], groundVertices[j + 12], f.x), f.y);
    return max(1 - smoothstep(0.3, 2.5, over - p.y), 0.05);
}

/// **The full ground at a point, as its own triangles have it** (2026-11-01): position, normal and painted colour,
/// interpolated over the full grid's triangle under `xz` exactly as the rasteriser interpolates them over a full chunk —
/// a cell split from its (x, z) corner to its (x + 1, z + 1) one, as `writeCell` lays it out. A chunk drawn at a coarser
/// level (`WorldGroundDetail`) reads its pixels from here, so its paint, light and shadows are the full ground's and only
/// its outline is coarser — by under half a pixel.
struct GroundPoint {
    float3 position;
    float3 normal;
    float3 colour;
    float soft;
};

static GroundPoint fineGround(float2 xz, constant FrameUniforms &frame, device const float *vertices) {
    int n = int(frame.ground.z);
    float2 g = clamp((xz + frame.ground.x) / frame.ground.y, 0.0, float(n - 1));
    int2 c = min(int2(g), int2(n - 2));
    float2 f = g - float2(c);
    int a = (c.y * n + c.x) * 12, corner = a + n * 12 + 12;   // a vertex is 12 floats: position, normal, uv, colour
    int other;
    float3 w;   // the weights of a, the other corner, and the far corner
    if (f.y >= f.x) { other = a + n * 12; w = float3(1 - f.y, f.y - f.x, f.x); }
    else            { other = a + 12;     w = float3(1 - f.x, f.x - f.y, f.y); }
    GroundPoint p;
    p.position = float3(xz.x, w.x * vertices[a + 1] + w.y * vertices[other + 1] + w.z * vertices[corner + 1], xz.y);
    p.normal = w.x * float3(vertices[a + 3], vertices[a + 4], vertices[a + 5])
             + w.y * float3(vertices[other + 3], vertices[other + 4], vertices[other + 5])
             + w.z * float3(vertices[corner + 3], vertices[corner + 4], vertices[corner + 5]);
    p.colour = w.x * float3(vertices[a + 8], vertices[a + 9], vertices[a + 10])
             + w.y * float3(vertices[other + 8], vertices[other + 9], vertices[other + 10])
             + w.z * float3(vertices[corner + 8], vertices[corner + 9], vertices[corner + 10]);
    p.soft = w.x * vertices[a + 11] + w.y * vertices[other + 11] + w.z * vertices[corner + 11];
    return p;
}

/// **What the point lights add to a surface**: each one's colour, Lambert, falling to nothing at its reach as
/// a light's reach falls off everywhere in the engine.
static float3 pointLighting(float3 p, float3 n, constant FrameUniforms &frame) {
    float3 sum = 0;
    int count = int(frame.lightCount.x);
    for (int i = 0; i < count; i++) {
        float3 d = frame.lightPosition[i].xyz - p;
        float distance = length(d);
        float t = saturate(distance / max(frame.lightPosition[i].w, 0.01));
        float fall = (1 - t) * (1 - t);
        sum += frame.lightColour[i].rgb * fall * saturate(dot(n, d / max(distance, 0.0001)));
    }
    return sum;
}


/// **The world's fog**, as Ductane's `DaySky.fog(atDistance:)` and the game reckon it, so a scene fogs here as
/// it does in a game built from it: exponential-squared toward the horizon colour the sky is drawn with.
///
/// **Counted from where the view looks, not from the eye** (`fogParams.y`, the orbit's distance): looking down on a
/// whole world from three hundred metres up, fog measured from the eye hid all of it. Walking,
/// the orbit is a metre long and this is the game's fog.
///
/// **Then the volume** (2026-11-16, Ductane's `VolumetricFog`): what the air in front sends toward the eye — ground
/// fog, the sun's shafts and the shadows through the haze, lights glowing — added, and what shows through the ground fog
/// kept, by Ductane's `duFogApply`.
static float3 fogged(float3 colour, float3 worldPosition, constant FrameUniforms &frame, texture3d<float> volume) {
    float d = distance(worldPosition, frame.cameraPosition.xyz);
    float density = frame.fogParams.x * max(d - frame.fogParams.y, 0.0);
    colour = mix(colour, frame.horizonColour.rgb, 1.0 - exp(-density * density));
    return duFogApply(colour, worldPosition, d, frame.viewProjection, frame.weather.fogVolume, volume);
}

/// Must match `ObjectUniforms` in WorldRenderer.swift.
struct ObjectUniforms {
    float4x4 model;
    float4x4 normalMatrix;     // upper 3×3 used
    float4   baseColour;
    float4   emissive;         // rgb radiance; w unused
    float4   params;           // x roughness, y metallic, z alpha cutoff (0 draws solid), w: 1 for the ground
    /// **What the season does to it** (Ductane's `Foliage`, `FallColors`): x 1 a tree that turns, 2 grass, 0
    /// neither; y where foliage is in its year (0 midsummer … 4); z 1 when trees stand bare in winter; w how far leaves turn.
    float4   foliage;
    /// **How it moves in the wind** (Ductane's `Sway`): x 1 a tree, 2 a plant, 3 cloth, 0 still; y the prop's height,
    /// z half its width, metres in its own space.
    float4   sway;
    /// **The wind** (`Weather.foliageWind`): x, z the way it blows, y how hard (0 still … 1 a gale), w seconds, wrapped.
    float4   wind;
};

struct VertexIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
    float2 uv       [[attribute(2)]];
};

struct VertexOut {
    float4 position [[position]];
    float3 worldPosition;
    /// **Where the surface rests before the wind moves it** — what decides which of a turning tree's leaves have fallen
    /// (`duFallen`), so a leaf swaying across the pattern does not drop and come back every frame. `worldPosition` on
    /// anything that does not sway.
    float3 restPosition;
    float3 normal;
    float2 uv;
    /// Multiplies the surface's colour: white for a prop, the painted mix for the ground.
    float3 tint;
    /// How soft the ground is here, 0…1 — where footprints show beside snow. None on a prop.
    float soft;
    /// **Its tree through the year** (`seasonOf`), worked out once a copy: rgb the colour its leaves turn to — straw for
    /// grass — a how far; and how much of its leaves it has.
    float4 fallColour [[flat]];
    float fallLeaves [[flat]];
};

/// The ground's vertex: a prop's, plus the colour its painted layers mix to at that point.
struct GroundVertexIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
    float2 uv       [[attribute(2)]];
    float4 colour   [[attribute(3)]];
};



/// One line every metre and a stronger one every ten, antialiased by their screen-space width, faded
/// with distance so the far grid does not turn to moiré.
static float gridLines(float2 p, float spacing) {
    float2 q = p / spacing;
    float2 width = fwidth(q);
    float2 line = abs(fract(q - 0.5) - 0.5) / max(width, 1e-4);
    return 1.0 - saturate(min(line.x, line.y));
}

// MARK: - Fall colors


















vertex VertexOut propVertex(VertexIn in [[stage_in]],
                            constant ObjectUniforms &object [[buffer(1)]],
                            constant FrameUniforms &frame [[buffer(2)]])
{
    float4 world = object.model * float4(in.position, 1);
    float3 rest = world.xyz;
    world.xyz = duSwayed(world.xyz, object.model[3].xyz, length(object.model[1].xyz), object.sway, object.wind, object.emissive.w > 0.5);
    VertexOut out;
    out.soft = 0;
    seasonOf(object.model[3].xz, object.foliage, frame.weather, out.fallColour, out.fallLeaves);
    out.position = seasonsOnFoliage && object.emissive.w > 0.5 && duShed(rest, out.fallLeaves) ? duFallenPosition : frame.viewProjection * world;
    out.worldPosition = world.xyz;
    out.restPosition = rest;
    out.normal = (object.normalMatrix * float4(in.normal, 0)).xyz;
    out.uv = in.uv;
    out.tint = float3(1);
    return out;
}

/// A copy — scattered, or a placed prop (2026-10-28) — the same vertex as a prop's, with the copy's own transform from
/// a buffer, applied on top of the mesh's place in its prop. **Normals go through the transform's cofactor matrix**,
/// the inverse transpose up to a scale the fragment shader's renormalising removes, its sign put back for a mirrored
/// piece: a placed prop can be stretched, and turning a normal by the transform itself leans it toward the stretch.
vertex VertexOut propInstancedVertex(VertexIn in [[stage_in]],
                                     uint instance [[instance_id]],
                                     constant ObjectUniforms &object [[buffer(1)]],
                                     constant FrameUniforms &frame [[buffer(2)]],
                                     const device float4x4 *copies [[buffer(3)]])
{
    float4x4 model = copies[instance] * object.model;
    float4 world = model * float4(in.position, 1);
    float3 rest = world.xyz;
    world.xyz = duSwayed(world.xyz, copies[instance][3].xyz, length(copies[instance][1].xyz), object.sway, object.wind, object.emissive.w > 0.5);
    VertexOut out;
    out.soft = 0;
    seasonOf(copies[instance][3].xz, object.foliage, frame.weather, out.fallColour, out.fallLeaves);
    out.position = seasonsOnFoliage && object.emissive.w > 0.5 && duShed(rest, out.fallLeaves) ? duFallenPosition : frame.viewProjection * world;
    out.worldPosition = world.xyz;
    out.restPosition = rest;
    float3 c0 = model[0].xyz, c1 = model[1].xyz, c2 = model[2].xyz;
    float3x3 cofactor = float3x3(cross(c1, c2), cross(c2, c0), cross(c0, c1));
    out.normal = cofactor * in.normal * sign(dot(c0, cross(c1, c2)));
    out.uv = in.uv;
    out.tint = float3(1);
    return out;
}

/// **Snow built up on a prop** (Ductane's `SnowCap`): the cap made from its upward faces, raised in the world by the
/// lying snow's depth (`params.y`) as each vertex says — `uv.x` how much, `uv.y` 0 or `1 + angle / 2π`, the level direction
/// its rim leans out toward by a third of the depth, turned with the copy — and swaying with its prop.
vertex VertexOut snowCapVertex(VertexIn in [[stage_in]],
                               uint instance [[instance_id]],
                               constant ObjectUniforms &object [[buffer(1)]],
                               constant FrameUniforms &frame [[buffer(2)]],
                               const device float4x4 *copies [[buffer(3)]])
{
    float4x4 model = copies[instance] * object.model;
    float4 world = model * float4(in.position, 1);
    world.xyz = duSwayed(world.xyz, copies[instance][3].xyz, length(copies[instance][1].xyz), object.sway, object.wind, object.emissive.w > 0.5);
    world = duSnowCapRaise(world, model, in.uv, object.params.y);
    float3 c0 = model[0].xyz, c1 = model[1].xyz, c2 = model[2].xyz;
    float3x3 cofactor = float3x3(cross(c1, c2), cross(c2, c0), cross(c0, c1));
    VertexOut out;
    out.soft = 0;
    out.position = frame.viewProjection * world;
    out.worldPosition = world.xyz;
    out.restPosition = out.worldPosition;
    out.normal = cofactor * in.normal * sign(dot(c0, cross(c1, c2)));
    out.uv = float2(0.5);
    out.tint = float3(1);
    out.fallColour = float4(0);
    out.fallLeaves = 1;
    return out;
}

/// One copy of an effect mesh: where, and the colour its particle tints it — must match `WorldRenderer.EffectCopy`.
struct EffectCopy {
    float4x4 transform;
    float4 tint;
};

/// **A particle drawn as a pack mesh** (`WorldRenderer.encodeEffectMeshes`) — a frog, a bubble, a fly: a prop's vertex,
/// placed by its particle and tinted by its colour, for `propFragment` to light as it lights a prop.
vertex VertexOut effectMeshVertex(VertexIn in [[stage_in]],
                                  uint instance [[instance_id]],
                                  constant ObjectUniforms &object [[buffer(1)]],
                                  constant FrameUniforms &frame [[buffer(2)]],
                                  const device EffectCopy *copies [[buffer(3)]])
{
    float4x4 model = copies[instance].transform * object.model;
    float4 world = model * float4(in.position, 1);
    VertexOut out;
    out.soft = 0;
    out.fallColour = float4(0);
    out.fallLeaves = 1;
    out.position = frame.viewProjection * world;
    out.worldPosition = world.xyz;
    out.restPosition = out.worldPosition;
    float3 c0 = model[0].xyz, c1 = model[1].xyz, c2 = model[2].xyz;
    float3x3 cofactor = float3x3(cross(c1, c2), cross(c2, c0), cross(c0, c1));
    out.normal = cofactor * in.normal * sign(dot(c0, cross(c1, c2)));
    out.uv = in.uv;
    out.tint = copies[instance].tint.rgb;
    return out;
}

// MARK: - Lying snow







// MARK: - Wet ground



// MARK: - Footprints







/// The ground goes through the props' fragment shader — the same light, so a rock on the ground is lit
/// exactly as the ground under it — carrying its painted colour as the tint.
vertex VertexOut groundVertex(GroundVertexIn in [[stage_in]],
                              constant ObjectUniforms &object [[buffer(1)]],
                              constant FrameUniforms &frame [[buffer(2)]],
                              depth2d<float> snowCover [[texture(7)]],
                              device const DUFootprint *prints [[buffer(6)]],
                              device const uint *cells [[buffer(7)]])
{
    float4 world = object.model * float4(in.position, 1);
    // **Snow with depth raises the ground where it lies** (`frame.weather.snow.y`), as much as it whitens it there — less
    // where feet have trodden it down into a path.
    if (weatherOnSurfaces && frame.weather.snow.y > 0) {
        float lying = duSnowOn(world.xyz, normalize((object.normalMatrix * float4(in.normal, 0)).xyz), frame.weather, snowCover);
        float down = lying > 0 ? duTrodden(float3(world.x, world.y + frame.weather.snow.y * lying, world.z), frame.weather, prints, cells) : 0;
        world.y += frame.weather.snow.y * lying * (1.0 - 0.7 * down);
    }
    VertexOut out;
    out.soft = 0;
    out.position = frame.viewProjection * world;
    out.worldPosition = world.xyz;
    out.restPosition = out.worldPosition;
    out.normal = (object.normalMatrix * float4(in.normal, 0)).xyz;
    out.uv = in.uv;
    out.tint = in.colour.rgb;
    out.soft = in.colour.a;
    out.fallColour = float4(0);
    out.fallLeaves = 1;
    return out;
}

/// **A cut-out's alpha, kept as full far away as near** (Ben Golus's mip-scaled alpha test). A texture's smaller mips
/// average its alpha, and a leaf image that is 45% leaf averages under the cut-off — so a wood seen from across the
/// zone drew as bare branches. Scaling alpha up by how far down the mip chain the sample is keeps the coverage.
static float coverage(texture2d<float> map, sampler s, float2 uv, float alpha) {
    return alpha * (1.0 + max(map.calculate_unclamped_lod(s, uv), 0.0) * 0.25);
}

// MARK: - Sun shadows

/// One cascade's lookup, 3×3 percentage-closer filtered. **Copied from Ductane's sample**, which is
/// where its reasoning lives: outside the map is lit, reversed-Z means lit when nearer is greater, and the
/// bias comes from the cascade's texel size.
static float sampleCascade(constant FrameUniforms &frame, float3 worldPosition, int cascade,
                           depth2d_array<float> shadowMap, sampler shadowSampler, bool single) {
    float4 lightPosition = frame.cascadeViewProjection[cascade] * float4(worldPosition, 1.0);
    float3 projected = lightPosition.xyz / lightPosition.w;
    float2 uv = projected.xy * float2(0.5, -0.5) + 0.5;
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0 || projected.z <= 0.0) { return 1.0; }
    const float reference = projected.z + frame.cascadeDepthBias[cascade];
    // **One tap for foliage**: the sampler's own bilinear compare, against nine. Leaves and grass are a sea of overlapping
    // cut-out cards, and nine taps for every one of them was half the frame; their busy edges hide the harder shadow.
    if (single) { return shadowMap.sample_compare(shadowSampler, uv, cascade, reference); }
    float sum = 0.0;
    for (int y = -1; y <= 1; ++y) {
        for (int x = -1; x <= 1; ++x) {
            sum += shadowMap.sample_compare(shadowSampler, uv + float2(x, y) * frame.shadowParams.x,
                                            cascade, reference);
        }
    }
    return sum / 9.0;
}

/// How much of the sun reaches a point: 0 in shadow, 1 lit. The tightest cascade that reaches it, by
/// distance from the eye, cross-faded into the next over a band so no seam sweeps the ground.
static float sunVisibility(constant FrameUniforms &frame, float3 worldPosition, depth2d_array<float> shadowMap,
                           bool single = false) {
    if (frame.shadowParams.y < 0.5) { return 1.0; }
    constexpr sampler shadowSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge,
                                    compare_func::greater_equal);   // reversed-Z
    const float depth = distance(worldPosition, frame.cameraPosition.xyz);
    int cascade = 3;
    for (int i = 0; i < 4; ++i) { if (depth < frame.cascadeSplits[i]) { cascade = i; break; } }
    float visibility = sampleCascade(frame, worldPosition, cascade, shadowMap, shadowSampler, single);
    if (cascade < 3) {
        const float start = frame.cascadeBlendStart[cascade], split = frame.cascadeSplits[cascade];
        const float t = saturate((depth - start) / max(split - start, 1e-4));
        if (t > 0.0) {
            visibility = mix(visibility, sampleCascade(frame, worldPosition, cascade + 1, shadowMap, shadowSampler, single), t);
        }
    }
    return visibility;
}

/// The shadow pass: position only, through Ductane's `ShadowMap` (`ShadowBufferIndex`: uniforms at 1,
/// the cascade's light matrix at 2, instanced copies at 4).
vertex float4 shadowPropVertex(VertexIn in [[stage_in]],
                               constant ObjectUniforms &object [[buffer(1)]],
                               constant float4x4 &lightViewProjection [[buffer(2)]]) {
    float4 world = object.model * float4(in.position, 1);
    world.xyz = duSwayed(world.xyz, object.model[3].xyz, length(object.model[1].xyz), object.sway, object.wind, object.emissive.w > 0.5);
    return lightViewProjection * world;
}

vertex float4 shadowInstancedVertex(VertexIn in [[stage_in]],
                                    uint instance [[instance_id]],
                                    constant ObjectUniforms &object [[buffer(1)]],
                                    constant float4x4 &lightViewProjection [[buffer(2)]],
                                    const device float4x4 *copies [[buffer(4)]]) {
    float4 world = copies[instance] * object.model * float4(in.position, 1);
    world.xyz = duSwayed(world.xyz, copies[instance][3].xyz, length(copies[instance][1].xyz), object.sway, object.wind, object.emissive.w > 0.5);
    return lightViewProjection * world;
}

/// **A cut-out surface casts the shape its alpha draws**, not its polygon's: a grass card casts blades rather than
/// a square, and a meadow of them is not one black blot. The same vertex as above with its uv carried through,
/// and a fragment function that only decides whether to discard — the shadow pass has no colour attachment.
struct ShadowMaskOut {
    float4 position [[position]];
    float2 uv;
    /// Where the surface rests before the wind moves it, and how much of its tree's leaves are left — for a turning tree's
    /// fallen leaves (`fallen`).
    float3 world;
    float leaves [[flat]];
};


vertex ShadowMaskOut shadowMaskPropVertex(VertexIn in [[stage_in]],
                                          constant ObjectUniforms &object [[buffer(1)]],
                                          constant float4x4 &lightViewProjection [[buffer(2)]]) {
    float4 world = object.model * float4(in.position, 1);
    float3 rest = world.xyz;
    world.xyz = duSwayed(world.xyz, object.model[3].xyz, length(object.model[1].xyz), object.sway, object.wind, object.emissive.w > 0.5);
    float leaves = duLeavesLeft(object.model[3].xz, object.foliage);
    if (object.emissive.w > 0.5) {
        if (duShed(rest, leaves)) return { duFallenPosition, in.uv, rest, 1 };
        leaves = 1;
    }
    return { lightViewProjection * world, in.uv, rest, leaves };
}

vertex ShadowMaskOut shadowMaskInstancedVertex(VertexIn in [[stage_in]],
                                               uint instance [[instance_id]],
                                               constant ObjectUniforms &object [[buffer(1)]],
                                               constant float4x4 &lightViewProjection [[buffer(2)]],
                                               const device float4x4 *copies [[buffer(4)]]) {
    float4 world = copies[instance] * object.model * float4(in.position, 1);
    float3 rest = world.xyz;
    world.xyz = duSwayed(world.xyz, copies[instance][3].xyz, length(copies[instance][1].xyz), object.sway, object.wind, object.emissive.w > 0.5);
    float leaves = duLeavesLeft(copies[instance][3].xz, object.foliage);
    if (object.emissive.w > 0.5) {
        if (duShed(rest, leaves)) return { duFallenPosition, in.uv, rest, 1 };
        leaves = 1;
    }
    return { lightViewProjection * world, in.uv, rest, leaves };
}

/// Bound on the fragment stage by the batch itself: the object's uniforms at 1, its base map at 0. **A turning tree's
/// fallen leaves cast nothing** — its solid canopy comes through here too while trees are thinning, its cutoff 0.
fragment void shadowMaskFragment(ShadowMaskOut in [[stage_in]],
                                 constant ObjectUniforms &object [[buffer(1)]],
                                 texture2d<float> baseMap [[texture(0)]]) {
    constexpr sampler linear(filter::linear, mip_filter::linear, address::repeat);
    float4 base = baseMap.sample(linear, in.uv);
    if (object.baseColour.a * coverage(baseMap, linear, in.uv, base.a) < object.params.z) { discard_fragment(); }
    if (in.leaves < 1.0 && duLeafness(object.baseColour.rgb * base.rgb, object.params.z > 0, base.a) > 0.5
        && duFallen(in.world, in.leaves)) discard_fragment();
}

/// The ground casts too: a hill throws its shadow over the valley behind it at dawn.
vertex float4 shadowGroundVertex(GroundVertexIn in [[stage_in]],
                                 constant ObjectUniforms &object [[buffer(1)]],
                                 constant float4x4 &lightViewProjection [[buffer(2)]]) {
    return lightViewProjection * (object.model * float4(in.position, 1));
}

/// Sky from above, ground from below, blended by how far the normal leans: the cheapest ambient that
/// still separates a top face from a side.
static float3 hemisphere(float3 n, constant FrameUniforms &frame) {
    float t = n.y * 0.5 + 0.5;
    return mix(frame.groundColour.rgb, frame.skyColour.rgb, t);
}

/// Must match `WorldRenderer.GrungeUniforms`: a material's triplanar grime (`WorldFile.Grime`).
struct GrungeUniforms {
    float4 colour;   // rgb: the tint; a: how much
    float4 params;   // x: repeats a metre; y: the projections' falloff; z: the sheet's own tiling; w: 1 when on
};

/// **A pack's triplanar grime** (`WorldFile.Grime`): the grunge map from three sides in world space, each side
/// weighted by the normal to the power of the falloff — Unity's Triplanar node — times the tint, multiplied into the
/// sheet at its intensity (its Blend node in Multiply).
static float3 grimed(float3 albedo, float3 p, float3 n, constant GrungeUniforms &grunge, texture2d<float> map, sampler s) {
    float3 w = pow(abs(n), float3(grunge.params.y));
    w /= max(w.x + w.y + w.z, 1e-4);
    float3 q = p * grunge.params.x;
    float3 g = map.sample(s, q.zy).rgb * w.x + map.sample(s, q.xz).rgb * w.y + map.sample(s, q.xy).rgb * w.z;
    return mix(albedo, albedo * g * grunge.colour.rgb, grunge.colour.a);
}

/// **Foliage is shaded as foliage** — a plant's or a tree's cut-out cards, its grass blades and leaves — as foliage shaders
/// in Unity and Unreal shade it: **the normal bent toward the sky**, so a clump is lit as a soft mass rather than blade by
/// blade (a pack's upright grass cards carry normals pointing sideways, and a high sun lit a meadow nearly black), and
/// **sunlight through the blade** (``foliageTransmission``). A plant is bent the most; a tree's leaves less, so a canopy
/// keeps its shape. `swayKind` is `ObjectUniforms.sway.x` (1 a tree, 2 a plant); a solid surface is left as it is. A pack
/// that already points its cards' normals up, as many do, changes little.
static inline float foliageBend(float swayKind, float cutoff) {
    if (cutoff <= 0) return 0.0;
    if (swayKind > 1.5 && swayKind < 2.5) return 0.8;
    if (swayKind > 0.5 && swayKind < 1.5) return 0.35;
    return 0.0;
}
static inline float3 foliageNormal(float3 n, float bend) {
    return bend > 0 ? normalize(mix(n, float3(0, 1, 0), bend)) : n;
}
/// **Sunlight through a leaf or a blade**: thin foliage lets light through, so a meadow or a canopy seen against the sun
/// glows rather than going dark. Most toward the sun, some whenever the sun is on the card's far side; as much of it as
/// reaches the card (`sunLit`, its shadow and the clouds').
static inline float foliageTransmission(float3 cardNormal, float3 v, float3 l) {
    float through = saturate(dot(-cardNormal, l));
    float againstTheSun = pow(saturate(dot(-v, l)), 4.0);
    return 0.35 * through + 0.65 * againstTheSun;
}

fragment float4 propFragment(VertexOut in [[stage_in]],
                             bool frontFacing [[front_facing]],
                             constant ObjectUniforms &object [[buffer(1)]],
                             constant FrameUniforms &frame [[buffer(2)]],
                             texture2d<float> baseMap [[texture(0)]],
                             depth2d_array<float> shadowMap [[texture(1)]],
                             texture2d<float> glowMap [[texture(2)]],
                             device const float *groundVertices [[buffer(4)]],
                             constant GrungeUniforms &grunge [[buffer(5)]],
                             texture2d<float> grungeMap [[texture(3)]],
                             depth2d<float> snowCover [[texture(7)]],
                             device const DUFootprint *prints [[buffer(6)]],
                             device const uint *cells [[buffer(7)]],
                             device const float *puddles [[buffer(8)]],
                             device const float *litterField [[buffer(9)]],
                             texture2d<float> cloudMap [[texture(8)]],
                             texture3d<float> fogVolume [[texture(9)]],
                             constant GroundLayers &groundLayers [[buffer(10)]],
                             device const uchar4 *groundWeights [[buffer(11)]],
                             texture2d_array<float> groundAlbedo [[texture(10)]],
                             texture2d_array<float> groundSurface [[texture(11)]])
{
    constexpr sampler linear(filter::linear, mip_filter::linear, address::repeat, max_anisotropy(8));
    float3 worldPosition = in.worldPosition, normal = in.normal, tint = in.tint;
    // A ground chunk at a coarser level (`params.w` 2): the full ground's point, normal and paint under this pixel.
    bool coarseGround = object.params.w > 1.5;
    float soft = in.soft;
    if (coarseGround) {
        GroundPoint ground = fineGround(in.worldPosition.xz, frame, groundVertices);
        worldPosition = ground.position;
        normal = ground.normal;
        tint = ground.colour;
        soft = ground.soft;
    }
    float3 n = normalize(normal);
    float3 v = normalize(frame.cameraPosition.xyz - worldPosition);
    // A pack's single-sided cards — leaves, grass — are lit from whichever side is seen. **A back face's normal is
    // mirrored across the card, never flipped by where the eye is**: foliage packs bake a card's normals pointing up,
    // for soft light across a clump. Flipping every back face lit half a meadow as if it faced the ground; flipping
    // only where the normal faced away from the eye turned a blade dark exactly where it rose above eye height — a
    // hard line along the horizon through a meadow seen at eye height (2026-11-20). Mirrored, a true normal turns to
    // the side seen, a baked upward one on an upright card stays as it is, and nothing changes with the view.
    float3 faceNormal = n;
    if (!frontFacing) {
        float3 card = cross(dfdx(worldPosition), dfdy(worldPosition));
        if (length_squared(card) > 1e-12) {
            card = normalize(card);
            if (dot(card, v) > 0) card = -card;     // the card's front, which faces away from the eye on a back face
            n = normalize(n - 2 * dot(n, card) * card);
        } else if (dot(n, v) < 0) {
            n = -n;
        }
    }
    // **Foliage shaded as foliage** (`foliageBend`): the seen side's normal kept for the light through it.
    float3 cardNormal = n;
    float bend = object.params.w > 0.5 ? 0.0 : foliageBend(object.sway.x, object.params.z);
    n = foliageNormal(n, bend);
    // The sheet repeated as its material says (`_Albedo_Tiling`, carried with its grime).
    float2 uv = grunge.params.w > 0.5 ? in.uv * grunge.params.z : in.uv;
    float4 base = baseMap.sample(linear, uv);
    // A cut-out surface — a leaf, a blade of grass — is not drawn where its alpha is below the cutoff.
    // **Multisampled, the cut-out edge becomes coverage** (alpha to coverage on the prop pipelines): the alpha sharpened to
    // about a pixel around the cutoff, so a leaf's outline is smoothed like a polygon's. One sample a pixel, the same cut.
    float edge = 1.0;
    if (object.params.z > 0) {
        float a = object.baseColour.a * coverage(baseMap, linear, uv, base.a);
        if (frame.shadowParams.w > 0.5) {
            edge = saturate((a - object.params.z) / max(fwidth(a), 1e-4) + 0.5);
            if (edge <= 0.0) discard_fragment();
        } else if (a < object.params.z) { discard_fragment(); }
    }
    float3 albedo = object.baseColour.rgb * base.rgb * tint;
    float surfaceRoughness = object.params.x, occlusion = 1.0;
    // **The ground from its layers' textures** (`texturedGround`), in place of its painted colours.
    if (texturedGround && object.params.w > 0.5) {
        LayerSample ground = texturedGroundSurface(worldPosition, faceNormal, frame, groundLayers, groundWeights,
                                                   groundAlbedo, groundSurface);
        albedo = ground.albedo;
        n = ground.normal;
        surfaceRoughness = ground.roughness;
        occlusion = ground.occlusion;
    }
    if (grunge.params.w > 0.5) albedo = grimed(albedo, worldPosition, faceNormal, grunge, grungeMap, linear);
    // **Through the year** (fall colors): a turning tree's leaves coloured or fallen, grass gone straw.
    if (seasonsOnFoliage && !duThroughTheYear(albedo, base.a, in.restPosition, in.fallColour, in.fallLeaves, object.params.z > 0, object.emissive.w > 0.5)) discard_fragment();
    // **The weather on it** (Ductane's `duWeathered`): fallen leaves on the ground under turning trees, lying snow
    // on what faces the sky, dust settled in a storm, wet surfaces, puddles and running water, footprints in snow and soft
    // ground.
    // Compiled out of the set a frame with no weather on surfaces draws with (`weatherOnSurfaces`).
    DUWeathered weathered = { albedo, n, 0, 0, 0, 0, 0 };
    if (weatherOnSurfaces) {
        weathered = duWeathered(albedo, n, faceNormal, worldPosition, object.params.w > 0.5, true, soft,
                                frame.weather, frame.ground, snowCover, prints, cells, puddles, litterField);
    }
    albedo = weathered.albedo;
    n = weathered.normal;

    float3 l = frame.sunDirection.xyz;
    float3 h = normalize(l + v);
    // The sun's light, less what is shadowed. The sky's ambient still reaches into shade.
    float sunLit = sunVisibility(frame, worldPosition, shadowMap, object.params.z > 0)
                 * duCloudShadow(worldPosition, l, frame.weather, cloudMap);
    float nl = saturate(dot(n, l)) * sunLit;
    float transmitted = bend > 0 ? foliageTransmission(cardNormal, v, l) * sunLit : 0.0;

    // Wet is glossy: a soaked surface toward 0.15, a puddle toward a mirror.
    float roughness = duWetRoughness(surfaceRoughness, weathered);
    float shininess = 2.0 / (roughness * roughness * roughness * roughness) - 2.0;
    float specular = pow(saturate(dot(n, h)), shininess) * (shininess + 8.0) / (8.0 * M_PI_F) * 0.04;

    // What glows: the material's emission times its map, white where it has none.
    // (The ground is never under itself: a coarse chunk's outline can sit a little below the full ground it is read from.)
    float3 colour = albedo * (frame.sunColour.rgb * (nl + transmitted) / M_PI_F + hemisphere(n, frame) * occlusion * (coarseGround ? 1.0 : skyReaching(worldPosition, frame, groundVertices))
                            + pointLighting(worldPosition, n, frame))
                  + frame.sunColour.rgb * specular * nl
                  + object.emissive.rgb * glowMap.sample(linear, in.uv).rgb;

    // **What is wet reflects the sky** (`duWetSheen`): by Schlick's Fresnel, more at a glance, a puddle most.
    if (weathered.gloss > 0) {
        colour += hemisphere(reflect(-v, n), frame) * duWetSheen(n, v, weathered) * (coarseGround ? 1.0 : skyReaching(worldPosition, frame, groundVertices));
    }

    // **A fine grain on the ground near the eye** (`fogParams.z`, the scene's `groundGrain`): two scales of value noise,
    // half a metre and two metres, darkening by up to a fifth, gone by forty metres — something underfoot to see go by
    // on ground painted one colour. See `WorldScene.groundGrain`.
    if (!texturedGround && object.params.w > 0.5 && frame.fogParams.z > 0) {
        float2 p = worldPosition.xz;
        float fine = duValueNoise(p * 2.0), coarse = duValueNoise(p * 0.5 + 17.0);
        float grain = (fine * 0.6 + coarse * 0.4) * frame.fogParams.z;
        float near = 1.0 - smoothstep(12.0, 40.0, length(worldPosition - frame.cameraPosition.xyz));
        colour *= 1.0 - 0.2 * grain * near;
    }

    // **The ground carries the grid's lines**, faintly, since it covers the grid: without them a flat
    // stretch is one colour, and neither distance nor slope can be judged on it.
    if (object.params.w > 0.5 && frame.cameraPosition.w > 0.5) {
        float2 p = worldPosition.xz;
        float lines = max(gridLines(p, 1.0) * 0.10, gridLines(p, 10.0) * 0.28);
        float distance = length(worldPosition - frame.cameraPosition.xyz);
        colour *= 1.0 + lines * (1.0 - smoothstep(40.0, 160.0, distance));
    }

    // **A see-through surface hands over its opacity** (glass: no cut-out, its material's alpha below one — the
    // renderer's `isSeeThrough`), which only the see-through pipeline draws, blended by it. Anything else hands over its
    // cut-out edge as before: a solid texture's own alpha must not reach alpha to coverage.
    float opacity = (object.params.z > 0 || object.baseColour.a >= 0.999) ? edge : object.baseColour.a * base.a;
    return float4(fogged(colour, worldPosition, frame, fogVolume), opacity);
}

/// **A snow cap's pixels** (``snowCapVertex``): snow, lit by the sun through its shadows and the clouds', the sky and the
/// point lights, in the fog — none where it could not have fallen, under a roof or a tree. Its own, light shader: a cap
/// is plain snow, and the prop shader's paint, wet and footprints are for what it covers.
fragment float4 snowCapFragment(VertexOut in [[stage_in]],
                                constant ObjectUniforms &object [[buffer(1)]],
                                constant FrameUniforms &frame [[buffer(2)]],
                                depth2d_array<float> shadowMap [[texture(1)]],
                                device const float *groundVertices [[buffer(4)]],
                                depth2d<float> snowCover [[texture(7)]],
                                texture2d<float> cloudMap [[texture(8)]],
                             texture3d<float> fogVolume [[texture(9)]])
{
    float3 p = in.worldPosition;
    if (duSnowOpen(p, frame.weather, snowCover) < 0.4) discard_fragment();
    float3 n = normalize(in.normal);
    float3 v = normalize(frame.cameraPosition.xyz - p);
    if (dot(n, v) < 0) n = -n;
    float3 l = frame.sunDirection.xyz;
    float nl = saturate(dot(n, l)) * sunVisibility(frame, p, shadowMap, false) * duCloudShadow(p, l, frame.weather, cloudMap);
    float3 colour = duSnowColour * (frame.sunColour.rgb * nl / M_PI_F + hemisphere(n, frame) * skyReaching(p, frame, groundVertices)
                                  + pointLighting(p, n, frame));
    return float4(fogged(colour, p, frame, fogVolume), 1);
}

// MARK: - Liquids

/// Must match `WorldRenderer.LiquidUniforms` — a liquid's look (`WorldFile.Liquid`) and the frame's clock.
struct LiquidUniforms {
    float4 shallow;      // rgb; w: deep height
    float4 deep;         // rgb; w: very deep height
    float4 veryDeep;     // rgb; w: shallows opacity
    float4 scrollTint;   // rgb; w: the sheet's opacity
    float4 scroll;       // xy: the sheet's tiling; zw: its direction, UVs a second
    float4 shoreTint;    // rgb; w: the band's opacity
    float4 shore;        // x: the band's thickness; y: the line's; z: how far the line returns; w: the line's noise scale
    float4 foamTint;     // rgb; w: the specks' opacity
    float4 foam;         // x: the specks' tiling; y: the line's second noise scale; z: base opacity; w: the near plane
    float4 ripples;      // x: tiling; y: intensity; z: their noises' intensity; w: their noises' tiling
    float4 surface;      // x: metallic; y: smoothness; z: the ripples' pan speed; w: seconds
    float4 switches;     // x: the shore's band and line; y: its specks; z: the sheet; w: the ripples — 1 on
};

/// A noise's red, sampled **from above**, as the pack's own shader's top-down projection samples it: by the point's x and z
/// in metres times its tiling. (Unity's `−z` is this world's `z`.)
static float topDown(texture2d<float> map, sampler s, float3 p, float2 tiling, float2 offset = 0) {
    return map.sample(s, p.xz * tiling + offset).r;
}

/// **A liquid coloured by how deep it is** (`WorldFile.Liquid`) — a stylised pack's water shader, which its goop wears,
/// term for term. `depth` is how far the solid scene lies behind the surface, as Unity's
/// `DepthFade` reckons it: the scene's distance along the view less the surface's, read from the solid pass's depth
/// (Ductane's `OpaqueTextures`; reversed-Z, so distance = near ÷ depth). Every part of the look is a function
/// of it — the colour, shallow at the shore and very deep a metre out; a band of the shore's colour fading over its
/// first `shore.x` metres; a line of it a little way out, where noise puts it; specks of foam in the first two metres;
/// and the opacity — with the sheet scrolling over the top by the mesh's UVs. Lit as a prop is, with the shader's metallic
/// and smoothness, its ripples from two panning samples of the normal map, top-down.
fragment float4 liquidFragment(VertexOut in [[stage_in]],
                               constant LiquidUniforms &liquid [[buffer(5)]],
                               constant FrameUniforms &frame [[buffer(2)]],
                               texture2d<float> sheet [[texture(0)]],
                               depth2d_array<float> shadowMap [[texture(1)]],
                               texture2d<float> noise [[texture(2)]],
                               texture2d<float> normals [[texture(3)]],
                               depth2d<float> solidDepth [[texture(6)]],
                               device const float *groundVertices [[buffer(4)]],
                             texture3d<float> fogVolume [[texture(9)]])
{
    constexpr sampler rep(filter::linear, mip_filter::linear, address::repeat, max_anisotropy(8));
    float3 p = in.worldPosition;
    float t = liquid.surface.w;

    // How deep: Unity's `SceneDepth(Eye) − ScreenPosition.w`.
    float stored = solidDepth.read(uint2(in.position.xy));
    float near = liquid.foam.w;
    float surfaceDistance = (frame.viewProjection * float4(p, 1)).w;
    float depth = (stored > 0 ? near / stored : 1e4) - surfaceDistance;

    // Shallow giving way to deep, and that to very deep — the shader's two gradients: 1 → 0, and 0 → 1 by half way.
    float toDeep = 1 - saturate(depth / abs(liquid.shallow.w));
    float toVeryDeep = min(saturate(depth / abs(liquid.deep.w)) * 2, 1.0);
    float3 colour = mix(mix(liquid.deep.rgb, liquid.shallow.rgb, toDeep), liquid.veryDeep.rgb, toVeryDeep);

    float3 shoreLine = 0, shoreBand = 0, specks = 0;
    if (liquid.switches.x > 0.5) {
        // The band: brightest at the shore, gone `shore.x` metres deep.
        shoreBand = liquid.shoreTint.rgb * (1 - saturate(pow(depth / liquid.shore.x, 2.0))) * liquid.shoreTint.w;
        // The line out from it. The shader animates where it falls; the goop's material leaves that off (`_Animation_Offset`
        // 0), so it stands where its noises put it.
        float m = fmod(saturate(topDown(noise, rep, p, liquid.shore.w * 0.005)), 1.0);
        float reach = M_PI_F / (2.0 - liquid.shore.z);
        float spread = saturate(pow(topDown(noise, rep, p, liquid.foam.y * 0.005), 0.2));
        float x = saturate((depth + sin(m * reach)) * spread);
        float thick = 0.99 * saturate(liquid.shore.y) * (1 - saturate(2 * m - 1)) * (1 - saturate(1 - 4 * m));
        float line = saturate(floor(x + thick) - floor(x));
        shoreLine = liquid.shoreTint.rgb * line * (liquid.shoreTint.w / 1.5);
    }
    if (liquid.switches.y > 0.5) {
        // Specks of foam in the first two metres, from a noise drifting slowly.
        float n = topDown(noise, rep, p, liquid.foam.x * 0.01, float2(t * 0.003));
        float speck = saturate(pow((1 - saturate(depth / 2)) * 0.8 * n * 5, 20.0));
        specks = liquid.foamTint.rgb * speck * (liquid.foamTint.w / 3);
    }
    float3 albedo = colour + shoreLine + shoreBand + specks;
    if (liquid.switches.z > 0.5) {
        // The sheet, by the mesh's UVs, offset `1 − direction × time` as the shader's tiling and offset has it.
        float2 uv = in.uv * liquid.scroll.xy + (1 - liquid.scroll.zw * t);
        albedo += liquid.scrollTint.w * liquid.scrollTint.rgb * sheet.sample(rep, uv).rgb;
    }
    // Opacity: nearly whole at the shore, whole fifteen metres deep, less what the base leaves through — and what the
    // shore adds (the alpha takes each colour's red, as the shader's graph does).
    float alpha = mix(liquid.veryDeep.w, 1.0, saturate(depth / 15))
                + shoreLine.r + shoreBand.r + specks.r - (1 - liquid.foam.z);
    alpha = saturate(alpha);

    // The ripples: two samples of the normal map from above, panning opposite ways, nudged by two still noises.
    float3 n = normalize(in.normal);
    if (liquid.switches.w > 0.5) {
        float tiling = liquid.ripples.x * 0.04;
        float nudge = topDown(noise, rep, p, liquid.ripples.w * 0.01) * topDown(noise, rep, p, liquid.ripples.w * 0.005)
                    * liquid.ripples.z;
        float2 pan = liquid.surface.z * 0.02 * float2(t);
        float3 a = normals.sample(rep, p.xz * tiling + nudge + pan).xyz * 2 - 1;
        float3 b = normals.sample(rep, p.xz * tiling * 0.2 + (nudge + pan) * float2(1, -1)).xyz * 2 - 1;
        // Unity's Normal Blend (Whiteout), then leant toward flat but for the intensity.
        float3 blended = normalize(float3(a.xy + b.xy, a.z * b.z));
        float3 tangentSpace = normalize(mix(float3(0, 0, 1), blended, liquid.ripples.y));
        // Seen from above, the surface's tangent runs along x and its bitangent along z.
        n = normalize(n * tangentSpace.z + float3(tangentSpace.x, 0, tangentSpace.y));
    }

    // Lit as a prop: the sun less its shadow, the sky and ground, the lamps — with the shader's metallic taking from the
    // diffuse and tinting the glint, and the sky's reflection for what a smooth, part-metal surface shows.
    float3 v = normalize(frame.cameraPosition.xyz - p);
    float3 l = frame.sunDirection.xyz;
    float3 h = normalize(l + v);
    float nl = saturate(dot(n, l)) * sunVisibility(frame, p, shadowMap, false);
    float metallic = liquid.surface.x;
    float roughness = clamp(1 - liquid.surface.y, 0.05, 1.0);
    float shininess = 2.0 / (roughness * roughness * roughness * roughness) - 2.0;
    float3 f0 = mix(float3(0.04), albedo, metallic);
    float3 specular = f0 * pow(saturate(dot(n, h)), shininess) * (shininess + 8.0) / (8.0 * M_PI_F);
    float facing = saturate(dot(n, v));
    float3 fresnel = f0 + (max(float3(1 - roughness), f0) - f0) * pow(1 - facing, 5.0);
    float3 r = reflect(-v, n);
    float3 sky = mix(frame.horizonColour.rgb, frame.skyColour.rgb * 1.6, pow(saturate(r.y), 0.6));
    float3 lit = albedo * (1 - metallic) * (frame.sunColour.rgb * nl / M_PI_F + hemisphere(n, frame) * skyReaching(p, frame, groundVertices)
                                            + pointLighting(p, n, frame))
               + frame.sunColour.rgb * specular * nl + sky * fresnel * (1 - roughness);
    return float4(fogged(lit, p, frame, fogVolume), alpha);
}

// MARK: - Far pictures

/// One of a far picture's views (`ImpostorViews`): the direction it looks from, toward the eye, and its right and up.
struct ImpostorView {
    float3 direction;
    float3 right;
    float3 up;
};

constant int impostorSide = 8;   // ImpostorViews.side

/// View `index` — `ImpostorViews.views[index]`, worked out the same way: the centre of its cell of the square, as a
/// direction, and the picture's right and up round it.
static ImpostorView impostorView(uint index) {
    float2 p = (float2(index % impostorSide, index / impostorSide) + 0.5) / float(impostorSide) * 2 - 1;
    float x = (p.x + p.y) / 2, z = (p.x - p.y) / 2;
    ImpostorView view;
    view.direction = normalize(float3(x, max(1 - abs(x) - abs(z), 0.0), z));
    float3 across = cross(float3(0, 1, 0), view.direction);
    view.right = length(across) > 1e-4 ? normalize(across) : float3(1, 0, 0);
    view.up = cross(view.direction, view.right);
    return view;
}

struct ImpostorBakeOut {
    float4 position [[position]];
    float3 normal;
    float2 uv;
    float3 direction [[flat]];
    /// How far toward the eye, in the unit sphere.
    float toward;
    uint layer [[render_target_array_index]];
};

/// **A far picture's bake**: the prop's mesh, already in the unit sphere round its centre (`object.model`), seen
/// orthographically from view `instance` into slice `instance` — every view in one draw.
vertex ImpostorBakeOut impostorBakeVertex(VertexIn in [[stage_in]],
                                          uint instance [[instance_id]],
                                          constant ObjectUniforms &object [[buffer(1)]])
{
    ImpostorView view = impostorView(instance);
    float3 p = (object.model * float4(in.position, 1)).xyz;
    float3 c0 = object.model[0].xyz, c1 = object.model[1].xyz, c2 = object.model[2].xyz;
    float3x3 cofactor = float3x3(cross(c1, c2), cross(c2, c0), cross(c0, c1));
    ImpostorBakeOut out;
    // Right, up, and depth growing away from the eye: the same handedness as the scene's clip space, so a front face
    // stays a front face.
    out.position = float4(dot(p, view.right), dot(p, view.up), 0.5 - 0.5 * dot(p, view.direction), 1);
    out.normal = cofactor * in.normal * sign(dot(c0, cross(c1, c2)));
    out.uv = in.uv;
    out.direction = view.direction;
    out.toward = dot(p, view.direction);
    out.layer = instance;
    return out;
}

struct ImpostorBakeTargets {
    float4 albedo [[color(0)]];
    float4 normal [[color(1)]];
    float depth [[color(2)]];
};

/// The surface's own colour and the normal it is lit by — cut out and turned toward the eye as `propFragment` does it —
/// with nothing of the light: the picture is lit where it is drawn.
fragment ImpostorBakeTargets impostorBakeFragment(ImpostorBakeOut in [[stage_in]],
                                                  bool frontFacing [[front_facing]],
                                                  constant ObjectUniforms &object [[buffer(1)]],
                                                  texture2d<float> baseMap [[texture(0)]])
{
    constexpr sampler linear(filter::linear, mip_filter::linear, address::repeat, max_anisotropy(8));
    float4 base = baseMap.sample(linear, in.uv);
    // **Cut as it is cut where the picture is drawn**, a mip further out than here: the picture is drawn at most three
    // quarters of its size, and a card's coverage grows with its distance (`coverage`). Cut at the bake's own size, the
    // gaps a far canopy never shows let the ground through it.
    float a = base.a * (1.0 + (max(baseMap.calculate_unclamped_lod(linear, in.uv), 0.0) + 1.0) * 0.25);
    if (object.params.z > 0 && object.baseColour.a * a < object.params.z) discard_fragment();
    float3 n = normalize(in.normal);
    if (!frontFacing && dot(n, in.direction) < 0) n = -n;
    // Bent as the near copies are (`foliageBend`): the bake's frame is the prop's own, its up the prop's up.
    n = foliageNormal(n, foliageBend(object.sway.x, object.params.z));
    ImpostorBakeTargets out;
    out.albedo = float4(object.baseColour.rgb * base.rgb, 1);
    out.normal = float4(n * 0.5 + 0.5, 1);
    out.depth = saturate(0.5 + 0.5 * in.toward);
    return out;
}

struct ImpostorOut {
    float4 position [[position]];
    float3 worldPosition;
    /// The point on the square in the unit sphere round the prop's centre, in the prop's own frame.
    float3 local;
    uint4 views [[flat]];
    float4 weights [[flat]];
    /// The copy's cofactor columns, sign put back: a normal in the prop's frame to the world's.
    float3 normal0 [[flat]];
    float3 normal1 [[flat]];
    float3 normal2 [[flat]];
    /// Toward the eye, and the sphere's radius in the world: a baked depth's step.
    float3 forward [[flat]];
    float radius [[flat]];
    /// Where the copy stands, and its tree through the year (`seasonOf`).
    float2 root [[flat]];
    float4 fallColour [[flat]];
    float fallLeaves [[flat]];
};

/// A direction in the upper hemisphere as a point of the unit square — `ImpostorViews.encode`.
static float2 hemiOctahedral(float3 d) {
    d /= max(abs(d.x) + abs(d.y) + abs(d.z), 1e-6);
    return float2(d.x + d.z, d.x - d.z) * 0.5 + 0.5;
}

/// **A far copy as one square facing the eye**, as big as the sphere round it (`object.model` takes the unit sphere to
/// the prop's), with the four views nearest the eye's direction in the copy's own frame and how much of each —
/// `ImpostorViews.blend`.
vertex ImpostorOut impostorVertex(uint vid [[vertex_id]],
                                  uint instance [[instance_id]],
                                  constant ObjectUniforms &object [[buffer(1)]],
                                  constant FrameUniforms &frame [[buffer(2)]],
                                  const device float4x4 *copies [[buffer(3)]])
{
    float4x4 model = copies[instance] * object.model;
    float3 centre = model[3].xyz;
    float3 c0 = model[0].xyz, c1 = model[1].xyz, c2 = model[2].xyz;
    float radius = max(length(c0), max(length(c1), length(c2)));
    float3 toEye = frame.cameraPosition.xyz - centre;
    float3 forward = normalize(toEye);
    float3 side = cross(float3(0, 1, 0), forward);
    side = length(side) > 1e-4 ? normalize(side) : float3(1, 0, 0);
    float3 up = cross(forward, side);
    const float2 corners[6] = { float2(-1, -1), float2(1, -1), float2(1, 1), float2(-1, -1), float2(1, 1), float2(-1, 1) };
    float3 world = centre + (side * corners[vid].x + up * corners[vid].y) * radius;

    // The copy's turn, lean and size undone: the cofactor's transpose over the determinant.
    float det = dot(c0, cross(c1, c2));
    float3x3 cofactor = float3x3(cross(c1, c2), cross(c2, c0), cross(c0, c1));
    float3x3 undo = transpose(cofactor) / det;
    float3 eye = undo * toEye;
    eye.y = max(eye.y, 0.0);
    if (length(eye) < 1e-6) eye = float3(0, 1, 0);
    const float side8 = float(impostorSide);
    float2 g = hemiOctahedral(normalize(eye)) * side8 - 0.5;
    float2 lower = clamp(floor(g), 0.0, side8 - 1), upper = min(lower + 1, side8 - 1);
    float2 f = clamp(g - lower, 0.0, 1.0);

    ImpostorOut out;
    // **Drawn at the front of the sphere**: the square pulled toward the eye until it touches the sphere's front, which
    // covers the same pixels. Every point of the surface the views baked is then behind it, so the depth the fragment
    // writes only moves away (`depth(less)`, nearer being greater) and the GPU can still reject a far picture's hidden
    // pixels before shading them. Written at any depth, the overview drew no faster with pictures than with meshes.
    float distance = length(toEye);
    float3 front = frame.cameraPosition.xyz + (world - frame.cameraPosition.xyz) * max(distance - radius, 0.01) / distance;
    out.position = frame.viewProjection * float4(front, 1);
    out.worldPosition = world;
    out.local = undo * (world - centre);
    out.views = uint4(uint(lower.y * side8 + lower.x), uint(lower.y * side8 + upper.x),
                      uint(upper.y * side8 + lower.x), uint(upper.y * side8 + upper.x));
    float4 weights = float4((1 - f.x) * (1 - f.y), f.x * (1 - f.y), (1 - f.x) * f.y, f.x * f.y);
    // A view under a twentieth is dropped and its share given to the rest: unread, it costs nothing to shade.
    weights = select(weights, float4(0), weights < 0.05);
    out.weights = weights / max(weights.x + weights.y + weights.z + weights.w, 1e-6);
    float s = sign(det);
    out.normal0 = cofactor[0] * s;
    out.normal1 = cofactor[1] * s;
    out.normal2 = cofactor[2] * s;
    out.forward = forward;
    out.radius = radius;
    out.root = copies[instance][3].xz;
    seasonOf(out.root, object.foliage, frame.weather, out.fallColour, out.fallLeaves);
    return out;
}

struct ImpostorPixel {
    float4 colour [[color(0)]];
    /// The depth of the surface the views baked, not of the square: clumps of a field overlap as their meshes do, and a
    /// tree on a slope meets the ground where its trunk does. Never nearer than the square (``impostorVertex``).
    float depth [[depth(less)]];
};

/// **A far copy's pixels**: each of its views read where this point of the square falls in it and blended, and lit with
/// the picture's normals as `propFragment` lights the mesh — the sun through its shadows (one tap, as foliage), the sky,
/// the point lights, the glint, the fog. The cut-out edge goes to coverage as a leaf's does.
///
/// **Lit, then averaged — as the mesh is.** A canopy is leaves facing every way, and the mesh lights each and lets the
/// pixel average them: mottled light and dark. A mipmap averages the normals first, and the one leaning normal it leaves
/// lit a far tree dark in its middle and bright at one edge. So four taps a view, a mip and a half finer than the pixel
/// and a quarter of a pixel apart, are each lit, and the light is averaged.
///
/// **Only the views that count are read** (``impostorVertex`` drops those under a twentieth and shares their weight out).
/// The weights are the copy's, the same over its square, so skipping one is the same choice for every pixel of it; and
/// each view's footprint is worked out from the square's own gradients, never a derivative taken inside the choice.
fragment ImpostorPixel impostorFragment(ImpostorOut in [[stage_in]],
                                 constant ObjectUniforms &object [[buffer(1)]],
                                 constant FrameUniforms &frame [[buffer(2)]],
                                 depth2d_array<float> shadowMap [[texture(1)]],
                                 texture2d_array<float> albedoMap [[texture(3)]],
                                 texture2d_array<float> normalMap [[texture(4)]],
                                 texture2d_array<float> depthMap [[texture(5)]],
                                 device const float *groundVertices [[buffer(4)]],
                                 depth2d<float> snowCover [[texture(7)]],
                                 texture2d<float> cloudMap [[texture(8)]],
                             texture3d<float> fogVolume [[texture(9)]])
{
    constexpr sampler pictures(filter::linear, mip_filter::linear, address::clamp_to_zero);
    float3 localX = dfdx(in.local), localY = dfdy(in.local);
    float texels = float(albedoMap.get_width());
    float2 uvs[4], acrosses[4], downs[4];
    float lods[4];
    // **Where the surface is**: the square through the middle moved toward the eye by the depth the views baked, so its
    // shadows, sky and fog are the canopy's surface's — looked up on the square, a tree sat in its own shadow.
    float depthSum = 0, coverageSum = 0, lod = 0;
    for (int i = 0; i < 4; i++) {
        if (in.weights[i] <= 0) continue;
        ImpostorView view = impostorView(in.views[i]);
        uvs[i] = float2(dot(in.local, view.right), dot(in.local, view.up)) * float2(0.5, -0.5) + 0.5;
        acrosses[i] = float2(dot(localX, view.right), dot(localX, view.up)) * float2(0.5, -0.5);
        downs[i] = float2(dot(localY, view.right), dot(localY, view.up)) * float2(0.5, -0.5);
        lods[i] = log2(max(max(length(acrosses[i]), length(downs[i])) * texels, 1e-6));
        lod = max(lod, lods[i]);
        gradient2d footprint(acrosses[i], downs[i]);
        depthSum += in.weights[i] * depthMap.sample(pictures, uvs[i], in.views[i], footprint).r;
        coverageSum += in.weights[i] * albedoMap.sample(pictures, uvs[i], in.views[i], footprint).a;
    }
    float a = coverageSum * (1.0 + max(lod, 0.0) * 0.25);
    float edge = 1.0;
    if (frame.shadowParams.w > 0.5) {
        edge = saturate((a - object.params.z) / max(fwidth(a), 1e-4) + 0.5);
        if (edge <= 0.0) discard_fragment();
    } else if (a < object.params.z) { discard_fragment(); }

    float toward = depthSum / max(coverageSum, 1e-4) * 2 - 1;
    float3 p = in.worldPosition + in.forward * toward * in.radius;
    float3 v = normalize(frame.cameraPosition.xyz - p);
    float3 l = frame.sunDirection.xyz;
    float3 h = normalize(l + v);
    float3x3 toWorld = float3x3(in.normal0, in.normal1, in.normal2);
    float sun = sunVisibility(frame, p, shadowMap, true) * duCloudShadow(p, frame.sunDirection.xyz, frame.weather, cloudMap);
    float sky = skyReaching(p, frame, groundVertices);
    float roughness = clamp(object.params.x, 0.05, 1.0);
    float shininess = 2.0 / (roughness * roughness * roughness * roughness) - 2.0;
    // Lying snow on the far tree's tops, as on the mesh's: whether it is open once, how much each tap faces up.
    float snowAmount = frame.weather.snow.x, open = snowAmount > 0 ? duSnowOpen(p, frame.weather, snowCover) : 0;
    float grain = open > 0 ? duSnowGrain(p) : 0;
    // Through the year, as the mesh: the picture's green turned or gone straw — the tree's numbers worked out once.
    bool seasonal = seasonsOnFoliage && in.fallColour.a > 0;

    float tapped = 0;
    float3 litSum = 0, normalSum = 0, albedoSum = 0;
    for (int i = 0; i < 4; i++) {
        float w = in.weights[i];
        if (w <= 0) continue;
        level fine(max(lods[i] - 1.5, 0.0));
        for (int t = 0; t < 4; t++) {
            float2 at = uvs[i] + acrosses[i] * ((t & 1) ? 0.25 : -0.25) + downs[i] * ((t & 2) ? 0.25 : -0.25);
            float4 colour = albedoMap.sample(pictures, at, in.views[i], fine);
            float4 packed = normalMap.sample(pictures, at, in.views[i], fine);
            float3 n = normalize(toWorld * (packed.rgb / max(packed.a, 1e-4) * 2 - 1));
            float3 albedo = colour.rgb / max(colour.a, 1e-4);
            if (seasonal) albedo = duTurnedTo(albedo, in.fallColour.rgb, in.fallColour.a * duGreenLeaf(albedo, false));
            if (open > 0) albedo = mix(albedo, duSnowColour, duSnowFacing(grain, n, snowAmount) * open);
            float nl = saturate(dot(n, l)) * sun;
            float specular = pow(saturate(dot(n, h)), shininess) * (shininess + 8.0) / (8.0 * M_PI_F) * 0.04;
            float3 lit = albedo * (frame.sunColour.rgb * nl / M_PI_F + hemisphere(n, frame) * sky)
                       + frame.sunColour.rgb * specular * nl;
            // Weighted by how much of the tap is the prop, as the mesh's samples are by its coverage.
            litSum += w * 0.25 * colour.a * lit;
            normalSum += w * 0.25 * colour.a * n;
            albedoSum += w * 0.25 * colour.rgb;
            tapped += w * 0.25 * colour.a;
        }
    }
    // A thinning tree's far picture loses its green in the same clumps as the mesh.
    if (seasonsOnFoliage && in.fallLeaves < 1.0 && duLeafness(albedoSum / max(tapped, 1e-4), false) > 0.3
        && duFallen(in.local * in.radius + float3(in.root.x, 0, in.root.y), in.fallLeaves)) discard_fragment();
    // The point lights once, from the taps' mean normal: a torch is rarely near a far tree.
    float3 n = length(normalSum) > 1e-4 ? normalize(normalSum) : v;
    float3 lit = (litSum + albedoSum * pointLighting(p, n, frame)) / max(tapped, 1e-4);
    float4 clip = frame.viewProjection * float4(p, 1);
    ImpostorPixel out;
    out.colour = float4(fogged(lit, p, frame, fogVolume), edge);
    out.depth = clip.z / clip.w;   // reversed-Z: behind the square is less
    return out;
}

// The sky is Ductane's `SkyPass` (moved there 2026-10-25).

// MARK: - Ground grid

struct GridOut {
    float4 position [[position]];
    float3 worldPosition;
};

/// A square on y = 0 around the grid's centre, from the vertex id: two triangles.
vertex GridOut gridVertex(uint id [[vertex_id]], constant FrameUniforms &frame [[buffer(2)]]) {
    const float2 corners[6] = { {-1, -1}, {1, -1}, {1, 1}, {-1, -1}, {1, 1}, {-1, 1} };
    float2 c = corners[id] * frame.grid.w + frame.grid.yz;
    GridOut out;
    out.worldPosition = float3(c.x, 0, c.y);
    out.position = frame.viewProjection * float4(out.worldPosition, 1);
    return out;
}

fragment float4 gridFragment(GridOut in [[stage_in]], constant FrameUniforms &frame [[buffer(2)]]) {
    float2 p = in.worldPosition.xz;
    float metre = gridLines(p, 1.0) * 0.25;
    float ten = gridLines(p, 10.0) * 0.55;
    float distance = length(in.worldPosition - frame.cameraPosition.xyz);
    float fade = 1.0 - smoothstep(frame.grid.x * 0.4, frame.grid.x, distance);
    // Lit as a surface would be — a dark, neutral albedo under the same sun and sky — so a prop on it is
    // judged against ground that behaves like ground, and stands out from it.
    float3 ground = 0.11 * (frame.sunColour.rgb * frame.sunDirection.y / M_PI_F + frame.skyColour.rgb);
    float3 colour = mix(ground, ground * 1.9, max(metre, ten) * fade);
    // Into the horizon, so the edge of the square is never seen.
    float edge = smoothstep(frame.grid.x * 0.6, frame.grid.x, distance);
    return float4(mix(colour, frame.horizonColour.rgb, edge), 1);
}

// MARK: - A prop's shape

/// **A prop's own shape, for an editor's outline** (`WorldRenderer.encodeSilhouette`): 1 wherever it covers, its cut-outs
/// cut exactly as the scene cuts them — so a tree's outline follows its leaves, not its cards.
fragment float4 silhouetteFragment(VertexOut in [[stage_in]],
                                      constant ObjectUniforms &object [[buffer(1)]],
                                      texture2d<float> baseMap [[texture(0)]])
{
    constexpr sampler linear(filter::linear, mip_filter::linear, address::repeat);
    if (object.params.z > 0 && object.baseColour.a * baseMap.sample(linear, in.uv).a < object.params.z) discard_fragment();
    return float4(1);
}

// MARK: - Water

struct WaterOut {
    float4 position [[position]];
    float3 worldPosition;
    float4 look;   // the body's own colour (linear) and opacity
};

/// Must match `WorldRenderer.WaterCorner`.
struct WaterCorner {
    float4 position;
    float4 look;
};

/// Every body of water's surface, six corners to a rectangle, each already at its body's level and carrying its body's
/// look — so the whole of a scene's water is one draw however many ponds it has (`WorldFile.Water`).
vertex WaterOut waterVertex(uint id [[vertex_id]],
                            const device WaterCorner *corners [[buffer(0)]],
                            constant FrameUniforms &frame [[buffer(2)]]) {
    WaterCorner corner = corners[id];
    WaterOut out;
    out.worldPosition = corner.position.xyz;
    out.position = frame.viewProjection * corner.position;
    out.look = corner.look;
    return out;
}

/// **What water mirrors** (`GraphicsSettings.reflections`): the ray off the surface marched across the solid scene as
/// drawn (Ductane's `OpaqueTextures`), in steps that lengthen with distance, until it passes behind something — then
/// refined, and that pixel is what the water shows. Depth is reversed and infinite, so a depth `d` is the near plane over
/// the distance. A ray that meets nothing takes the sky as drawn while it is still on screen, and `sky` where it has left
/// it. Faded toward the screen's edges, where what would be reflected is not in the picture.
///
/// **Cheap where it can be**: steps start at a hundredth of the water's distance from the eye, the march gives up past
/// 150 m, and a surface looked down on — where Fresnel shows almost none of the reflection (`worth` under 0.12) — takes
/// `sky` without marching. With reflections off (`frame.sunDirection.w` 0) it is `sky`, as water was before.
static float3 reflectedScene(float3 p, float3 r, float worth, float3 sky, constant FrameUniforms &frame,
                             texture2d<float> colour, depth2d<float> depth) {
    const float nearPlane = frame.sunDirection.w;
    if (nearPlane <= 0.0 || worth < 0.12) return sky;
    constexpr sampler linear(filter::linear, address::clamp_to_edge);
    constexpr sampler nearest(filter::nearest, address::clamp_to_edge);
    // Never down into the water: a ripple steep enough to send the ray under the surface still reflects the bank.
    float3 dir = normalize(float3(r.x, max(r.y, 0.02), r.z));
    auto project = [&](float distance, thread float &w) {
        float4 clip = frame.viewProjection * float4(p + dir * distance, 1.0);
        w = clip.w;
        return float2(clip.x / clip.w * 0.5 + 0.5, 0.5 - clip.y / clip.w * 0.5);
    };
    auto edgeFade = [](float2 uv) {
        float2 edge = smoothstep(0.0, 0.08, uv) * smoothstep(0.0, 0.08, 1.0 - uv);
        return edge.x * edge.y;
    };
    float step = max(0.3, 0.015 * distance(p, frame.cameraPosition.xyz));
    float t = step, previous = 0.0;
    float2 lastUV = float2(-1.0);
    for (int i = 0; i < 20 && t < 150.0; i++) {
        float w;
        float2 uv = project(t, w);
        if (w <= nearPlane || any(uv < 0.0) || any(uv > 1.0)) break;
        lastUV = uv;
        float d = depth.sample(nearest, uv);
        float behind = d > 0.0 ? w - nearPlane / d : -1.0;
        if (behind > 0.0 && behind < max(step * 1.5, 0.3)) {
            // Between the last step in front and this one behind: halve it four times.
            float lo = previous, hi = t;
            for (int k = 0; k < 4; k++) {
                float mid = 0.5 * (lo + hi), wm;
                float2 um = project(mid, wm);
                float dm = depth.sample(nearest, um);
                if (dm > 0.0 && wm > nearPlane / dm) { hi = mid; } else { lo = mid; }
            }
            float wh;
            float2 hit = project(hi, wh);
            return mix(sky, colour.sample(linear, hit).rgb, edgeFade(hit));
        }
        previous = t;
        t += step;
        step *= 1.25;
    }
    // Nothing solid in the way: the sky as drawn, while the ray is still on screen.
    if (lastUV.x >= 0.0 && depth.sample(nearest, lastUV) <= 0.0) {
        return mix(sky, colour.sample(linear, lastUV).rgb, edgeFade(lastUV));
    }
    return sky;
}

/// The height of still water's faint ripple at a point, 0…1.75: three octaves of value noise, the finer turned against
/// the coarser so no direction lines up.
static float waterRipple(float2 p) {
    return duValueNoise(p * 0.8) + 0.5 * duValueNoise(p * 2.1 + 17.3) + 0.25 * duValueNoise(float2(p.y, -p.x) * 4.7 + 5.1);
}

/// Water as an eye judges it: its own deep color looking down, the sky reflected looking across
/// (Fresnel), and the sun's glint. **Flat, with no waves** — enough to read where the shore is and how
/// the light falls on it; moving water is a look for later.
fragment float4 waterFragment(WaterOut in [[stage_in]],
                              constant ObjectUniforms &object [[buffer(1)]],
                              constant FrameUniforms &frame [[buffer(2)]],
                              texture2d<float> solidColour [[texture(3)]],
                              depth2d<float> solidDepth [[texture(6)]],
                             texture3d<float> fogVolume [[texture(9)]]) {
    // A faint ripple in the normal, so the glint breaks up instead of being a disc: the slope of three octaves of value
    // noise, which never repeats. Two crossed sine waves did this until 2026-11-20 — an egg-crate a few metres across that,
    // looked across at a low angle, the reflection picked out as rows of round blobs. Where a ripple is smaller than a pixel
    // it only shimmers, so it fades as the surface recedes.
    float2 p = in.worldPosition.xz;
    const float e = 0.04;
    float h = waterRipple(p);
    float2 slope = float2(waterRipple(p + float2(e, 0)) - h, waterRipple(p + float2(0, e)) - h) / e;
    float strength = 0.012 * (1.0 - smoothstep(0.12, 0.6, length(fwidth(p))));
    float3 n = normalize(float3(-slope.x * strength, 1, -slope.y * strength));
    float3 v = normalize(frame.cameraPosition.xyz - in.worldPosition);
    float facing = saturate(dot(n, v));
    float fresnel = 0.02 + 0.98 * pow(1.0 - facing, 5.0);

    float3 r = reflect(-v, n);
    float3 sky = mix(frame.horizonColour.rgb, frame.skyColour.rgb * 1.6, pow(saturate(r.y), 0.6));
    sky = reflectedScene(in.worldPosition, r, fresnel, sky, frame, solidColour, solidDepth);
    float3 l = frame.sunDirection.xyz;
    float glint = pow(saturate(dot(r, l)), 600.0) * 6.0 * step(0.0, l.y);

    float3 body = in.look.rgb * (frame.sunColour.rgb * saturate(l.y) / M_PI_F + frame.skyColour.rgb);
    float3 colour = mix(body, sky, fresnel) + frame.sunColour.rgb * glint;
    float alpha = mix(in.look.a, 1.0, fresnel);
    return float4(fogged(colour, in.worldPosition, frame, fogVolume), alpha);
}

/// Must match `WorldRenderer.StreamVertex`.
struct StreamVertex {
    float4 position;   // xyz; w: metres along the course
    float4 flow;       // xy: the way it runs (x, z); z: how white; w: how fast, m/s
    float4 extra;      // x: which bank, −1 or 1; y: the stream's length
};

struct StreamOut {
    float4 position [[position]];
    float3 worldPosition;
    float along;
    float2 heading;
    float whiteness;
    float speed;
    float side;
    float length;
};

/// Every stream's surface, three corners to a triangle, already where it runs (`WorldFile.Stream`).
vertex StreamOut streamVertex(uint id [[vertex_id]],
                              const device StreamVertex *vertices [[buffer(0)]],
                              constant FrameUniforms &frame [[buffer(2)]]) {
    StreamVertex v = vertices[id];
    StreamOut out;
    out.worldPosition = v.position.xyz;
    out.position = frame.viewProjection * float4(v.position.xyz, 1);
    out.along = v.position.w;
    out.heading = v.flow.xy;
    out.whiteness = v.flow.z;
    out.speed = v.flow.w;
    out.side = v.extra.x;
    out.length = v.extra.y;
    return out;
}

/// **Running water** (`WorldFile.Stream`): `waterFragment`'s light — its deep colour looking down, the sky looking across, the
/// sun's glint — over a surface that moves. Ripples and streaks are carried down the course at the water's own speed
/// (`object.params.x` is the time), so a stream is seen to run; **it turns white where it is steep**, foam breaking
/// across it the more it tumbles, and a line of it along each bank. It fades in at its source and out at its mouth.
fragment float4 streamFragment(StreamOut in [[stage_in]],
                               constant ObjectUniforms &object [[buffer(1)]],
                               constant FrameUniforms &frame [[buffer(2)]],
                             texture2d<float> solidColour [[texture(3)]],
                               depth2d<float> solidDepth [[texture(6)]],
                             texture3d<float> fogVolume [[texture(9)]]) {
    float t = object.params.x;
    float2 h = length(in.heading) > 1e-4 ? normalize(in.heading) : float2(0, 1);
    float2 across = float2(-h.y, h.x);
    // Coordinates that run with the water: across in metres, along in metres less how far it has run.
    float u = dot(in.worldPosition.xz, across);
    float v = in.along - in.speed * t;

    float r1 = duValueNoise(float2(u * 1.7, v * 0.9)) - 0.5;
    float r2 = duValueNoise(float2(u * 3.3 + 7.0, v * 2.1)) - 0.5;
    float rough = 0.18 + 0.3 * in.whiteness;
    float2 slope = (across * r1 + h * r2) * rough;
    float3 n = normalize(float3(slope.x, 1, slope.y));
    float3 eye = normalize(frame.cameraPosition.xyz - in.worldPosition);
    float fresnel = 0.02 + 0.98 * pow(1.0 - saturate(dot(n, eye)), 5.0);
    float3 r = reflect(-eye, n);
    float3 sky = mix(frame.horizonColour.rgb, frame.skyColour.rgb * 1.6, pow(saturate(r.y), 0.6));
    sky = reflectedScene(in.worldPosition, r, fresnel, sky, frame, solidColour, solidDepth);
    float3 l = frame.sunDirection.xyz;
    float glint = pow(saturate(dot(r, l)), 400.0) * 4.0 * step(0.0, l.y);
    float3 light = frame.sunColour.rgb * saturate(l.y) / M_PI_F + frame.skyColour.rgb;
    float3 body = object.baseColour.rgb * light;

    // Streaks drawn out along the current, so the flow reads from far off where ripples are too small to see.
    float streaks = smoothstep(0.62, 0.82, duValueNoise(float2(u * 4.0, v * 0.3))) * 0.3;
    // White water: broken foam, more of it the steeper the stream, and a ragged line along each bank.
    float churn = duValueNoise(float2(u * 2.4, v * 1.3)) * 0.6 + duValueNoise(float2(u * 6.1 + 3.0, v * 3.4)) * 0.4;
    // Never solid, even at its whitest: broken foam with dark water between, as a tumbling stream is.
    float threshold = mix(1.05, 0.4, in.whiteness);
    float foam = smoothstep(threshold, threshold + 0.16, churn);
    float bank = smoothstep(0.72, 0.98, abs(in.side)) * smoothstep(0.35, 0.65, duValueNoise(float2(u * 3.0, v * 1.5)));
    foam = saturate(max(foam, bank * 0.55) + streaks * (1.0 - in.whiteness));

    float3 colour = mix(body, sky, fresnel) + frame.sunColour.rgb * glint;
    float alpha = mix(object.baseColour.a, 1.0, fresnel);
    colour = mix(colour, float3(0.86, 0.89, 0.88) * light, foam);
    alpha = mix(alpha, 0.95, foam);
    // Fading in from its source and out into the water at its mouth, and softly at its banks.
    alpha *= smoothstep(0.0, 1.5, in.along) * smoothstep(0.0, 1.5, in.length - in.along);
    alpha *= 1.0 - smoothstep(0.85, 1.0, abs(in.side)) * 0.5;
    return float4(fogged(colour, in.worldPosition, frame, fogVolume), alpha);
}


// MARK: - Fog over the sky




