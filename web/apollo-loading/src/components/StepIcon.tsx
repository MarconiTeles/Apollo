import type { StepState } from "../lib/types";

/** 12 pt state glyph shared by every scene. The check draws itself once,
 *  when the step lands — the only moment worth animating. */
export function StepIcon({ state }: { state: StepState }) {
  return (
    <span className="step-icon" data-state={state} aria-hidden>
      {state === "active" && (
        <svg viewBox="0 0 12 12">
          <circle className="spin-track" cx="6" cy="6" r="4.5" />
          <circle className="spin-arc" cx="6" cy="6" r="4.5" pathLength="100" />
        </svg>
      )}
      {state === "done" && (
        <svg viewBox="0 0 12 12">
          <path className="check" d="M3 6.3 L5.1 8.3 L9 4" pathLength="100" />
        </svg>
      )}
      {state === "failed" && (
        <svg viewBox="0 0 12 12">
          <circle className="fail-disc" cx="6" cy="6" r="5" />
          <path className="fail-mark" d="M6 3.4 V6.6 M6 8.3 V8.5" />
        </svg>
      )}
      {state === "pending" && (
        <svg viewBox="0 0 12 12">
          <circle className="pending-dot" cx="6" cy="6" r="2.4" />
        </svg>
      )}
      {state === "skipped" && (
        <svg viewBox="0 0 12 12">
          <path className="skip-dash" d="M3.5 6 H8.5" />
        </svg>
      )}
    </span>
  );
}
