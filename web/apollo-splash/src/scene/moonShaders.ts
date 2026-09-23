// GLSL for the moon. Two passes:
//
// 1. BAKE (once, at startup): procedurally builds an equirectangular map of
//    the lunar surface — R albedo, G height, B maria mask. Craters are 3D
//    cellular features (no seams, no pole pinching); the maria are hand-
//    placed basins at their real selenographic positions so the disc reads
//    as *our* moon, not a generic grey ball.
// 2. SHADE (every frame): lights the sphere with a lunar-Lambert BRDF,
//    bump-maps the baked height, and adds cyan earthshine on the night side.
//    Only texture reads + a handful of ALU ops per pixel.

export const FULLSCREEN_VERT = /* glsl */ `#version 300 es
in vec2 aPos;
out vec2 vUv;
void main() {
  vUv = aPos * 0.5 + 0.5;
  gl_Position = vec4(aPos, 0.0, 1.0);
}`;

const NOISE = /* glsl */ `
float hash13(vec3 p) {
  p = fract(p * 0.1031);
  p += dot(p, p.zyx + 31.32);
  return fract((p.x + p.y) * p.z);
}
vec3 hash33(vec3 p) {
  p = fract(p * vec3(0.1031, 0.1030, 0.0973));
  p += dot(p, p.yxz + 33.33);
  return fract((p.xxy + p.yxx) * p.zyx);
}
float vnoise(vec3 p) {
  vec3 i = floor(p);
  vec3 f = fract(p);
  vec3 u = f * f * (3.0 - 2.0 * f);
  float n000 = hash13(i);
  float n100 = hash13(i + vec3(1, 0, 0));
  float n010 = hash13(i + vec3(0, 1, 0));
  float n110 = hash13(i + vec3(1, 1, 0));
  float n001 = hash13(i + vec3(0, 0, 1));
  float n101 = hash13(i + vec3(1, 0, 1));
  float n011 = hash13(i + vec3(0, 1, 1));
  float n111 = hash13(i + vec3(1, 1, 1));
  return mix(
    mix(mix(n000, n100, u.x), mix(n010, n110, u.x), u.y),
    mix(mix(n001, n101, u.x), mix(n011, n111, u.x), u.y),
    u.z);
}
float fbm(vec3 p) {
  float sum = 0.0;
  float amp = 0.5;
  for (int i = 0; i < 6; i++) {
    sum += amp * vnoise(p);
    p = p * 2.07 + vec3(17.1, 3.7, 9.2);
    amp *= 0.5;
  }
  return sum;
}
`;

