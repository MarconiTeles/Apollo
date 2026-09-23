// Motion tokens shared with the native app. Every curve here is a real
// cubic-bezier (the same values the Swift side uses), solved exactly so
// GSAP timelines and CSS transitions feel identical.

/** Returns an easing function equivalent to CSS `cubic-bezier(x1, y1, x2, y2)`. */
export function cubicBezier(x1: number, y1: number, x2: number, y2: number) {
  const cx = 3 * x1;
  const bx = 3 * (x2 - x1) - cx;
  const ax = 1 - cx - bx;
  const cy = 3 * y1;
  const by = 3 * (y2 - y1) - cy;
  const ay = 1 - cy - by;

  const sampleX = (t: number) => ((ax * t + bx) * t + cx) * t;
  const sampleY = (t: number) => ((ay * t + by) * t + cy) * t;
  const slopeX = (t: number) => (3 * ax * t + 2 * bx) * t + cx;

  const solveT = (x: number) => {
    // Newton–Raphson converges in a few steps for well-formed curves…
    let t = x;
    for (let i = 0; i < 8; i++) {
      const err = sampleX(t) - x;
      if (Math.abs(err) < 1e-6) return t;
      const d = slopeX(t);
      if (Math.abs(d) < 1e-6) break;
      t -= err / d;
    }
    // …bisection covers the flat-slope cases Newton can't.
    let lo = 0;
    let hi = 1;
    t = x;
    while (lo < hi) {
      const v = sampleX(t);
      if (Math.abs(v - x) < 1e-6) return t;
      if (x > v) lo = t;
      else hi = t;
      t = (lo + hi) / 2;
      if (hi - lo < 1e-7) break;
    }
    return t;
  };

  return (x: number) => (x <= 0 ? 0 : x >= 1 ? 1 : sampleY(solveT(x)));
}

/** Strong ease-out for anything entering or leaving. */
export const EASE_OUT = cubicBezier(0.23, 1, 0.32, 1);
/** Strong ease-in-out for large on-screen morphs (the reveal iris). */
export const EASE_IN_OUT = cubicBezier(0.77, 0, 0.175, 1);
/** iOS-like drawer curve — used for the slow, deliberate moon rise. */
export const EASE_DRAWER = cubicBezier(0.32, 0.72, 0, 1);
export const LINEAR = (t: number) => t;
