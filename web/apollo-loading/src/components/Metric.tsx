import { useArrivals, useFollow } from "../lib/motion";
import { formatCount } from "../lib/format";

/** A count that glides up as data lands, with a one-shot lift on arrival. */
export function Metric({ value, label, align = "end" }: { value: number; label: string; align?: "start" | "end" }) {
  const shown = useFollow(value, 0.16);
  const arrivals = useArrivals(value);
  return (
    <div className="metric" data-align={align}>
      <span key={arrivals} className="metric-value" data-arrived={arrivals > 0 || undefined}>
        {formatCount(shown)}
      </span>
      <span className="metric-label">{label}</span>
    </div>
  );
}
