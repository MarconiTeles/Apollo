import { useFollow } from "../lib/motion";

type Props = {
  /** Lit fraction, 0 (new moon) … 1 (full moon). */
  value: number;
  size?: number;
  tone?: "live" | "failed" | "offline";
};

/** The scene's status mark: a small moon whose lit face *is* the progress —
 *  waxing from a sliver to full as the sync completes, with one satellite on
 *  a slow orbit so the mark reads as alive even while a step is waiting. */
export function MoonPhase({ value, size = 22, tone = "live" }: Props) {
  const phase = useFollow(Math.min(1, Math.max(0.04, value)), 0.22);
  const r = 7;
  const c = 11;
  // The terminator is a half-ellipse; its x-radius shrinks to 0 at half moon
  // and grows back out as the lit side passes the middle.
  const rx = Math.abs(1 - 2 * phase) * r;
  const sweep = phase > 0.5 ? 1 : 0;
  const lit = `M ${c} ${c - r} A ${r} ${r} 0 0 1 ${c} ${c + r} A ${rx} ${r} 0 0 ${sweep} ${c} ${c - r} Z`;

  return (
    <span className="moon" data-tone={tone} style={{ width: size, height: size }} aria-hidden>
      <svg viewBox="0 0 22 22" width={size} height={size}>
        <g transform={`rotate(-24 ${c} ${c})`}>
          <circle className="moon-disc" cx={c} cy={c} r={r} />
          <path className="moon-lit" d={lit} />
          <circle className="moon-rim" cx={c} cy={c} r={r} />
        </g>
      </svg>
      <span className="moon-orbit">
        <span className="moon-satellite" />
      </span>
    </span>
  );
}
