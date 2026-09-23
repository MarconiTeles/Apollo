import type { ReactNode } from "react";
import type { Step } from "../lib/types";
import { StepIcon } from "./StepIcon";

/** Steps as one quiet sentence: icon · label · detail, separated by space. */
export function StepsInline({ steps }: { steps: Step[] }) {
  return (
    <ol className="steps-inline">
      {steps.map((step) => (
        <li key={step.id} data-state={step.state}>
          <StepIcon state={step.state} />
          <span className="step-label">{step.label}</span>
          {step.detail && <span className="step-detail">{step.detail}</span>}
        </li>
      ))}
    </ol>
  );
}

/** Steps as a ledger: label on the left, the fact on the right. */
export function StepsLedger({ steps, glyphs }: { steps: Step[]; glyphs?: Record<string, ReactNode> }) {
  return (
    <ol className="steps-ledger">
      {steps.map((step, index) => (
        <li key={step.id} data-state={step.state} style={{ ["--i" as string]: index }}>
          {glyphs?.[step.id] && <span className="ledger-glyph">{glyphs[step.id]}</span>}
          <span className="step-label">{step.label}</span>
          <span className="ledger-fill" />
          {step.detail && <span className="step-detail">{step.detail}</span>}
          <StepIcon state={step.state} />
        </li>
      ))}
    </ol>
  );
}
