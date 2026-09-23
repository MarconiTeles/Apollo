// Drifting interstellar gas, in the spirit of Webb's NebulaField: fbm with
// two levels of domain warping, rendered at a fraction of the window's
// resolution so the browser's upscale does the blurring for free.
//
// Two instances run with different settings:
// - "veil": the deep nebula behind the stars, slow and wide;
// - "mist": thin, faster wisps in front of the moon, so the disc sits
//   *inside* the atmosphere instead of on top of a wallpaper.

const VERT = /* glsl */ `#version 300 es
in vec2 aPos;
void main() { gl_Position = vec4(aPos, 0.0, 1.0); }`;

const FRAG = /* glsl */ `#version 300 es
precision mediump float;
out vec4 outColor;

uniform vec2 uResolution;
uniform float uTime;
uniform vec2 uCore;
uniform float uCoreRadius;
uniform float uReveal;
uniform float uMist;
uniform vec3 uTintA;
uniform vec3 uTintB;
uniform vec3 uGlow;

float hash(vec2 p) { p = fract(p * vec2(123.34, 456.21)); p += dot(p, p + 45.32); return fract(p.x * p.y); }
float noise(vec2 p) {
  vec2 i = floor(p), f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}
float fbm(vec2 p) {
  float v = 0.0, a = 0.5;
  mat2 m = mat2(1.6, 1.2, -1.2, 1.6);
  for (int i = 0; i < 5; i++) { v += a * noise(p); p = m * p; a *= 0.5; }
  return v;
}

void main() {
  vec2 uv = gl_FragCoord.xy / uResolution;
  uv.y = 1.0 - uv.y;
  float aspect = uResolution.x / uResolution.y;
  vec2 p = (uv - 0.5) * vec2(aspect, 1.0) * mix(2.2, 3.4, uMist);
  float t = uTime * mix(0.022, 0.06, uMist);
  // The mist also slides sideways, so it visibly passes in front of the moon.
  p.x -= uTime * 0.035 * uMist;

  vec2 q = vec2(fbm(p + t), fbm(p + vec2(5.2, 1.3) - t * 0.7));
  vec2 r = vec2(fbm(p + 1.6 * q + vec2(1.7, 9.2) + t * 0.5), fbm(p + 1.6 * q + vec2(8.3, 2.8) - t * 0.3));
  float f = fbm(p + 1.4 * r);

  vec2 d = (uv - uCore) * vec2(aspect, 1.0);
  float core = exp(-dot(d, d) / (uCoreRadius * uCoreRadius));

  vec3 color;
  float a;
  if (uMist < 0.5) {
    float band = smoothstep(0.30, 0.80, f);
    float veil = smoothstep(1.45, 0.3, length((uv - 0.5) * vec2(aspect, 1.0)));
    color = mix(uTintA, uTintB, smoothstep(0.35, 0.75, r.x)) * (band * 1.35 + f * 0.35) * mix(0.45, 1.0, veil);
    color += uGlow * core * (0.35 + band * 0.9);
    a = clamp(band * 0.85 + core * 0.55 + 0.1, 0.0, 1.0) * mix(0.5, 1.0, veil);
  } else {
    // Wisps: only the densest filaments, brightest where moonlight hits them.
    float wisp = smoothstep(0.52, 0.86, f) * smoothstep(0.1, 0.6, uv.y);
    color = mix(uTintB, uGlow, core * 0.8) * (0.6 + wisp);
    a = wisp * (0.28 + core * 0.5);
  }
  a *= uReveal;
  outColor = vec4(color * a, a);
}`;

export type NebulaOptions = {
  mode: "veil" | "mist";
  /** Backing-store scale relative to CSS pixels. Lower = softer + cheaper. */
  scale: number;
};

// Lunar palette: steel blue and a teal nod to the icon, lit by cold moonlight.
const TINT_A: [number, number, number] = [0.085, 0.12, 0.19];
const TINT_B: [number, number, number] = [0.05, 0.17, 0.2];
const GLOW: [number, number, number] = [0.3, 0.42, 0.56];

export class NebulaRenderer {
  private readonly gl: WebGL2RenderingContext;
  private readonly program: WebGLProgram;
  private readonly u: Record<string, WebGLUniformLocation | null>;
  private width = 1;
  private height = 1;

  static create(canvas: HTMLCanvasElement, options: NebulaOptions) {
    const gl = canvas.getContext("webgl2", {
      alpha: true,
      premultipliedAlpha: true,
      antialias: false,
      depth: false,
      stencil: false,
      powerPreference: "low-power",
    });
    if (!gl) return null;
    try {
      return new NebulaRenderer(gl, options);
    } catch (error) {
      console.error(error);
      return null;
    }
  }

  private constructor(
    gl: WebGL2RenderingContext,
    private readonly options: NebulaOptions,
  ) {
    this.gl = gl;
    const compile = (type: number, source: string) => {
      const shader = gl.createShader(type)!;
      gl.shaderSource(shader, source);
      gl.compileShader(shader);
      if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
        throw new Error(`Nebula shader: ${gl.getShaderInfoLog(shader)}`);
      }
      return shader;
    };
    const program = gl.createProgram()!;
    gl.attachShader(program, compile(gl.VERTEX_SHADER, VERT));
    gl.attachShader(program, compile(gl.FRAGMENT_SHADER, FRAG));
    gl.bindAttribLocation(program, 0, "aPos");
    gl.linkProgram(program);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
      throw new Error(`Nebula link: ${gl.getProgramInfoLog(program)}`);
    }
    this.program = program;
    gl.useProgram(program);

    const vao = gl.createVertexArray();
    gl.bindVertexArray(vao);
    gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
    gl.enableVertexAttribArray(0);
    gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);

    const names = ["uResolution", "uTime", "uCore", "uCoreRadius", "uReveal", "uMist", "uTintA", "uTintB", "uGlow"];
    this.u = Object.fromEntries(names.map((name) => [name, gl.getUniformLocation(program, name)]));
    gl.uniform1f(this.u.uMist, options.mode === "mist" ? 1 : 0);
    gl.uniform3f(this.u.uTintA, ...TINT_A);
    gl.uniform3f(this.u.uTintB, ...TINT_B);
    gl.uniform3f(this.u.uGlow, ...GLOW);
  }

  resize(cssWidth: number, cssHeight: number) {
    const canvas = this.gl.canvas as HTMLCanvasElement;
    this.width = Math.max(2, Math.round(cssWidth * this.options.scale));
    this.height = Math.max(2, Math.round(cssHeight * this.options.scale));
    canvas.width = this.width;
    canvas.height = this.height;
    canvas.style.width = `${cssWidth}px`;
    canvas.style.height = `${cssHeight}px`;
  }

  /** `core` is the moon centre in 0…1 viewport space; `radius` in viewport heights. */
  draw(time: number, reveal: number, core: { x: number; y: number }, radius: number) {
    const { gl, u } = this;
    gl.viewport(0, 0, this.width, this.height);
    gl.clearColor(0, 0, 0, 0);
    gl.clear(gl.COLOR_BUFFER_BIT);
    if (reveal <= 0.001) return;
    gl.uniform2f(u.uResolution, this.width, this.height);
    gl.uniform1f(u.uTime, time);
    gl.uniform2f(u.uCore, core.x, core.y);
    gl.uniform1f(u.uCoreRadius, radius);
    gl.uniform1f(u.uReveal, reveal);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  }

  dispose() {
    this.gl.deleteProgram(this.program);
    this.gl.getExtension("WEBGL_lose_context")?.loseContext();
  }
}