export const BAKE_FRAG = /* glsl */ `#version 300 es
precision highp float;
in vec2 vUv;
out vec4 outColor;

const float PI = 3.14159265359;
${NOISE}

vec3 dirFromLonLat(float lonDeg, float latDeg) {
  float lon = radians(lonDeg);
  float lat = radians(latDeg);
  return vec3(cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon));
}

// Ragged basin edge. \`w\` is a domain-warped surface point, so shorelines
// come out organic instead of following the noise lattice. Returns 0…1.
float basin(vec3 w, vec3 c, float r, float ragged) {
  float d = length(w - c);
  float edge = (fbm(w * 4.0 + c * 3.0) - 0.5) * ragged + (fbm(w * 19.0 + c) - 0.5) * 0.06;
  return 1.0 - smoothstep(r - 0.03, r + 0.02, d + edge);
}

// One octave of cellular craters. Returns (height, albedo boost).
vec2 craterOctave(vec3 p, float scale, float density, float depth, float seed) {
  vec3 q = p * scale;
  vec3 id = floor(q);
  vec2 acc = vec2(0.0);
  for (int z = -1; z <= 1; z++)
  for (int y = -1; y <= 1; y++)
  for (int x = -1; x <= 1; x++) {
    vec3 cell = id + vec3(x, y, z);
    if (hash13(cell * 1.37 + seed) > density) continue;
    vec3 centre = (cell + hash33(cell + seed)) / scale;
    float radius = mix(0.16, 0.44, pow(hash13(cell * 2.91 + seed), 1.6)) / scale;
    float d = length(p - centre) / radius;
    if (d > 2.4) continue;
    float bowl = d < 1.0 ? (d * d - 1.0) * 0.9 : 0.0;
    float rim = exp(-pow((d - 1.0) / 0.2, 2.0)) * 0.42;
    float ejecta = d > 1.0 ? exp(-(d - 1.0) * 2.6) * 0.07 : 0.0;
    float peak = radius * scale > 0.36 ? exp(-d * d * 60.0) * 0.35 : 0.0;
    acc.x += (bowl + rim + ejecta + peak) * depth / scale;
    // Young craters read as bright splashes (floor + ejecta), not rings.
    float fresh = pow(1.0 - hash13(cell * 4.13 + seed), 4.0);
    acc.y += fresh * 0.18 * exp(-d * d * 0.9);
  }
  return acc;
}

// Bright ray system around a young crater (Tycho, Copernicus).
float rays(vec3 p, vec3 c, float reach, float seed) {
  vec3 v = p - c;
  float d = length(v);
  vec3 e1 = normalize(cross(c, vec3(0.0, 1.0, 0.0)));
  vec3 e2 = cross(c, e1);
  float a = atan(dot(v, e1), dot(v, e2));
  float streak = pow(vnoise(vec3(cos(a) * 7.0, sin(a) * 7.0, seed)), 5.0) * 3.2;
  return streak * exp(-d / reach) * smoothstep(0.02, 0.06, d);
}

void main() {
  float lon = (vUv.x * 2.0 - 1.0) * PI;
  float lat = (vUv.y - 0.5) * PI;
  vec3 p = vec3(cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon));

  // Maria — the dark basaltic plains, at their real near-side positions.
  vec3 w = p + (vec3(fbm(p * 2.3), fbm(p * 2.3 + 7.1), fbm(p * 2.3 + 13.7)) - 0.5) * 0.22;
  float maria = 0.0;
  maria = max(maria, basin(w, dirFromLonLat(-57.0, 18.0), 0.50, 0.34)); // Procellarum
  maria = max(maria, basin(w, dirFromLonLat(-16.0, 33.0), 0.32, 0.16)); // Imbrium
  maria = max(maria, basin(w, dirFromLonLat( 17.0, 28.0), 0.20, 0.10)); // Serenitatis
  maria = max(maria, basin(w, dirFromLonLat( 31.0,  8.0), 0.24, 0.18)); // Tranquillitatis
  maria = max(maria, basin(w, dirFromLonLat( 59.0, 17.0), 0.12, 0.05)); // Crisium
  maria = max(maria, basin(w, dirFromLonLat( 51.0, -8.0), 0.16, 0.14)); // Fecunditatis
  maria = max(maria, basin(w, dirFromLonLat(-17.0,-21.0), 0.18, 0.16)); // Nubium
  maria = max(maria, basin(w, dirFromLonLat(-39.0,-24.0), 0.10, 0.06)); // Humorum
  maria = max(maria, basin(w, dirFromLonLat( 34.0,-15.0), 0.09, 0.06)); // Nectaris
  maria = max(maria, basin(w, dirFromLonLat(  5.0, 57.0), 0.12, 0.30) * 0.8); // Frigoris
  // Large-scale mottling so neither terrain reads flat.
  float mottling = fbm(p * 3.1);
  maria *= smoothstep(0.25, 0.55, mottling + 0.2);

  // Craters: four octaves, densest and shallowest at the small end.
  // Maria are younger and smoother, so they keep fewer small craters.
  vec2 c0 = craterOctave(p, 3.0, 0.14, 0.55, 1.0) * (1.0 - maria * 0.5);
  vec2 c1 = craterOctave(p, 7.0, 0.18, 0.45, 2.0) * (1.0 - maria * 0.6);
  vec2 c2 = craterOctave(p, 16.0, 0.24, 0.36, 3.0) * (1.0 - maria * 0.7);
  vec2 c3 = craterOctave(p, 38.0, 0.34, 0.28, 4.0) * (1.0 - maria * 0.8);
  vec2 c4 = craterOctave(p, 84.0, 0.42, 0.22, 5.0) * (1.0 - maria * 0.6);
  vec2 craters = c0 + c1 + c2 + c3 + c4;

  // Mountain arcs (Apennines, Carpathians…) ring the big impact basins, and
  // the highlands get ridged roughness — relief that only the low sun near
  // the terminator reveals.
  float ridged = 1.0 - abs(fbm(p * 13.0 + 3.0) * 2.0 - 1.0);
  float rings = 0.0;
  rings += exp(-pow((length(w - dirFromLonLat(-16.0, 33.0)) - 0.34) / 0.035, 2.0));
  rings += exp(-pow((length(w - dirFromLonLat( 17.0, 28.0)) - 0.22) / 0.025, 2.0));
  rings += exp(-pow((length(w - dirFromLonLat( 59.0, 17.0)) - 0.135) / 0.02, 2.0));
  rings += exp(-pow((length(w - dirFromLonLat(-39.0,-24.0)) - 0.115) / 0.02, 2.0));
  float mountains = rings * pow(ridged, 3.0) * 0.05;
  float roughness = pow(ridged, 4.0) * 0.012 * (1.0 - maria);
  float height = craters.x + mountains + roughness + (fbm(p * 11.0) - 0.5) * 0.012 - maria * 0.01;

  // Highlands vs maria is the dominant contrast of the real near side.
  float albedo = mix(0.80, 0.30, maria);
  albedo *= 0.80 + 0.34 * fbm(p * 7.0 + 4.0);
  // Lava flows of different ages give the maria their own mottling.
  albedo *= 1.0 + maria * (fbm(w * 9.0 + 2.0) - 0.5) * 0.55;
  albedo *= 0.92 + 0.16 * fbm(p * 41.0);
  albedo += craters.y;
  albedo += rays(p, dirFromLonLat(-11.0, -43.0), 0.55, 11.0) * 0.20; // Tycho
  albedo += rays(p, dirFromLonLat(-20.0,  10.0), 0.22, 23.0) * 0.14; // Copernicus
  albedo += rays(p, dirFromLonLat(-38.0,   8.0), 0.12, 37.0) * 0.10; // Kepler
  albedo = clamp(albedo, 0.0, 1.0);

  // Height is stored offset/scaled so an RGBA8 fallback target keeps the
  // negative bowl values; the shade pass only ever reads differences.
  outColor = vec4(albedo, height * 2.0 + 0.5, maria, 1.0);
}`;

