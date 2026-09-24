import { useLayoutEffect, useRef, useState } from "react";

// RoundedRectangle(cornerRadius:style: .continuous) — Apple's continuous
// corner (the iOS 7 bezier set), which matches SwiftUI's rasterisation within
// antialiasing noise where CSS border-radius (circular) does not.

const K = 1.52866483;

export function squircle(x: number, y: number, w: number, h: number, radius: number): string {
  if (w <= 0 || h <= 0) return "";
  const r = Math.max(0, Math.min(radius, Math.min(w, h) / 2 / K));
  const R = x + w;
  const B = y + h;
  const f = (n: number) => Number(n.toFixed(3));
  const tr = (a: number, b: number) => `${f(R - a * r)} ${f(y + b * r)}`;
  const br = (a: number, b: number) => `${f(R - a * r)} ${f(B - b * r)}`;
  const bl = (a: number, b: number) => `${f(x + a * r)} ${f(B - b * r)}`;
  const tl = (a: number, b: number) => `${f(x + a * r)} ${f(y + b * r)}`;
  return [
    `M${tl(K, 0)}`,
    `L${tr(1.52866471, 0)}`,
    `C${tr(1.08849323, 0)} ${tr(0.86840689, 0)} ${tr(0.66993427, 0.065496)}`,
    `L${tr(0.63149399, 0.074911)}`,
    `C${tr(0.37282392, 0.16905899)} ${tr(0.16906013, 0.37282401)} ${tr(0.07491176, 0.63149399)}`,
    `C${tr(0, 0.86840701)} ${tr(0, 1.08849299)} ${tr(0, K)}`,
    `L${br(0, 1.52866471)}`,
    `C${br(0, 1.08849323)} ${br(0, 0.86840689)} ${br(0.06549569, 0.66993493)}`,
    `L${br(0.07491111, 0.63149399)}`,
    `C${br(0.16905883, 0.37282392)} ${br(0.37282392, 0.16905883)} ${br(0.63149399, 0.07491111)}`,
    `C${br(0.86840689, 0)} ${br(1.08849323, 0)} ${br(1.52866471, 0)}`,
    `L${bl(K, 0)}`,
    `C${bl(1.08849299, 0)} ${bl(0.86840701, 0)} ${bl(0.66993427, 0.065496)}`,
    `L${bl(0.63149399, 0.074911)}`,
    `C${bl(0.37282401, 0.16906001)} ${bl(0.16906001, 0.37282401)} ${bl(0.074911, 0.63149399)}`,
    `C${bl(0, 0.86840701)} ${bl(0, 1.08849299)} ${bl(0, K)}`,
    `L${tl(0, 1.52866471)}`,
    `C${tl(0, 1.08849323)} ${tl(0, 0.86840689)} ${tl(0.065496, 0.66993427)}`,
    `L${tl(0.074911, 0.63149399)}`,
    `C${tl(0.16906001, 0.37282401)} ${tl(0.37282401, 0.16906001)} ${tl(0.63149399, 0.074911)}`,
    `C${tl(0.86840701, 0)} ${tl(1.08849299, 0)} ${tl(K, 0)}`,
    "Z",
  ].join("");
}

/** Gaussian blurs shared by every shadow path (σ = SwiftUI shadow radius).
 *  Explicit filter regions: CSS drop-shadow clipped them inconsistently. */
export const SHADOW_SIGMAS = [4, 10.4] as const;
export const blurId = (sigma: number) => `sq-blur-${String(sigma).replace(".", "_")}`;

export function ShadowFilters() {
  return (
    <svg width="0" height="0" style={{ position: "absolute" }} aria-hidden>
      <defs>
        {SHADOW_SIGMAS.map((sigma) => (
          <filter key={sigma} id={blurId(sigma)} x="-25%" y="-150%" width="150%" height="400%"
                  colorInterpolationFilters="sRGB">
            <feGaussianBlur stdDeviation={sigma} />
          </filter>
        ))}
      </defs>
    </svg>
  );
}

export interface ShadowLayer {
  className: string;
  dy: number;
  sigma: (typeof SHADOW_SIGMAS)[number];
}

/** Filled continuous rounded rect covering its positioned parent, with
 *  optional shadow layers painted underneath (`.shadow(color:radius:y:)`). */
export function Squircle({
  width,
  height,
  radius,
  className,
  stroke,
  shadows,
}: {
  width: number;
  height: number;
  radius: number;
  className: string;
  /** strokeBorder width: drawn inside the shape (path inset by half). */
  stroke?: { className: string; width: number };
  shadows?: ShadowLayer[];
}) {
  if (width <= 0 || height <= 0) return null;
  const d = squircle(0, 0, width, height, radius);
  const inset = stroke ? stroke.width / 2 : 0;
  return (
    <svg className={`squircle ${className}`} width={width} height={height} aria-hidden>
      {shadows?.map((shadow) => (
        <path
          key={shadow.className}
          className={shadow.className}
          d={d}
          transform={`translate(0 ${shadow.dy})`}
          filter={`url(#${blurId(shadow.sigma)})`}
        />
      ))}
      <path className="squircle-fill" d={d} />
      {stroke && (
        <path
          className={stroke.className}
          d={squircle(inset, inset, width - 2 * inset, height - 2 * inset, radius - inset)}
          fill="none"
          strokeWidth={stroke.width}
        />
      )}
    </svg>
  );
}

/** Untransformed border-box size of an element (hover scale ignored). */
export function useBoxSize<T extends HTMLElement>() {
  const ref = useRef<T>(null);
  const [size, setSize] = useState({ width: 0, height: 0 });
  useLayoutEffect(() => {
    const element = ref.current;
    if (!element) return;
    const observer = new ResizeObserver(([entry]) => {
      const box = entry.borderBoxSize?.[0];
      const width = box ? box.inlineSize : element.offsetWidth;
      const height = box ? box.blockSize : element.offsetHeight;
      setSize((previous) => (previous.width === width && previous.height === height ? previous : { width, height }));
    });
    observer.observe(element);
    return () => observer.disconnect();
  }, []);
  return [ref, size] as const;
}
