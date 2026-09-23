import type { Layout } from "./state";

const SVG_NS = "http://www.w3.org/2000/svg";
const TRAIL = 18;

export type OrbitOptions = {
  id: string;
  /** Semi-axes as fractions of the moon diameter. */
  rx: number;
  ry: number;
  /** Orbit plane tilt, degrees. */
  tilt: number;
  /** Seconds per revolution; negative reverses direction. */
  period: number;
  /** Where on the orbit the craft starts, radians. */
  phase: number;
  /** "star" is the icon glyph; "dot" is a small, distant companion. */
  craft: "star" | "dot";
  /** Ring stroke opacity on the near side (far side is half). */
  ringOpacity: number;
};

type Half = {
  svg: SVGSVGElement;
  group: SVGGElement;
  clipRect: SVGRectElement;
  ring: SVGEllipseElement;
  trail: SVGCircleElement[];
  craft: SVGGElement;
};

/**
 * One inclined orbit around the moon, split into a far half (drawn behind
 * the moon canvas, so the disc occludes it) and a near half (drawn in front).
 * The spacecraft — the icon's four-point star — hands over between the two
 * SVGs as it crosses the orbit's line of nodes, which is what sells the depth.
 */
export class OrbitRig {
  private readonly back: Half;
  private readonly front: Half;
  private rx = 0;
  private ry = 0;

  constructor(
    backSvg: SVGSVGElement,
    frontSvg: SVGSVGElement,
    private readonly options: OrbitOptions,
  ) {
    this.back = this.build(backSvg, "back");
    this.front = this.build(frontSvg, "front");
  }

  resize(layout: Layout) {
    this.rx = layout.diameter * this.options.rx;
    this.ry = layout.diameter * this.options.ry;
    for (const half of [this.back, this.front]) {
      half.svg.setAttribute("viewBox", `0 0 ${layout.width} ${layout.height}`);
      half.svg.setAttribute("width", String(layout.width));
      half.svg.setAttribute("height", String(layout.height));
      half.group.setAttribute("transform", `translate(${layout.cx} ${layout.cy}) rotate(${this.options.tilt})`);
      half.ring.setAttribute("rx", String(this.rx));
      half.ring.setAttribute("ry", String(this.ry));
    }
    const clipBack = this.back.clipRect;
    const clipFront = this.front.clipRect;
    const big = layout.diameter * 3;
    clipBack.setAttribute("x", String(-big));
    clipBack.setAttribute("y", String(-big));
    clipBack.setAttribute("width", String(big * 2));
    clipBack.setAttribute("height", String(big));
    clipFront.setAttribute("x", String(-big));
    clipFront.setAttribute("y", "0");
    clipFront.setAttribute("width", String(big * 2));
    clipFront.setAttribute("height", String(big));
  }

  /** `drawn` 0…1 traces the ring in; `craft` 0…1 fades the spacecraft. */
  draw(time: number, drawn: number, craft: number) {
    const offset = String(1 - drawn);
    this.back.ring.style.strokeDashoffset = offset;
    this.front.ring.style.strokeDashoffset = offset;

    const { period, phase } = this.options;
    const direction = Math.sign(period);
    const base = phase - (time / Math.abs(period)) * Math.PI * 2 * direction;
    this.place(base, craft, -1);
    for (let i = 0; i < TRAIL; i++) {
      this.place(base + (i + 1) * 0.05 * direction, craft * Math.pow(1 - i / TRAIL, 1.6), i);
    }
  }

  // index -1 is the spacecraft itself; 0…TRAIL-1 are trail samples.
  private place(angle: number, alpha: number, index: number) {
    const x = this.rx * Math.cos(angle);
    const y = this.ry * Math.sin(angle);
    const near = y >= 0;
    // Depth: brighter and larger on the near side of the orbit.
    const depth = 0.5 + 0.5 * Math.sin(angle);
    const shown = near ? this.front : this.back;
    const hidden = near ? this.back : this.front;
    const a = alpha * (0.45 + 0.55 * depth);

    if (index < 0) {
      const scale = (0.72 + 0.42 * depth) * (this.options.craft === "dot" ? 0.55 : 1);
      shown.craft.setAttribute("transform", `translate(${x} ${y}) scale(${scale})`);
      shown.craft.style.opacity = String(a);
      hidden.craft.style.opacity = "0";
      return;
    }
    const dot = shown.trail[index];
    dot.setAttribute("cx", String(x));
    dot.setAttribute("cy", String(y));
    dot.setAttribute("r", String((1.9 - (index / TRAIL) * 1.5) * (0.75 + 0.35 * depth)));
    dot.style.opacity = String(a * 0.8);
    hidden.trail[index].style.opacity = "0";
  }

  private build(svg: SVGSVGElement, side: "back" | "front"): Half {
    const make = <K extends keyof SVGElementTagNameMap>(tag: K, parent: Element) => {
      const el = document.createElementNS(SVG_NS, tag);
      parent.appendChild(el);
      return el;
    };
    const { id, ringOpacity, craft: craftKind } = this.options;
    // Several rigs share the same pair of SVGs, each in its own group.
    const root = make("g", svg);
    const defs = make("defs", root);
    const clip = make("clipPath", defs);
    const clipId = `orbit-clip-${id}-${side}`;
    clip.setAttribute("id", clipId);
    const clipRect = make("rect", clip);

    const halo = make("radialGradient", defs);
    halo.setAttribute("id", `craft-halo-${id}-${side}`);
    const stop0 = make("stop", halo);
    stop0.setAttribute("offset", "0");
    stop0.setAttribute("stop-color", "rgb(140, 238, 255)");
    stop0.setAttribute("stop-opacity", "0.55");
    const stop1 = make("stop", halo);
    stop1.setAttribute("offset", "1");
    stop1.setAttribute("stop-color", "rgb(140, 238, 255)");
    stop1.setAttribute("stop-opacity", "0");

    const group = make("g", root);
    const clipped = make("g", group);
    clipped.setAttribute("clip-path", `url(#${clipId})`);

    const ring = make("ellipse", clipped);
    ring.setAttribute("fill", "none");
    ring.setAttribute("pathLength", "1");
    ring.setAttribute("stroke-dasharray", "1 1");
    ring.setAttribute("stroke-width", side === "front" ? "1" : "0.8");
    ring.setAttribute(
      "stroke",
      `rgba(170, 228, 255, ${side === "front" ? ringOpacity : ringOpacity * 0.47})`,
    );
    ring.style.strokeDashoffset = "1";

    const trail = Array.from({ length: TRAIL }, () => {
      const dot = make("circle", group);
      dot.setAttribute("fill", "rgb(150, 238, 255)");
      dot.style.opacity = "0";
      return dot;
    });

    const craft = make("g", group);
    craft.style.opacity = "0";
    const glow = make("circle", craft);
    glow.setAttribute("r", "16");
    glow.setAttribute("fill", `url(#craft-halo-${id}-${side})`);
    if (craftKind === "star") {
      const star = make("path", craft);
      // Same concave four-point star as the Apollo icon.
      star.setAttribute("d", "M0 -7 Q1.1 -1.1 7 0 Q1.1 1.1 0 7 Q-1.1 1.1 -7 0 Q-1.1 -1.1 0 -7 Z");
      star.setAttribute("fill", "rgb(232, 252, 255)");
    } else {
      const dot = make("circle", craft);
      dot.setAttribute("r", "3");
      dot.setAttribute("fill", "rgb(220, 240, 255)");
    }

    return { svg, group, clipRect, ring, trail, craft };
  }
}
