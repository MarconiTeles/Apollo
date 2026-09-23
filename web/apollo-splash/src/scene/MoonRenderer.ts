import { BAKE_FRAG, FULLSCREEN_VERT, SHADE_FRAG } from "./moonShaders";

const MAP_WIDTH = 2048;
const MAP_HEIGHT = 1024;
/**
 * Direction the light comes from, measured up from the horizontal. 0 puts
 * the sun exactly to the right, so the terminator stands perfectly vertical.
 */
const LIGHT_ANGLE = 0;
/**
 * Slides the terminator toward the night side, in disc radii, keeping its
 * curvature. 0.26 lights ~33% of the disc at the resting phase (vs ~17% for
 * a physical sphere) — i.e. 20% less of the disc in shadow.
 */
const TERMINATOR_SHIFT = 0.26;
/**
 * Night-side ambient, in linear RGB. Chosen so the shadowed half lands on the
 * sky's own tone around the moon (≈ #161C25 in sRGB), not on black.
 */
const EARTHSHINE: [number, number, number] = [0.0048, 0.0078, 0.0142];

type Uniforms = Record<
  | "uMap"
  | "uTexel"
  | "uSun"
  | "uSpin"
  | "uExposure"
  | "uAlpha"
  | "uPixel"
  | "uEarthshine"
  | "uTerminatorShift",
  WebGLUniformLocation | null
>;

export type MoonFrame = {
  /** Sun–viewer angle in radians (π new moon, 0 full moon). */
  phase: number;
  spin: number;
  exposure: number;
  alpha: number;
};

/**
 * Renders the moon into a square WebGL2 canvas. The expensive procedural
 * surface is baked into a texture once; each frame is a single lit quad.
 */
export class MoonRenderer {
  private readonly gl: WebGL2RenderingContext;
  private readonly shade: WebGLProgram;
  private readonly uniforms: Uniforms;
  private readonly map: WebGLTexture;
  private readonly quad: WebGLVertexArrayObject;
  private sizePx = 1;

  static create(canvas: HTMLCanvasElement): MoonRenderer | null {
    const gl = canvas.getContext("webgl2", {
      alpha: true,
      premultipliedAlpha: true,
      antialias: false,
      depth: false,
      stencil: false,
      powerPreference: "high-performance",
    });
    if (!gl) return null;
    try {
      return new MoonRenderer(gl);
    } catch (error) {
      console.error(error);
      return null;
    }
  }

  private constructor(gl: WebGL2RenderingContext) {
    this.gl = gl;
    this.quad = this.createQuad();

    const bake = this.program(FULLSCREEN_VERT, BAKE_FRAG);
    this.shade = this.program(FULLSCREEN_VERT, SHADE_FRAG);
    this.map = this.bakeSurface(bake);
    gl.deleteProgram(bake);

    const u = (name: string) => gl.getUniformLocation(this.shade, name);
    this.uniforms = {
      uMap: u("uMap"),
      uTexel: u("uTexel"),
      uSun: u("uSun"),
      uSpin: u("uSpin"),
      uExposure: u("uExposure"),
      uAlpha: u("uAlpha"),
      uPixel: u("uPixel"),
      uEarthshine: u("uEarthshine"),
      uTerminatorShift: u("uTerminatorShift"),
    };
  }

  resize(cssSize: number, dpr: number) {
    const canvas = this.gl.canvas as HTMLCanvasElement;
    this.sizePx = Math.max(1, Math.round(cssSize * dpr));
    canvas.width = this.sizePx;
    canvas.height = this.sizePx;
    canvas.style.width = `${cssSize}px`;
    canvas.style.height = `${cssSize}px`;
  }