export const SHADE_FRAG = /* glsl */ `#version 300 es
precision highp float;
in vec2 vUv;
out vec4 outColor;

uniform sampler2D uMap;
uniform vec2 uTexel;
uniform vec3 uSun;
uniform float uSpin;
uniform float uExposure;
uniform float uAlpha;
uniform float uPixel;
uniform float uTerminatorShift;
uniform vec3 uEarthshine;

const float PI = 3.14159265359;
${NOISE}

float heightAt(vec2 uv) { return (texture(uMap, uv).g - 0.5) * 0.5; }

mat3 rotY(float a) { float c = cos(a), s = sin(a); return mat3(c, 0.0, -s, 0.0, 1.0, 0.0, s, 0.0, c); }
mat3 rotX(float a) { float c = cos(a), s = sin(a); return mat3(1.0, 0.0, 0.0, 0.0, c, s, 0.0, -s, c); }

vec2 uvOf(vec3 p) {
  return vec2(atan(p.x, p.z) / (2.0 * PI) + 0.5, asin(clamp(p.y, -1.0, 1.0)) / PI + 0.5);
}

float dither(vec2 frag) {
  return fract(52.9829189 * fract(dot(frag, vec2(0.06711056, 0.00583715)))) - 0.5;
}

void main() {
  vec2 d = vUv * 2.0 - 1.0;
  float r = length(d);
  // Analytic anti-aliased limb — no MSAA needed.
  float cover = 1.0 - smoothstep(1.0 - uPixel * 1.6, 1.0, r);
  if (cover <= 0.0) { outColor = vec4(0.0); return; }

  float z = sqrt(max(0.0, 1.0 - min(r * r, 1.0)));
  vec3 n = vec3(d, z);

  // Libration tilt + slow spin so craters drift across the terminator.
  mat3 R = rotX(0.10) * rotY(uSpin);
  vec3 p = R * n;
  vec2 uv = uvOf(p);

  vec4 s = texture(uMap, uv);
  float hE = texture(uMap, uv + vec2(uTexel.x, 0.0)).g - texture(uMap, uv - vec2(uTexel.x, 0.0)).g;
  float hN = texture(uMap, uv + vec2(0.0, uTexel.y)).g - texture(uMap, uv - vec2(0.0, uTexel.y)).g;
  float cosLat = max(sqrt(1.0 - p.y * p.y), 0.08);
  vec3 east = normalize(vec3(p.z, 0.0, -p.x) + vec3(1e-5, 0.0, 0.0));
  vec3 north = cross(p, east);
  float dLon = 2.0 * uTexel.x * 2.0 * PI;
  float dLat = 2.0 * uTexel.y * PI;
  vec3 grad = (east * (hE / (dLon * cosLat)) + north * (hN / dLat)) * 0.5;
  // Procedural micro-relief below the texture's resolution: regolith and
  // tiny craterlets that sparkle along the terminator at any window size.
  vec3 micro = (vec3(vnoise(p * 260.0), vnoise(p * 260.0 + 17.0), vnoise(p * 260.0 + 41.0)) - 0.5)
             + 0.5 * (vec3(vnoise(p * 610.0), vnoise(p * 610.0 + 7.0), vnoise(p * 610.0 + 29.0)) - 0.5);
  micro -= dot(micro, p) * p;
  vec3 bumped = normalize(p - grad * 0.8 - micro * 0.07);
  vec3 nb = transpose(R) * bumped;

  vec3 L = normalize(uSun);

  // Art-directed terminator: the same ellipse a real sphere would show at
  // this phase (same curvature), slid toward the night side by
  // uTerminatorShift radii so more of the disc is lit. All lighting uses this
  // "light normal" (plus the bump detail); texture lookups stay physical.
  vec2 dl = vec2(d.x + uTerminatorShift, d.y);
  float rl2 = dot(dl, dl);
  // Beyond the shifted disc edge (only ever on the lit side) → fully facing the sun.
  vec3 nL = rl2 < 1.0 ? vec3(dl, sqrt(1.0 - rl2)) : normalize(vec3(dl, 0.0));
  float facing = dot(nL, L);
  vec3 nbL = normalize(nL + (nb - n));

  // Cast shadows: march the height field toward the sun. Only where the sun
  // is low — the terminator band — which is exactly where shadows are long
  // and where the eye looks during the phase sweep.
  vec3 Ls = R * L;
  float elevation = facing;
  float shadow = 1.0;
  if (elevation > -0.04 && elevation < 0.3) {
    vec2 toward = vec2(dot(Ls, east), dot(Ls, north));
    float run = max(length(toward), 1e-3);
    vec2 dirUv = (toward / run) * vec2(1.0 / (2.0 * PI * cosLat), 1.0 / PI);
    float slope = elevation / run;
    float h0 = heightAt(uv);
    for (int i = 1; i <= 18; i++) {
      float dist = 0.0016 * pow(float(i), 1.55);
      float ray = h0 + dist * slope;
      float ground = heightAt(uv + dirUv * dist);
      // Lit whenever the ray clears the ground; only real occluders darken.
      shadow = min(shadow, smoothstep(-0.004, 0.0, ray - ground));
    }
    // Fade the effect out before the band ends so there is no seam.
    shadow = mix(shadow, 1.0, smoothstep(0.18, 0.3, elevation));
  }
  float mu0 = dot(nbL, L);
  float lambert = max(mu0, 0.0);
  float lommel = lambert / (lambert + max(z, 0.05));
  // Mostly Lommel–Seeliger: like the real moon, relief flattens out under a
  // high sun and only reads strongly near the terminator.
  float brdf = mix(lambert, 2.0 * lommel, 0.85);
  // Crater peaks may catch light just past the terminator, as on the real moon.
  brdf *= smoothstep(-0.052, 0.039, facing) * shadow;

  float albedo = s.r;
  float maria = s.b;
  vec3 highland = vec3(0.50, 0.49, 0.475);
  vec3 mare = vec3(0.43, 0.45, 0.49);
  vec3 base = mix(highland, mare, maria) * albedo;

  vec3 sun = vec3(1.0, 0.975, 0.94) * 1.75 * uExposure;
  vec3 col = base * brdf * sun;

  // The night half sits in the same blue-grey as the sky around it (so it
  // reads as shadow, not a hole), with faint albedo so the maria still
  // whisper through, plus a cyan hairline on the dark limb — the one
  // brand-coloured light in the scene.
  float night = 1.0 - smoothstep(-0.156, 0.052, facing);
  // Applied everywhere, so crater shadows on the lit half match it too.
  col += uEarthshine * (0.7 + 0.55 * albedo);
  col += vec3(0.012, 0.035, 0.05) * pow(1.0 - z, 6.0) * night;

  // Filmic shoulder, then sRGB.
  col = col / (1.0 + col * 0.42);
  col = pow(max(col, 0.0), vec3(1.0 / 2.2));
  col += dither(gl_FragCoord.xy) / 255.0;

  float a = cover * uAlpha;
  outColor = vec4(col * a, a);
}`;
