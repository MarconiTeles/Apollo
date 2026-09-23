// A single mutable scene record. GSAP tweens its fields; the render loop
// reads them once per frame. Nothing here touches React state, so a busy
// timeline never re-renders the component tree.

export type Scene = {
  /** Starfield visibility, 0…1. */
  stars: number;
  /** Deep nebula visibility, 0…1. */
  nebula: number;
  /** Foreground mist + dust motes visibility, 0…1. */
  mist: number;
  /** Moon disc visibility, 0…1. */
  moon: number;
  /**
   * Angle between the sun and the viewer as seen from the moon, radians.
   * π is a new moon, π/2 an exact quarter. Tweening it sweeps the terminator
   * across the disc — the signature motion of the splash.
   */
  phase: number;
  /** Extra rotation that unwinds during the intro: the moon arrives spinning. */
  spinExtra: number;
  /** Multiplier on the sunlit side. Flares when the sun first hits the limb. */
  exposure: number;
  /** Camera pull-back, 1 → 0: every layer starts closer and settles. */
  pull: number;
  /** Orbit ring draw-in, 0…1 (inner, outer). */
  orbit: number;
  orbitOuter: number;
  /** Spacecraft + trail visibility, 0…1. */
  satellite: number;
  /** Halo behind the disc, 0…1. */
  halo: number;
};

export const PHASE_CRESCENT = 2.8;
/**
 * Resting phase: well past the quarter, so the terminator curves strongly
 * like a "meia lua" instead of cutting the disc with a straight line
 * (~17% lit; the curve's depth is |cos φ| ≈ 0.67 of the radius).
 */
export const PHASE_REST = 2.3;

export function createScene(reduced: boolean): Scene {
  const base = { stars: 0, nebula: 0, mist: 0, moon: 0, exposure: 1, halo: 0, spinExtra: 0, pull: 0 };
  return reduced
    ? { ...base, phase: PHASE_REST, orbit: 1, orbitOuter: 1, satellite: 1 }
    : { ...base, phase: PHASE_CRESCENT, orbit: 0, orbitOuter: 0, satellite: 0, pull: 1 };
}

export type Layout = {
  width: number;
  height: number;
  /** Moon diameter in CSS px. */
  diameter: number;
  /** Moon centre in CSS px. */
  cx: number;
  cy: number;
};

/**
 * The moon scales with the window but never dominates it: roughly a third
 * of the width, capped so the wordmark always fits underneath — including
 * the 960×620 menu-bar popover.
 */
export function computeLayout(width: number, height: number): Layout {
  const diameter = Math.round(Math.min(Math.max(Math.min(width * 0.34, height * 0.46), 200), 540));
  return { width, height, diameter, cx: width / 2, cy: height * 0.42 };
}
