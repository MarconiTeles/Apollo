import type { Step } from "../lib/types";

/** One hairline per step. A single honest value (see `useCreep`) flows
 *  through the segments; the running segment carries a travelling glint. */
export function ProgressRail({ steps, value }: { steps: Step[]; value: number }) {
  const counted = steps.filter((s) => s.state !== "skipped");
  const n = Math.max(1, counted.length);
  return (
    <div className="rail" role="progressbar" aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.round(value * 100)}>
      {counted.map((step, i) => {
        const fill = Math.min(1, Math.max(0, (value - i / n) * n));
        return (
          <span key={step.id} className="rail-segment" data-state={step.state}>
            <span className="rail-fill" style={{ transform: `scaleX(${fill})` }} />
            {step.state === "active" && <span className="rail-glint" />}
          </span>
        );
      })}
    </div>
  );
}
