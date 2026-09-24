// CASpringAnimation(mass 0.7, stiffness 310, damping 22, initialVelocity 2)
// sampled into a CSS linear() easing, with duration = settlingDuration.
// Used for MyTasksDoneCircle's release bounce.

function springEasing(mass: number, stiffness: number, damping: number, velocity: number) {
  const w0 = Math.sqrt(stiffness / mass);
  const zeta = damping / (2 * Math.sqrt(stiffness * mass));
  const decay = zeta * w0;
  const wd = w0 * Math.sqrt(Math.max(0, 1 - zeta * zeta));
  const b = (decay - velocity) / wd;
  // Remaining displacement (1 → 0) for the under-damped solution.
  const displacement = (t: number) => Math.exp(-decay * t) * (Math.cos(wd * t) + b * Math.sin(wd * t));
  // settlingDuration: envelope below 0.1% of the travelled distance.
  const envelope = Math.sqrt(1 + b * b);
  const duration = Math.log(envelope / 0.001) / decay;
  const steps = 48;
  const points: string[] = [];
  for (let i = 0; i <= steps; i++) {
    const t = (duration * i) / steps;
    const value = i === steps ? 1 : 1 - displacement(t);
    points.push(value.toFixed(4));
  }
  return { easing: `linear(${points.join(", ")})`, duration };
}

export const doneSpring = springEasing(0.7, 310, 22, 2);

export function installMotionTokens() {
  const root = document.documentElement.style;
  root.setProperty("--spring", doneSpring.easing);
  root.setProperty("--spring-duration", `${doneSpring.duration.toFixed(3)}s`);
}
