// SwiftUI springs sampled into CSS linear() easings.
//
// `.spring(response:dampingFraction:)` is a unit-mass spring with
// stiffness (2π / response)² and damping 4π·ζ / response;
// `.spring(duration:bounce:)` is the same curve with response = duration and
// ζ = 1 − bounce. The CSS duration is the settling time (0.1% envelope).

export interface Spring {
  easing: string;
  duration: number;
}

export function spring(response: number, dampingFraction: number): Spring {
  const w0 = (2 * Math.PI) / response;
  const zeta = dampingFraction;
  const decay = zeta * w0;
  const wd = w0 * Math.sqrt(Math.max(1e-6, 1 - zeta * zeta));
  const b = decay / wd;
  const displacement = (t: number) => Math.exp(-decay * t) * (Math.cos(wd * t) + b * Math.sin(wd * t));
  const envelope = Math.sqrt(1 + b * b);
  const duration = Math.log(envelope / 0.001) / decay;
  const steps = 60;
  const points: string[] = [];
  for (let i = 0; i <= steps; i++) {
    const t = (duration * i) / steps;
    points.push((i === steps ? 1 : 1 - displacement(t)).toFixed(4));
  }
  return { easing: `linear(${points.join(", ")})`, duration };
}

/** interactivePillFeedback: hover (0.4 / 0.75) and press (0.3 / 0.7). */
export const hoverSpring = spring(0.4, 0.75);
export const pressSpring = spring(0.3, 0.7);
/** AgendaMonthView day selection: .spring(duration: 0.28, bounce: 0.15). */
export const selectSpring = spring(0.28, 0.85);
/** AgendaDayPanel content: .spring(duration: 0.3, bounce: 0.12). */
export const panelSpring = spring(0.3, 0.88);

export function installMotionTokens() {
  const root = document.documentElement.style;
  const set = (name: string, value: Spring) => {
    root.setProperty(`--${name}`, value.easing);
    root.setProperty(`--${name}-duration`, `${value.duration.toFixed(3)}s`);
  };
  set("hover", hoverSpring);
  set("press", pressSpring);
  set("select", selectSpring);
  set("panel", panelSpring);
}
