import { Bone } from "../components/Bone";
import { MoonPhase } from "../components/MoonPhase";
import { StepsLedger } from "../components/Steps";
import { seeded, useCreep } from "../lib/motion";
import type { Snapshot } from "../lib/types";
import { fitting, useViewport } from "../lib/viewport";
import { tone } from "./TasksScene";

// Inbox — "listening to every source".
//
// The Inbox is not a fetch, it is a comparison: what changed in ClickUp and
// Google Agenda since the last reading. So the scene is a ledger of sources,
// each with its own state and fact, joined by a signal line that runs down
// into the (still empty) feed. While a source is being read, light travels
// along that line toward the capsules below. As many whole capsules as the
// column holds drop in one after another, like notifications landing.

/** Head + ledger + gap above the first capsule (mirrored in Swift). */
const TOP = 166.5;
const CAPSULE = 58;
const CAPSULE_GAP = 9;

const GLYPHS = {
  clickup: (
    <svg viewBox="0 0 16 16" aria-hidden>
      <rect x="2.5" y="3" width="11" height="10" rx="2.4" />
      <path d="M5 6.4 L6.4 7.8 L8.9 5.3 M5 10.4 H11" />
    </svg>
  ),
  calendar: (
    <svg viewBox="0 0 16 16" aria-hidden>
      <rect x="2.5" y="3.5" width="11" height="10" rx="2.4" />
      <path d="M2.5 6.6 H13.5 M5.5 2.2 V4.6 M10.5 2.2 V4.6" />
    </svg>
  ),
  changes: (
    <svg viewBox="0 0 16 16" aria-hidden>
      <path d="M3 5.5 H12 L9.6 3.1 M13 10.5 H4 L6.4 12.9" />
    </svg>
  ),
};

export function InboxScene({ s }: { s: Snapshot }) {
  const progress = useCreep(s.progress, s.ceiling);
  const listening = s.steps.some((step) => step.state === "active");
  const { h } = useViewport();
  const capsules = fitting(h, TOP, CAPSULE, CAPSULE_GAP);

  return (
    <main className="scene scene-inbox" data-offline={!s.online || undefined}>
      <header className="inbox-console">
        <div className="inbox-head">
          <MoonPhase value={progress} tone={tone(s)} />
          <div className="console-text">
            <h1 className="headline">{s.headline}</h1>
            {s.context && <p className="context">¶ {s.context}</p>}
          </div>
        </div>
        <StepsLedger steps={s.steps} glyphs={GLYPHS} />
      </header>

      <section className="inbox-feed" data-listening={listening || undefined} aria-hidden>
        {Array.from({ length: capsules }, (_, i) => (
          <div key={i} className="capsule" style={{ ["--i" as string]: i, ["--r" as string]: i * 2 }}>
            <Bone h={28} round />
            <div className="capsule-lines">
              <Bone w={`${46 + seeded(i + 11) * 30}%`} h={10} c={1} />
              <Bone w={`${28 + seeded(i + 17) * 26}%`} h={8} tone="secondary" c={2} />
            </div>
            <Bone w={34} h={8} tone="faint" c={5} />
          </div>
        ))}
      </section>
    </main>
  );
}
