import { useEffect, useRef, useState } from "react";

export const reducedMotion = () => window.matchMedia("(prefers-reduced-motion: reduce)").matches;

/** Critically damped follow: `value` chases `target` at a fixed half-life,
 *  frame-rate independent. Numbers never jump; they glide. */
export function useFollow(target: number, halfLife = 0.18) {
  const [value, setValue] = useState(target);
  const state = useRef({ value: target, target });
  state.current.target = target;

  useEffect(() => {
    if (reducedMotion()) {
      state.current.value = target;
      setValue(target);
      return;
    }
    let frame = 0;
    let last = performance.now();
    const tick = (now: number) => {
      const dt = Math.min(0.1, (now - last) / 1000);
      last = now;
      const s = state.current;
      const k = 1 - Math.pow(0.5, dt / halfLife);
      s.value += (s.target - s.value) * k;
      if (Math.abs(s.target - s.value) < 0.0005) s.value = s.target;
      setValue(s.value);
      if (s.value !== s.target) frame = requestAnimationFrame(tick);
    };
    frame = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(frame);
  }, [target, halfLife]);

  return value;
}

/** Progress that is always honest and never idle.
 *
 *  `progress` is what Swift knows is finished. While a step runs, the bar
 *  keeps easing toward `ceiling` (the step's end) on an asymptote — it slows
 *  as it approaches and can never cross into unfinished work. When the step
 *  lands, it springs to the new `progress`. */
export function useCreep(progress: number, ceiling: number) {
  const [value, setValue] = useState(progress);
  const state = useRef({ value: progress, progress, ceiling });
  state.current.progress = progress;
  state.current.ceiling = Math.max(progress, ceiling);

  useEffect(() => {
    const motion = !reducedMotion();
    let frame = 0;
    let last = performance.now();
    const tick = (now: number) => {
      const dt = Math.min(0.1, (now - last) / 1000);
      last = now;
      const s = state.current;
      if (s.value < s.progress) {
        // Landed: catch up quickly (≈ 140 ms half-life).
        s.value += (s.progress - s.value) * (1 - Math.pow(0.5, dt / 0.14));
      } else if (s.value < s.ceiling) {
        // Running: drift toward the ceiling, ~2.2 s half-life.
        s.value += (s.ceiling - s.value) * (1 - Math.pow(0.5, dt / 2.2));
      } else if (s.value > s.ceiling) {
        s.value = s.ceiling;
      }
      if (!motion) s.value = s.progress;
      setValue(s.value);
      frame = requestAnimationFrame(tick);
    };
    frame = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(frame);
  }, []);

  return value;
}

/** Wall clock at a coarse cadence — for elapsed-time labels. */
export function useNow(interval = 100) {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const id = window.setInterval(() => setNow(Date.now()), interval);
    return () => window.clearInterval(id);
  }, [interval]);
  return now;
}

/** Increments whenever `value` grows — used as a React `key` to replay a
 *  one-shot "data arrived" animation exactly when data arrives. */
export function useArrivals(value: number | undefined) {
  const [count, setCount] = useState(0);
  const previous = useRef(value);
  useEffect(() => {
    if (value !== undefined && previous.current !== undefined && value > previous.current) {
      setCount((c) => c + 1);
    }
    previous.current = value;
  }, [value]);
  return count;
}

/** Deterministic pseudo-random in [0, 1) — skeleton widths stay the same
 *  from frame to frame and from launch to launch. */
export function seeded(n: number) {
  const x = Math.sin(n * 127.1 + 311.7) * 43758.5453;
  return x - Math.floor(x);
}

/** "a" / "b" alternating per arrival (undefined before the first): lets CSS
 *  replay a one-shot animation without remounting — remounting would drop
 *  each bone's anchor to the light front. */
export const replay = (count: number) => (count === 0 ? undefined : count % 2 ? "a" : "b");