  draw(frame: MoonFrame) {
    const { gl } = this;
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    gl.viewport(0, 0, this.sizePx, this.sizePx);
    gl.clearColor(0, 0, 0, 0);
    gl.clear(gl.COLOR_BUFFER_BIT);
    if (frame.alpha <= 0.001) return;

    gl.useProgram(this.shade);
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, this.map);
    gl.uniform1i(this.uniforms.uMap, 0);
    gl.uniform2f(this.uniforms.uTexel, 1 / MAP_WIDTH, 1 / MAP_HEIGHT);
    // Sunlight direction projected on the disc: LIGHT_ANGLE above the
    // horizontal; the terminator is perpendicular to it.
    const lit = Math.sin(frame.phase);
    gl.uniform3f(
      this.uniforms.uSun,
      lit * Math.cos(LIGHT_ANGLE),
      lit * Math.sin(LIGHT_ANGLE),
      Math.cos(frame.phase),
    );
    gl.uniform1f(this.uniforms.uSpin, frame.spin);
    gl.uniform1f(this.uniforms.uExposure, frame.exposure);
    gl.uniform1f(this.uniforms.uAlpha, frame.alpha);
    gl.uniform1f(this.uniforms.uPixel, 2 / this.sizePx);
    gl.uniform3f(this.uniforms.uEarthshine, ...EARTHSHINE);
    gl.uniform1f(this.uniforms.uTerminatorShift, TERMINATOR_SHIFT);
    gl.bindVertexArray(this.quad);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  }

  dispose() {
    const { gl } = this;
    gl.deleteTexture(this.map);
    gl.deleteProgram(this.shade);
    gl.deleteVertexArray(this.quad);
    gl.getExtension("WEBGL_lose_context")?.loseContext();
  }

  // ── Setup ────────────────────────────────────────────────────────────

  private createQuad() {
    const { gl } = this;
    const vao = gl.createVertexArray();
    const buffer = gl.createBuffer();
    if (!vao || !buffer) throw new Error("WebGL: could not allocate the quad");
    gl.bindVertexArray(vao);
    gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
    // One oversized triangle covers the viewport with no diagonal seam.
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
    gl.enableVertexAttribArray(0);
    gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
    return vao;
  }

  private program(vertexSource: string, fragmentSource: string) {
    const { gl } = this;
    const compile = (type: number, source: string) => {
      const shader = gl.createShader(type);
      if (!shader) throw new Error("WebGL: could not create shader");
      gl.shaderSource(shader, source);
      gl.compileShader(shader);
      if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
        throw new Error(`WebGL shader: ${gl.getShaderInfoLog(shader)}`);
      }
      return shader;
    };
    const program = gl.createProgram();
    if (!program) throw new Error("WebGL: could not create program");
    const vs = compile(gl.VERTEX_SHADER, vertexSource);
    const fs = compile(gl.FRAGMENT_SHADER, fragmentSource);
    gl.attachShader(program, vs);
    gl.attachShader(program, fs);
    gl.bindAttribLocation(program, 0, "aPos");
    gl.linkProgram(program);
    gl.deleteShader(vs);
    gl.deleteShader(fs);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
      throw new Error(`WebGL link: ${gl.getProgramInfoLog(program)}`);
    }
    return program;
  }

  private bakeSurface(bake: WebGLProgram) {
    const { gl } = this;
    // Half-float keeps the height field smooth enough for bump mapping;
    // plain RGBA8 is the (slightly steppier) fallback.
    const halfFloat = gl.getExtension("EXT_color_buffer_float") !== null;
    const texture = gl.createTexture();
    const framebuffer = gl.createFramebuffer();
    if (!texture || !framebuffer) throw new Error("WebGL: could not allocate the surface map");

    gl.bindTexture(gl.TEXTURE_2D, texture);
    gl.texStorage2D(
      gl.TEXTURE_2D,
      Math.floor(Math.log2(MAP_WIDTH)) + 1,
      halfFloat ? gl.RGBA16F : gl.RGBA8,
      MAP_WIDTH,
      MAP_HEIGHT,
    );
    gl.bindFramebuffer(gl.FRAMEBUFFER, framebuffer);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, texture, 0);
    if (gl.checkFramebufferStatus(gl.FRAMEBUFFER) !== gl.FRAMEBUFFER_COMPLETE) {
      throw new Error("WebGL: surface framebuffer incomplete");
    }

    gl.viewport(0, 0, MAP_WIDTH, MAP_HEIGHT);
    gl.useProgram(bake);
    gl.bindVertexArray(this.quad);
    gl.drawArrays(gl.TRIANGLES, 0, 3);

    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    gl.deleteFramebuffer(framebuffer);

    // Mipmaps stop the small end of the crater field from shimmering while
    // the disc spins at small window sizes.
    gl.generateMipmap(gl.TEXTURE_2D);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.REPEAT);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    return texture;
  }
}
